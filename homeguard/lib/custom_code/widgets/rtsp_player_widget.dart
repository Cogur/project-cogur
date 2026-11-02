// FlutterFlow custom widget.
// Settings → Custom Code → Widgets → "RtspPlayerWidget".
// Dependencies: media_kit, media_kit_video, media_kit_libs_video.
// Parameters are primitives so the widget can be dropped onto any FF page.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/utils/log.dart';

/// Lookup for live players by tag, so FlutterFlow custom actions (snapshot,
/// mute) can reach a player without passing non-primitive objects around.
class RtspPlayerRegistry {
  RtspPlayerRegistry._();
  static final instance = RtspPlayerRegistry._();
  final Map<String, Player> _players = {};

  Player? operator [](String tag) => _players[tag];
  void _register(String tag, Player p) => _players[tag] = p;
  void _unregister(String tag, Player p) {
    if (identical(_players[tag], p)) _players.remove(tag);
  }
}

enum RtspPlayerStatus { connecting, playing, buffering, stalled, error, ended }

/// Low-latency RTSP player with automatic recovery.
///
/// * TCP-interleaved RTSP (no UDP loss/NAT issues), demuxer cache disabled,
///   minimal probing — typically 300–700 ms glass-to-glass on LAN.
/// * Watchdog: if no new frame position arrives for [stallTimeout], the
///   stream is reopened.
/// * Exponential back-off reconnect (1s → 30s) on errors or dropouts.
class RtspPlayerWidget extends StatefulWidget {
  const RtspPlayerWidget({
    super.key,
    this.width,
    this.height,
    required this.rtspUrl,
    this.playerTag,
    this.muted = true,
    this.fit = BoxFit.contain,
    this.stallTimeoutSeconds = 8,
    this.onStatusChanged,
    this.overlayBuilder,
    this.live = true,
    this.extraProperties = const {},
    this.onFrameType,
    this.onEarlyEnd,
  });

  final double? width;
  final double? height;

  /// Full URL including credentials. Never displayed or logged.
  final String rtspUrl;
  final String? playerTag;
  final bool muted;
  final BoxFit fit;
  final int stallTimeoutSeconds;
  final void Function(RtspPlayerStatus status, String? message)? onStatusChanged;
  final Widget Function(BuildContext, RtspPlayerStatus, String?, VoidCallback retry)? overlayBuilder;

  /// Live camera (reconnects when the stream ends) or a recording (stops
  /// at its end instead of starting over).
  final bool live;

  /// mpv properties applied after the defaults (decoder experiments).
  final Map<String, String> extraProperties;

  /// Picture type of each newly shown frame ("I", "P", "B"), sampled.
  final void Function(String type, Duration sinceOpen)? onFrameType;

  /// Recordings: the stream went quiet after playing for [played] (wall
  /// clock from the first picture to the last progress). The NVR stops
  /// some clips early; the page can reopen from where it stopped.
  final void Function(Duration played)? onEarlyEnd;

  @override
  State<RtspPlayerWidget> createState() => _RtspPlayerWidgetState();
}

