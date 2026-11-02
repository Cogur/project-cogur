import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/utils/log.dart';
import '../settings/settings_controller.dart';
import '../../core/models/device.dart';
import '../../core/services/device_registry.dart';
import '../../core/services/recording_service.dart';
import '../../custom_code/widgets/rtsp_player_widget.dart';
import '../../theme/app_theme.dart';

/// Recordings: pick a camera and a day, see the day on a 24 h timeline, tap
/// anywhere on it to play from that moment.
class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key});

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  String? _cameraId;
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  List<Recording> _recs = const [];
  Recording? _playing;
  bool _loading = false;
  String? _error;
  bool _needsApi = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cameraId == null) {
      final cams = _cameras(context.read<DeviceRegistry>());
      if (cams.isNotEmpty) {
        _cameraId = cams.first.id;
        WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      }
    }
  }

  static List<DeviceConfig> _cameras(DeviceRegistry r) =>
      r.videoDevices.where((d) => d.kind == DeviceKind.camera).toList();

  Future<void> _load() async {
    final id = _cameraId;
    if (id == null) return;
    setState(() {
      _loading = true;
      _error = null;
      _needsApi = false;
      _playing = null;
    });
    try {
      final hd = context.read<SettingsController>().preferHd;
      final recs = await context.read<AppServices>().recordings.search(
        id,
        _day,
        quality: hd ? StreamQuality.main : StreamQuality.sub,
      );
      if (!mounted || id != _cameraId) return;
      setState(() => _recs = recs);
    } on RecordingException catch (e) {
      if (!mounted) return;
      setState(() {
        _recs = const [];
        _error = e.message;
        _needsApi = e.needsApiServer;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _enableApi() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.video_library_outlined),
        title: const Text('Switch on recording access?'),
        content: const Text(
          'Searching recordings needs the NVR\'s HTTP API ("API Server"). HomeGuard can switch it on with your '
          'account. It stays password protected.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Switch on')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppServices>().recordings.enableApiServer(_cameraId!);
      await _load();
    } on RecordingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _shiftDay(int days) {
    final next = _day.add(Duration(days: days));
    if (next.isAfter(DateUtils.dateOnly(DateTime.now()))) return;
    setState(() => _day = next);
    _load();
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _day = DateUtils.dateOnly(picked));
      await _load();
    }
  }

  void _play(Recording r, String why) {
    Log.d(
      'playback',
      '$why: ${r.device.name} ${r.segment.start}–${r.segment.end} ${r.segment.type} path ${r.path}',
    );
    setState(() => _playing = r);
  }

  void _playAt(DateTime t) {
    final hit = _recs.where((r) => r.segment.contains(t)).firstOrNull;
    if (hit != null) {
      _play(RecordingService.seek(hit, t), 'timeline tap');
      return;
    }
    // Nothing at that moment: jump to the next recording after it.
    final next = _recs.where((r) => r.segment.start.isAfter(t)).firstOrNull;
    if (next != null) _play(next, 'timeline tap (next)');
  }

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final cams = _cameras(registry);
    final today = DateUtils.isSameDay(_day, DateTime.now());
    return Scaffold(
      appBar: AppBar(title: const Text('Recordings')),
      body: cams.isEmpty
          ? const Center(
              child: Text('No cameras', style: TextStyle(color: AppColors.textMuted)),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (_playing != null)
                  _Player(recording: _playing!, onClose: () => setState(() => _playing = null)),
                SizedBox(
                  height: 56,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    children: [
                      for (final c in cams)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(c.name),
                            selected: c.id == _cameraId,
                            onSelected: (_) {
                              setState(() => _cameraId = c.id);
                              _load();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Previous day',
                        onPressed: () => _shiftDay(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _pickDay,
                          icon: const Icon(Icons.calendar_today, size: 18),
                          label: Text(today ? 'Today' : DateFormat.yMMMEd().format(_day)),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Next day',
                        onPressed: today ? null : () => _shiftDay(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _Timeline(day: _day, recordings: _recs, playing: _playing, onTap: _playAt),
                ),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.error_outline, color: AppColors.danger),
                        title: Text(_error!),
                        trailing: _needsApi
                            ? FilledButton(onPressed: _enableApi, child: const Text('Switch on'))
                            : IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
                      ),
                    ),
                  ),
                if (!_loading && _error == null && _recs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text('No recordings on this day', style: TextStyle(color: AppColors.textMuted)),
                    ),
                  ),
                for (final r in _recs.reversed)
                  ListTile(
                    leading: Icon(_typeIcon(r.segment.type), color: _typeColor(r.segment.type)),
                    title: Text(
                      '${DateFormat.Hms().format(r.segment.start)} – ${DateFormat.Hms().format(r.segment.end)}',
                    ),
                    subtitle: Text(
                      [
                        _duration(r.segment.length),
                        if (r.segment.type.isNotEmpty) r.segment.type,
                      ].join(' · '),
                    ),
                    selected: _playing?.segment.end == r.segment.end,
                    trailing: const Icon(Icons.play_circle_outline),
                    onTap: () => _play(r, 'list tap'),
                  ),
              ],
            ),
    );
  }

  static String _duration(Duration d) =>
      d.inHours > 0 ? '${d.inHours} h ${d.inMinutes % 60} min' : '${d.inMinutes} min ${d.inSeconds % 60} s';

  static bool _isEvent(String type) =>
      RegExp('motion|alarm|sensor|event|smart|intel|detect', caseSensitive: false).hasMatch(type);
  static IconData _typeIcon(String type) => _isEvent(type) ? Icons.directions_run : Icons.videocam_outlined;
  static Color _typeColor(String type) => _isEvent(type) ? AppColors.warning : AppColors.primary;
}

