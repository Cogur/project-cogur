import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/rtsp/rtp_inspector.dart';
import '../../core/services/device_registry.dart';
import '../../core/services/recording_service.dart';
import '../../core/utils/log.dart';
import '../../custom_code/widgets/rtsp_player_widget.dart';
import '../../theme/app_theme.dart';

/// One way of opening and decoding a recording.
class LabVariant {
  const LabVariant(
    this.id,
    this.label,
    this.description, {
    this.props = const {},
    this.preroll = Duration.zero,
    this.quality,
    this.linkType = true,
    this.rtp,
  });
  final String id;
  final String label;
  final String description;
  final Map<String, String> props;
  final Duration preroll;
  final StreamQuality? quality;
  final bool linkType;

  /// Not a player: HomeGuard reads the raw RTP itself ('recording' or
  /// 'live' for comparison) and reports packets and keyframes.
  final String? rtp;

  static const _sw = {'hwdec': 'no'};
  static const _clean = {'vd-lavc-o': 'flags=-output_corrupt', 'vd-lavc-show-all': 'no'};
  static const _plainDemux = {
    'demuxer-lavf-o': 'rtsp_transport=tcp',
    'demuxer-lavf-analyzeduration': '0',
    'demuxer-lavf-probesize': '0',
  };
  static const _buffered = {
    'untimed': 'no',
    'cache': 'yes',
    'cache-pause': 'yes',
    'demuxer-readahead-secs': '5',
    'video-sync': 'display-resample',
  };

  static const all = [
    LabVariant(
      'R',
      'R · RTP check',
      'No player: HomeGuard reads the recording stream itself for 20 s and reports whether data and '
          'keyframes arrive.',
      rtp: 'recording',
    ),
    LabVariant(
      'S',
      'S · live RTP',
      'The same check on this camera\'s live SD stream, for comparison.',
      rtp: 'live',
    ),
    LabVariant('A', 'A · now', 'What Recordings uses now: hardware decoder, damaged frames shown.'),
    LabVariant('B', 'B · SW', 'Software decoder (hwdec=no).', props: _sw),
    LabVariant(
      'C',
      'C · HW clean',
      'Hardware decoder, damaged frames hidden until a keyframe.',
      props: _clean,
    ),
    LabVariant('D', 'D · SW clean', 'Software decoder, damaged frames hidden.', props: {..._sw, ..._clean}),
    LabVariant(
      'E',
      'E · −10 s',
      'Starts 10 s earlier so a keyframe arrives first; hardware decoder.',
      preroll: Duration(seconds: 10),
    ),
    LabVariant(
      'F',
      'F · −10 s SW clean',
      'Starts 10 s earlier, software decoder, damaged frames hidden.',
      preroll: Duration(seconds: 10),
      props: {..._sw, ..._clean},
    ),
    LabVariant(
      'G',
      'G · full probe',
      'Lets ffmpeg probe the stream fully (no nobuffer/discardcorrupt), software decoder.',
      props: {..._sw, ..._plainDemux},
    ),
    LabVariant(
      'H',
      'H · buffered',
      'Buffered, timed playback (like a file) with full probe, software decoder.',
      props: {..._sw, ..._plainDemux, ..._buffered},
    ),
    LabVariant(
      'I',
      'I · main',
      'Main (HD) stream, software decoder, full probe.',
      quality: StreamQuality.main,
      props: {..._sw, ..._plainDemux},
    ),
    LabVariant(
      'J',
      'J · sub',
      'Sub (SD) stream, software decoder, full probe.',
      quality: StreamQuality.sub,
      props: {..._sw, ..._plainDemux},
    ),
    LabVariant(
      'K',
      'K · no linkType',
      'Playback URL without "&linkType=tcp", software decoder, full probe.',
      linkType: false,
      props: {..._sw, ..._plainDemux},
    ),
  ];
}

class _Result {
  final events = <String>[];
  int? firstFrameMs;
  int? firstKeyframeMs;
  final types = <String, int>{};
  String status = 'not run';
}

/// Recordings → decoder lab: plays one recording in several ways, one tab
/// at a time (the NVR has few playback slots), and records which way shows
/// a picture and how fast. "Copy" hands the results and logs over.
class DecoderLabPage extends StatefulWidget {
  const DecoderLabPage({super.key, required this.recording});
  final Recording recording;