class _RtspPlayerWidgetState extends State<RtspPlayerWidget> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _video;
  final _subs = <StreamSubscription<Object?>>[];
  RtspPlayerStatus _status = RtspPlayerStatus.connecting;
  String? _message;
  Timer? _watchdog;
  Timer? _retryTimer;
  int _attempt = 0;
  DateTime _lastProgress = DateTime.now();
  bool _disposed = false;
  bool _paused = false;

  /// Last warning/error from libmpv/ffmpeg: the real reason behind a generic
  /// "Stream error" (e.g. 401, unsupported codec), shown to the user.
  String? _lastLog;
  DateTime _openedAt = DateTime.now();
  DateTime? _firstFrameAt;
  bool _sawProgress = false;
  Duration _lastPos = Duration.zero;

  static final _benign = RegExp(r'cannot seek|force-seekable|property not found', caseSensitive: false);
  String get _tag => 'video:${widget.playerTag ?? 'player'}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 512 * 1024,
        // Settings → Detailed logs: keep libmpv/ffmpeg's own messages too.
        logLevel: Log.verbose ? MPVLogLevel.info : MPVLogLevel.warn,
        // Live player may only speak RTSP; no file/http/data access.
        protocolWhitelist: const ['rtsp', 'rtsps', 'rtp', 'udp', 'tcp', 'tls'],
      ),
    );
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
    );
    _player.setVolume(widget.muted ? 0 : 100);
    if (widget.playerTag != null) {
      RtspPlayerRegistry.instance._register(widget.playerTag!, _player);
    }
    _subs
      ..add(
        _player.stream.log.listen((l) {
          final text = _stripCredentials('${l.prefix}: ${l.text}'.trim());
          if (l.level == 'error' || l.level == 'warn') _lastLog = text;
          Log.d('mpv:${widget.playerTag ?? 'player'}', '${l.level} $text');
        }),
      )
      ..add(
        _player.stream.error.listen((e) {
          if (_benign.hasMatch(e)) {
            // libmpv reports these at "error" level but keeps playing;
            // reconnecting on them made every tile flash off once.
            Log.d(_tag, 'ignored player message: $e');
            return;
          }
          Log.d(_tag, 'player error: ${_stripCredentials(e)}');
          _onFailure(_explain(e));
        }),
      )
      ..add(
        _player.stream.width.listen((w) {
          if (w != null && w > 0) {
            Log.d(_tag, 'video size ${w}x${_player.state.height} after ${_sinceOpen()}');
            _firstFrameAt ??= DateTime.now();
            _logDecoderInfo('first frame');
            // The first decoded picture is what counts as "playing".
            _lastProgress = DateTime.now();
            if (_status != RtspPlayerStatus.playing) {
              _attempt = 0;
              _setStatus(RtspPlayerStatus.playing);
            }
          }
        }),
      )
      ..add(
        _player.stream.buffering.listen((b) {
          Log.d(_tag, 'buffering=$b (status ${_status.name}) at ${_sinceOpen()}');
          if (b && _status == RtspPlayerStatus.playing) _setStatus(RtspPlayerStatus.buffering);
        }),
      )
      ..add(
        _player.stream.position.listen((pos) {
          // mpv reports position 0 right after open, before any picture:
          // only a moving position is progress.
          if (pos <= Duration.zero || pos == _lastPos) return;
          _lastPos = pos;
          _lastProgress = DateTime.now();
          if (!_sawProgress) {
            _sawProgress = true;
            Log.d(_tag, 'first progress (pos $pos) after ${_sinceOpen()}');
          }
          if (_status != RtspPlayerStatus.playing && _player.state.width != null) {
            _attempt = 0;
            _setStatus(RtspPlayerStatus.playing);
          }
        }),
      )
      ..add(
        _player.stream.completed.listen((done) {
          if (!done) return;
          Log.d(_tag, 'completed after ${_sinceOpen()} (live=${widget.live})');
          if (!widget.live) {
            // A recording simply ends; replaying it in a loop looked like a
            // flickering picture.
            _watchdog?.cancel();
            _setStatus(RtspPlayerStatus.ended, 'End of recording');
            return;
          }
          // A live stream never "completes"; this means the device hung up.
          _onFailure('Stream ended by device');
        }),
      );
    _open();
  }

  Future<void> _configureLowLatency() async {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    final props = {
      'rtsp-transport': 'tcp',
      'cache': 'no',
      'cache-pause': 'no',
      'demuxer-readahead-secs': '0',
      'demuxer-lavf-o': 'rtsp_transport=tcp,fflags=+nobuffer+discardcorrupt,flags=low_delay',
      'demuxer-lavf-analyzeduration': '0.4',
      'demuxer-lavf-probesize': '262144',
      'video-sync': 'audio',
      'interpolation': 'no',
      'network-timeout': '6',
      'untimed': 'yes',
      // Android: go straight to the decoder mode that works with this
      // renderer; plain "mediacodec" failed on every open first
      // ("Both surface and native_window are NULL") and cost time.
      if (Platform.isAndroid) 'hwdec': 'mediacodec-copy',
      // Live: joining between keyframes otherwise shows a black picture with
      // only the moving parts drawn in until the next keyframe. Show nothing
      // until a full frame decodes (the tile shows a still meanwhile).
      // Recordings keep partial frames: some NVR clips have no keyframe
      // within their first seconds and would otherwise stay black.
      if (widget.live) 'vd-lavc-o': 'flags=-output_corrupt',
      if (widget.live) 'vd-lavc-show-all': 'no',
    };
    // Recordings use the same settings: buffered playback ("untimed" off)
    // waited forever on the NVR's playback timestamps and never showed a
    // picture. What differs for recordings is the end (see `completed`).
    props.addAll(widget.extraProperties);
    if (widget.extraProperties.isNotEmpty) Log.d(_tag, 'extra mpv properties ${widget.extraProperties}');
    for (final e in props.entries) {
      await p.setProperty(e.key, e.value);
    }
  }

  /// Which decoder mpv really used and how many frames it dropped: the
  /// difference between a black and a working recording is often here.
  Future<void> _logDecoderInfo(String when) async {
    if (!Log.verbose) return;
    final p = _player.platform;
    if (p is! NativePlayer) return;
    final out = <String>[];
    for (final name in const [
      'hwdec-current',
      'video-codec',
      'video-params/pixelformat',
      'video-params/hw-pixelformat',
      'container-fps',
      'estimated-vf-fps',
      'estimated-frame-number',
      'video-pts',
      'decoder-frame-drop-count',
      'frame-drop-count',
      'video-frame-info/picture-type',
      'demuxer-cache-duration',
    ]) {
      try {
        out.add('$name=${await p.getProperty(name)}');
      } catch (_) {
        out.add('$name=?');
      }
    }
    if (!_disposed) Log.d(_tag, 'decoder $when: ${out.join(', ')}');
  }

  Timer? _frameProbe;
  String? _lastFrameType;
  int _frameTypeChanges = 0;

  /// Samples the type of the displayed picture (I = full keyframe) so the
  /// log shows when the first complete picture arrived.
  void _startFrameProbe() {
    _frameProbe?.cancel();
    _lastFrameType = null;
    _frameTypeChanges = 0;
    if (!Log.verbose && widget.onFrameType == null) return;
    final p = _player.platform;
    if (p is! NativePlayer) return;
    _frameProbe = Timer.periodic(const Duration(milliseconds: 150), (t) async {
      if (_disposed) return t.cancel();
      try {
        final type = await p.getProperty('video-frame-info/picture-type');
        if (type.isEmpty || type == _lastFrameType) return;
        _lastFrameType = type;
        final since = DateTime.now().difference(_openedAt);
        // Log the first changes, then only keyframes.
        if (_frameTypeChanges++ < 6 || type == 'I') {
          Log.d(_tag, 'frame type $type at ${since.inMilliseconds} ms');
        }
        widget.onFrameType?.call(type, since);
      } catch (_) {
        // Property unavailable until the first frame.
      }
      final ticks = t.tick;
      if (!widget.live && ticks % 33 == 0 && ticks <= 200) _logDecoderInfo('at ${_sinceOpen()}');
      if (DateTime.now().difference(_openedAt) > const Duration(minutes: 2)) t.cancel();
    });
  }

  Future<void> _open() async {
    if (_disposed || _paused) return;
    _retryTimer?.cancel();
    _lastLog = null;
    _openedAt = DateTime.now();
    _firstFrameAt = null;
    _sawProgress = false;
    _lastPos = Duration.zero;
    Log.d(_tag, 'open attempt ${_attempt + 1}, live=${widget.live}: ${_stripCredentials(widget.rtspUrl)}');
    _setStatus(RtspPlayerStatus.connecting);
    try {
      await _configureLowLatency();
      await _player.open(Media(widget.rtspUrl), play: true);
      // Disposed while opening: do not start a watchdog for a dead player.
      if (_disposed) return;
      _startFrameProbe();
      _lastProgress = DateTime.now();
      _watchdog?.cancel();
      _watchdog = Timer.periodic(const Duration(seconds: 2), (_) => _checkStall());
    } catch (e) {
      _onFailure(_explain('$e'));
    }
  }

  String _sinceOpen() => '${DateTime.now().difference(_openedAt).inMilliseconds} ms';

  void _checkStall() {
    if (_disposed) {
      _watchdog?.cancel();
      return;
    }
    if (_status == RtspPlayerStatus.error || _status == RtspPlayerStatus.ended) return;
    final silent = DateTime.now().difference(_lastProgress);
    // Before the first picture the camera may still be waiting for its next
    // keyframe (several seconds on H.265 "smart" codecs): give it longer
    // than a mid-stream stall, or the tile reconnects in a loop.
    final limit = _status == RtspPlayerStatus.connecting
        ? max(widget.stallTimeoutSeconds, 20)
        : widget.stallTimeoutSeconds;
    if (silent > Duration(seconds: limit)) {
      Log.d(_tag, 'watchdog: no progress for ${silent.inMilliseconds} ms in ${_status.name}');
      if (!widget.live && (_status == RtspPlayerStatus.playing || _status == RtspPlayerStatus.buffering)) {
        // The NVR keeps a playback session open after the clip's last frame:
        // that is its end, not a dropout to reconnect (which replayed it).
        _watchdog?.cancel();
        final played = _lastProgress.difference(_firstFrameAt ?? _lastProgress);
        Log.d(_tag, 'recording went quiet after ${played.inMilliseconds} ms of picture');
        _setStatus(RtspPlayerStatus.ended, 'End of recording');
        widget.onEarlyEnd?.call(played);
        return;
      }
      _onFailure(
        _status == RtspPlayerStatus.connecting
            ? 'Camera did not start streaming'
            : 'Stream stalled — reconnecting',
      );
    }
  }

  void _onFailure(String message) {
    if (_disposed) return;
    _watchdog?.cancel();
    _attempt++;
    final delay = Duration(milliseconds: min(30000, 1000 * pow(2, _attempt - 1).toInt()));
    Log.d(_tag, 'failure "$message" after ${_sinceOpen()}, retry in ${delay.inMilliseconds} ms');
    _setStatus(RtspPlayerStatus.error, message);
    _retryTimer?.cancel();
    // A refused login is not retried on its own: recorders count (and beep
    // on) every failed attempt. The user can still tap "Retry now".
    if (message == 'Authentication failed') return;
    _retryTimer = Timer(delay, () async {
      await _player.stop();
      _open();
    });
  }

  void retry() {
    _attempt = 0;
    _retryTimer?.cancel();
    _player.stop().then((_) => _open());
  }

  static final _userInfo = RegExp(r'([a-z][a-z0-9+.-]*://)[^/@\s]+@', caseSensitive: false);
  static String _stripCredentials(String s) => s.replaceAllMapped(_userInfo, (m) => '${m[1]}***@');

  /// Friendly text, falling back to the player's own last message.
  String _explain(String raw) {
    final detail = _lastLog;
    final friendly = _humanize('$raw ${detail ?? ''}');
    if (friendly != 'Stream error') return friendly;
    final text = detail ?? _stripCredentials(raw);
    return text.isEmpty
        ? friendly
        : 'Stream error: ${text.length > 160 ? '${text.substring(0, 160)}…' : text}';
  }

  static String _humanize(String raw) {
    final r = raw.toLowerCase();
    if (r.contains('401') || r.contains('unauthorized')) return 'Authentication failed';
    if (r.contains('timed out') || r.contains('timeout')) return 'Connection timed out';
    if (r.contains('refused')) return 'Connection refused by device';
    if (r.contains('unreachable') || r.contains('no route')) return 'Device unreachable';
    if (r.contains('404') || r.contains('not found')) return 'Stream path not found';
    if (r.contains('403') || r.contains('forbidden')) return 'This user may not view this camera';
    if (r.contains('recognize file format')) return 'Device refused the stream (check the RTSP login)';
    if (r.contains('461') || r.contains('unsupported transport')) return 'Device refused RTSP over TCP';
    return 'Stream error';
  }

  void _setStatus(RtspPlayerStatus s, [String? message]) {
    if (_disposed) return;
    if (s == _status && message == _message) return;
    Log.d(
      _tag,
      'status ${_status.name} → ${s.name}${message == null ? '' : ' ($message)'} at ${_sinceOpen()}',
    );
    setState(() {
      _status = s;
      _message = message;
    });
    widget.onStatusChanged?.call(s, message);
  }

  @override
  void didUpdateWidget(covariant RtspPlayerWidget old) {
    super.didUpdateWidget(old);
    if (old.muted != widget.muted) _player.setVolume(widget.muted ? 0 : 100);
    if (old.rtspUrl != widget.rtspUrl) retry();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the camera session in background: saves battery/data and
    // frees one of the NVR's limited concurrent stream slots.
    if (state == AppLifecycleState.paused) {
      _paused = true;
      _watchdog?.cancel();
      _retryTimer?.cancel();
      _player.stop();
    } else if (state == AppLifecycleState.resumed && _paused) {
      _paused = false;
      _attempt = 0;
      _open();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _watchdog?.cancel();
    _frameProbe?.cancel();
    _retryTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (widget.playerTag != null) {
      RtspPlayerRegistry.instance._unregister(widget.playerTag!, _player);
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(
            color: Colors.black,
            child: Video(controller: _video, fit: widget.fit, controls: null, fill: Colors.black),
          ),
          if (widget.overlayBuilder != null)
            widget.overlayBuilder!(context, _status, _message, retry)
          else
            _DefaultOverlay(status: _status, message: _message, onRetry: retry),
        ],
      ),
    );
  }
}

class _DefaultOverlay extends StatelessWidget {
  const _DefaultOverlay({required this.status, required this.message, required this.onRetry});

  final RtspPlayerStatus status;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case RtspPlayerStatus.playing:
        return const SizedBox.shrink();
      case RtspPlayerStatus.connecting || RtspPlayerStatus.buffering:
        return const Center(
          child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        );
      case RtspPlayerStatus.stalled || RtspPlayerStatus.error:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, color: Colors.white70),
              const SizedBox(height: 6),
              Text(
                message ?? 'Stream unavailable',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              TextButton(onPressed: onRetry, child: const Text('Retry now')),
            ],
          ),
        );
      case RtspPlayerStatus.ended:
        return Center(
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.replay),
            label: const Text('End of recording · play again'),
          ),
        );
    }
  }
}
