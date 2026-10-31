// FlutterFlow custom action: "probeRtspStream"
// Return type: JSON — {ok, latencyMs, video, audio, backchannel, server, error}.
// Argument: deviceId (String).
//
// Performs RTSP OPTIONS + DESCRIBE (with digest auth) and parses the SDP,
// without starting the video decoder. Useful for diagnostics screens.

import '../../core/app_services.dart';
import '../../core/models/device.dart';
import '../../core/network/connection_manager.dart';
import '../../core/rtsp/rtsp_client.dart';

Future<dynamic> probeRtspStream(String deviceId) async {
  final s = AppServices.instance;
  final device = s.registry.byId(deviceId);
  if (device == null) return {'ok': false, 'error': 'Unknown device'};
  try {
    final route = await s.connections.require(deviceId);
    final creds = s.registry.mediaCredentialsFor(deviceId);
    final r = await RtspClient.probe(
      uri: route.rtspUri(route.streamPath(device, StreamQuality.main)),
      username: creds?.username ?? '',
      password: creds?.password ?? '',
    );
    return {
      'ok': true,
      'route': route.kind.name,
      'latencyMs': r.latency.inMilliseconds,
      'video': r.videoCodec,
      'audio': r.audioCodec,
      'backchannel': r.hasBackchannel,
      'server': r.server,
    };
  } on RtspException catch (e) {
    return {'ok': false, 'error': e.message};
  } on DeviceUnreachableException catch (e) {
    return {'ok': false, 'error': e.toString()};
  }
}
