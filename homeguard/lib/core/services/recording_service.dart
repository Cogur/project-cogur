import '../bridge/bridge_client.dart';
import '../models/device.dart';
import '../network/connection_manager.dart';
import '../network/device_http_client.dart';
import '../security/secure_store.dart';
import '../tvt/tvt_lapi_client.dart';
import '../tvt/tvt_web_client.dart';
import 'device_registry.dart';

/// One recorded piece of video and how to play it.
class Recording {
  const Recording({required this.segment, required this.device, required this.path, required this.route});
  final RecordSegment segment;
  final DeviceConfig device;

  /// RTSP path on [route] that plays this recording.
  final String path;
  final ResolvedRoute route;
}

class RecordingException implements Exception {
  RecordingException(this.message, {this.needsApiServer = false});
  final String message;

  /// The recorder's HTTP API ("API Server") is off; it can be switched on
  /// with [RecordingService.enableApiServer] after asking the user.
  final bool needsApiServer;
  @override
  String toString() => message;
}

/// Finds recordings on the NVR (LAN: TVT HTTP API; remote: HomeGuard Bridge)
/// and builds the playback stream for each.
class RecordingService {
  RecordingService(this._registry, this._connections, {DeviceHttpClient? http}) : _http = http;

  final DeviceRegistry _registry;
  final ConnectionManager _connections;
  final DeviceHttpClient? _http;

  /// TVT RTSP playback form from the HTTP API guide (Viewtron/TVT docs):
  /// The guide says `chID` is 0-based here, but the TCR I12 numbers it from
  /// 1 like the live URL (0-based played the neighbouring camera).
  static const tvtPlaybackTemplate =
      '/chID={channel}&date={date}&time={time}&timelen={seconds}&streamType={stream}&action=playback&linkType=tcp';

  static String playbackPath(
    DeviceConfig camera,
    RecordSegment s, {
    StreamQuality quality = StreamQuality.main,
  }) {
    // Non-TVT stream paths (custom firmware, the simulator) have no known
    // playback form; show the camera's stream instead of failing.
    if (camera.rtspPathTemplate != DeviceConfig.tvtRtspTemplate) return camera.rtspPath(quality);
    String two(int v) => v.toString().padLeft(2, '0');
    final t = s.start;
    return tvtPlaybackTemplate
        .replaceAll('{channel0}', '${camera.channel - 1}') // playback chID is 0-based
        .replaceAll('{channel}', '${camera.channel}')
        .replaceAll('{date}', '${t.year}-${two(t.month)}-${two(t.day)}')
        .replaceAll('{time}', '${two(t.hour)}:${two(t.minute)}:${two(t.second)}')
        .replaceAll('{seconds}', '${s.length.inSeconds.clamp(1, 86400)}')
        .replaceAll('{stream}', quality.name);
  }

  /// The same recording, played from [start] (e.g. a tap on the timeline).
  static Recording seek(Recording r, DateTime start) {
    final seg = RecordSegment(
      channel: r.segment.channel,
      start: start,
      end: r.segment.end,
      type: r.segment.type,
    );
    String stamp(DateTime t) =>
        '${t.year}${[t.month, t.day, t.hour, t.minute, t.second].map((v) => v.toString().padLeft(2, '0')).join()}';
    final path = r.route.bridge
        ? '/${r.device.parentId ?? r.device.id}_ch${r.device.channel}_pb_${stamp(seg.start)}_${stamp(seg.end)}'
        : playbackPath(r.device, seg);
    return Recording(segment: seg, device: r.device, path: path, route: r.route);
  }

  Credentials _creds(DeviceConfig d) {
    final c = _registry.mediaCredentialsFor(d.id);
    if (c == null) throw RecordingException('Not signed in');
    return c;
  }

  Future<List<Recording>> search(String cameraId, DateTime day) async {
    final camera = _registry.byId(cameraId);
    if (camera == null) throw RecordingException('Unknown camera');
    final recorder = camera.parentId == null ? camera : _registry.byId(camera.parentId!) ?? camera;
    final route = await _connections.require(cameraId);
    final from = DateTime(day.year, day.month, day.day);
    final to = from.add(const Duration(days: 1)).subtract(const Duration(seconds: 1));

    if (route.bridge) {
      final bridge = BridgeClient(
        host: route.host,
        port: route.httpPort,
        credentials: _registry.credentialsFor(recorder.id) ?? (throw RecordingException('Not signed in')),
        http: _http,
      );
      try {
        final recs = await bridge.recordings(recorder.id, camera.channel, from, to);
        return [
          for (final r in recs) Recording(segment: r.segment, device: camera, path: r.path, route: route),
        ];
      } on DeviceHttpException catch (e) {
        throw RecordingException('Bridge: ${e.message}');
      }
    }

    final lapi = TvtLapiClient(
      host: route.host,
      port: route.httpPort,
      secure: route.secure,
      credentials: _creds(recorder),
      http: _http,
    );
    try {
      final segs = await lapi.searchByTime(camera.channel, from, to);
      return [
        for (final s in segs)
          Recording(segment: s, device: camera, path: playbackPath(camera, s), route: route),
      ];
    } on DeviceHttpException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 501 || e.statusCode == 503) {
        throw RecordingException('The NVR\'s HTTP API ("API Server") is switched off.', needsApiServer: true);
      }
      final why = (e.body ?? '').replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      throw RecordingException(
        why.isEmpty ? e.message : '${e.message}: ${why.length > 120 ? why.substring(0, 120) : why}',
      );
    } on FormatException {
      throw RecordingException('The NVR answered recording search in an unknown format.');
    }
  }

  /// Switches on the recorder's API Server through its web interface, with
  /// the signed-in account (same permission as doing it on the web page).
  Future<void> enableApiServer(String cameraId) async {
    final camera = _registry.byId(cameraId)!;
    final recorder = camera.parentId == null ? camera : _registry.byId(camera.parentId!)!;
    final route = await _connections.require(cameraId);
    // The web login hashes the password itself: plain credentials here.
    final c = _registry.credentialsFor(recorder.id);
    if (c == null) throw RecordingException('Not signed in');
    final web = TvtWebClient(
      host: route.host,
      port: route.httpPort,
      secure: route.secure,
      username: c.username,
      password: c.password,
    );
    try {
      await web.login();
      if (!await web.apiServerEnabled()) await web.enableApiServer();
    } on TvtWebException catch (e) {
      throw RecordingException('Could not switch on the API Server: $e');
    } finally {
      web.close();
    }
  }
}