  @override
  State<DecoderLabPage> createState() => _DecoderLabPageState();
}

class _DecoderLabPageState extends State<DecoderLabPage> {
  int _index = 0;
  int _run = 0;

  /// The NVR needs a moment to free the previous playback session.
  bool _ready = false;
  Timer? _gap;
  final _results = <String, _Result>{};
  final _openedAt = <String, DateTime>{};

  LabVariant get _variant => LabVariant.all[_index];

  @override
  void initState() {
    super.initState();
    final r = widget.recording;
    Log.d('playback', 'lab opened: ${r.device.name} ${r.segment.start}–${r.segment.end} ${r.segment.type}');
    _startGap(LabVariant.all.first.id);
  }

  void _startGap(String id) {
    _ready = false;
    _gap?.cancel();
    _gap = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _ready = true;
        _openedAt[id] = DateTime.now();
      });
    });
  }

  @override
  void dispose() {
    _gap?.cancel();
    super.dispose();
  }

  _Result _resultFor(String id) => _results.putIfAbsent(id, _Result.new);

  int _sinceOpen(String id) => DateTime.now().difference(_openedAt[id] ?? DateTime.now()).inMilliseconds;

  /// Each selection is a fresh run of that variant.
  void _select(int i) {
    final id = LabVariant.all[i].id;
    Log.d('playback', 'lab run $id: ${LabVariant.all[i].description}');
    setState(() {
      _index = i;
      _run++;
      _results[id] = _Result();
      _startGap(id);
    });
  }

  void _onStatus(LabVariant v, RtspPlayerStatus s, String? msg) {
    final res = _resultFor(v.id);
    final ms = _sinceOpen(v.id);
    res.status = s.name;
    res.events.add('${s.name}${msg == null ? '' : ' ($msg)'} @$ms ms');
    if (s == RtspPlayerStatus.playing) res.firstFrameMs ??= ms;
    Log.d('playback', 'lab ${v.id} status ${s.name}${msg == null ? '' : ' ($msg)'} at $ms ms');
    if (mounted) setState(() {});
  }

  void _onFrameType(LabVariant v, String type, Duration since) {
    final res = _resultFor(v.id);
    res.types[type] = (res.types[type] ?? 0) + 1;
    if (type == 'I' && res.firstKeyframeMs == null) {
      res.firstKeyframeMs = since.inMilliseconds;
      Log.d('playback', 'lab ${v.id} first keyframe at ${since.inMilliseconds} ms');
    }
    if (mounted) setState(() {});
  }

  String _summary() {
    final r = widget.recording;
    final b = StringBuffer()
      ..writeln('HomeGuard decoder lab, ${DateTime.now()}')
      ..writeln(
        '${r.device.name} ch${r.device.channel} ${r.segment.start}–${r.segment.end} ${r.segment.type}',
      )
      ..writeln('variant | status | first frame | first keyframe | frame types | events');
    for (final v in LabVariant.all) {
      final res = _results[v.id];
      if (res == null) continue;
      b.writeln(
        '${v.id} | ${res.status} | ${res.firstFrameMs ?? '-'} ms | ${res.firstKeyframeMs ?? '-'} ms | '
        '${res.types} | ${res.events.join('; ')}',
      );
    }
    b
      ..writeln()
      ..writeln('--- log ---');
    for (final l in Log.recent) {
      if (l.contains('lab') || l.contains('playback')) b.writeln(l);
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final v = _variant;
    final rec = RecordingService.variant(
      widget.recording,
      quality: v.quality,
      preroll: v.preroll,
      linkType: v.linkType,
    );
    final registry = context.read<DeviceRegistry>();
    final url = rec.route.rtspUrl(
      rec.path,
      registry.streamCredentialsFor(rec.device.id, viaBridge: rec.route.bridge),
    );
    final res = _resultFor(v.id);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Decoder lab'),
        actions: [
          IconButton(
            tooltip: 'Copy results and log',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _summary()));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lab results copied')));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (var i = 0; i < LabVariant.all.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: _verdictIcon(_results[LabVariant.all[i].id]),
                      label: Text(LabVariant.all[i].label),
                      selected: i == _index,
                      onSelected: (_) => _select(i),
                    ),
                  ),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ColoredBox(
              color: Colors.black,
              child: Builder(
                builder: (_) {
                  final key = '${v.id}#$_run';
                  if (!_ready) {
                    return const Center(
                      child: Text(
                        'Waiting 2 s for the NVR to free the previous stream…',
                        style: TextStyle(color: Colors.white70),
                      ),
                    );
                  }
                  if (v.rtp != null) {
                    final live = v.rtp == 'live';
                    final path = live ? rec.route.streamPath(rec.device, StreamQuality.sub) : rec.path;
                    final c = registry.streamCredentialsFor(rec.device.id, viaBridge: rec.route.bridge);
                    return _RtpPanel(
                      key: ValueKey(key),
                      inspector: RtpInspector(
                        uri: rec.route.rtspUri(path),
                        username: c?.username ?? '',
                        password: c?.password ?? '',
                        tag: 'rtp:lab-${v.id}',
                      ),
                      onDone: (stats) {
                        final res = _resultFor(v.id);
                        res.status = stats == null
                            ? 'failed'
                            : stats.firstKeyframeMs != null
                            ? 'keyframe'
                            : stats.packets > 0
                            ? 'no keyframe'
                            : 'no data';
                        res.firstKeyframeMs = stats?.firstKeyframeMs;
                        res.firstFrameMs = stats?.firstPacketMs;
                        res.events.add(stats?.summary(0) ?? 'failed');
                        if (mounted) setState(() {});
                      },
                    );
                  }
                  return RtspPlayerWidget(
                    key: ValueKey(key),
                    rtspUrl: url,
                    muted: true,
                    playerTag: 'lab-${v.id}',
                    stallTimeoutSeconds: 15,
                    live: false,
                    extraProperties: v.props,
                    onStatusChanged: (s, m) => _onStatus(v, s, m),
                    onFrameType: (t, since) => _onFrameType(v, t, since),
                  );
                },
              ),
            ),
          ),
          ListTile(
            title: Text(v.label),
            subtitle: Text(v.description),
            trailing: IconButton(
              tooltip: 'Run again',
              icon: const Icon(Icons.replay),
              onPressed: () => _select(_index),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Status: ${res.status}\n'
              '${v.rtp != null ? 'First RTP packet' : 'First picture'}: ${res.firstFrameMs == null ? '-' : '${res.firstFrameMs} ms'}\n'
              'First keyframe (I): ${res.firstKeyframeMs == null ? '-' : '${res.firstKeyframeMs} ms'}\n'
              'Frame types: ${res.types.isEmpty ? '-' : res.types}\n'
              'Start: ${DateFormat.Hms().format(rec.segment.start.subtract(v.preroll))}'
              '${v.preroll == Duration.zero ? '' : ' (−${v.preroll.inSeconds} s)'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Try each tab for about 20 seconds and note whether the picture is black, partly drawn or '
              'clear. Then tap Copy (top right) and send the text.',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _verdictIcon(_Result? r) {
    if (r == null) return null;
    if (r.firstKeyframeMs != null) return const Icon(Icons.check_circle, size: 18, color: Colors.green);
    if (r.firstFrameMs != null) return const Icon(Icons.timelapse, size: 18, color: AppColors.warning);
    if (r.status == 'error' || r.status == 'no data' || r.status == 'failed') {
      return const Icon(Icons.error_outline, size: 18, color: AppColors.danger);
    }
    return null;
  }
}

/// Runs an [RtpInspector] while shown and lists what it reports.
class _RtpPanel extends StatefulWidget {
  const _RtpPanel({super.key, required this.inspector, required this.onDone});
  final RtpInspector inspector;
  final void Function(RtpStats? stats) onDone;

  @override
  State<_RtpPanel> createState() => _RtpPanelState();
}

class _RtpPanelState extends State<_RtpPanel> {
  final _lines = <String>[];
  bool _running = true;

  @override
  void initState() {
    super.initState();
    widget.inspector
        .run((l) {
          if (mounted) setState(() => _lines.add(l));
        })
        .then((stats) {
          if (!mounted) return;
          setState(() => _running = false);
          widget.onDone(stats);
        });
  }

  @override
  void dispose() {
    widget.inspector.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Newest first, without SDP noise once it is long.
    final shown = _lines.reversed.where((l) => !l.startsWith('  sdp')).take(12).toList();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_running)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 8),
              Text(_running ? 'Reading the stream…' : 'Done', style: const TextStyle(color: Colors.white)),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView(
              children: [
                for (final l in shown)
                  Text(
                    l,
                    style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 10),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