class _Player extends StatelessWidget {
  const _Player({required this.recording, required this.onClose});
  final Recording recording;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final registry = context.read<DeviceRegistry>();
    final url = recording.route.rtspUrl(
      recording.path,
      registry.streamCredentialsFor(recording.device.id, viaBridge: recording.route.bridge),
    );
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: RtspPlayerWidget(
              key: ValueKey(recording.path),
              rtspUrl: url,
              muted: false,
              playerTag: 'playback',
              stallTimeoutSeconds: 15,
              live: false,
            ),
          ),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.history),
          title: Text(
            '${recording.device.name} · ${DateFormat.MMMd().add_Hms().format(recording.segment.start)}',
          ),
          trailing: IconButton(tooltip: 'Close', onPressed: onClose, icon: const Icon(Icons.close)),
        ),
      ],
    );
  }
}

/// 24 h bar: recorded spans, the playing position, hour ticks.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.day, required this.recordings, required this.playing, required this.onTap});
  final DateTime day;
  final List<Recording> recordings;
  final Recording? playing;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final f = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0);
          onTap(day.add(Duration(seconds: (f * 86400).round())));
        },
        child: Semantics(
          label: '24 hour recording timeline, ${recordings.length} recordings. Tap to play from a time.',
          child: CustomPaint(
            size: Size(box.maxWidth, 56),
            painter: _TimelinePainter(day, recordings, playing),
          ),
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.day, this.recordings, this.playing);
  final DateTime day;
  final List<Recording> recordings;
  final Recording? playing;

  double _x(DateTime t, Size s) => (t.difference(day).inSeconds / 86400).clamp(0.0, 1.0) * s.width;

  @override
  void paint(Canvas canvas, Size size) {
    const barTop = 8.0;
    const barH = 24.0;
    final bg = Paint()..color = AppColors.surfaceHigh;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, barTop, size.width, barH), const Radius.circular(6)),
      bg,
    );
    for (final r in recordings) {
      final x0 = _x(r.segment.start, size);
      final x1 = _x(r.segment.end, size);
      final event = _PlaybackPageState._isEvent(r.segment.type);
      canvas.drawRect(
        Rect.fromLTRB(x0, barTop, (x1 - x0) < 1 ? x0 + 1 : x1, barTop + barH),
        Paint()..color = (event ? AppColors.warning : AppColors.primary).withValues(alpha: 0.85),
      );
    }
    final tick = Paint()
      ..color = AppColors.textMuted
      ..strokeWidth = 1;
    final text = TextPainter(textDirection: TextDirection.ltr);
    for (var h = 0; h <= 24; h += 3) {
      final x = size.width * h / 24;
      canvas.drawLine(Offset(x, barTop + barH), Offset(x, barTop + barH + 4), tick);
      if (h < 24) {
        text.text = TextSpan(
          text: '$h',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
        );
        text.layout();
        text.paint(canvas, Offset((x + 2).clamp(0, size.width - text.width), barTop + barH + 4));
      }
    }
    final p = playing;
    if (p != null) {
      final x = _x(p.segment.start, size);
      canvas.drawLine(
        Offset(x, 2),
        Offset(x, barTop + barH + 2),
        Paint()
          ..color = AppColors.secure
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.recordings != recordings || old.playing != playing || old.day != day;
}
