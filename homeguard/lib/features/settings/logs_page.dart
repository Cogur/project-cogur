import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/utils/log.dart';
import '../../theme/app_theme.dart';
import 'settings_controller.dart';

/// The in-memory log (redacted: no passwords or tokens), to copy and send
/// when something does not work. Filter by area, copy, clear.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const _filters = {
    'All': null,
    'Video': ['video:', 'mpv:', 'access'],
    'Playback': ['playback', 'lapi', 'video:playback', 'mpv:playback', 'video:lab', 'mpv:lab'],
    'Network': ['net', 'http', 'rtsp', 'tvt', 'auth', 'setup'],
  };
  String _filter = 'All';

  List<String> get _lines {
    final tags = _filters[_filter];
    final all = Log.recent;
    if (tags == null) return all;
    return [
      for (final l in all)
        if (tags.any((t) => l.contains(' D/$t') || l.contains(' W/$t') || l.contains(' E/$t'))) l,
    ];
  }

  String _report(List<String> lines) {
    final s = context.read<SettingsController>();
    return [
      'HomeGuard log, ${DateTime.now()}',
      'filter: $_filter, HD: ${s.preferHd}, detailed: ${s.detailedLogs}, lines: ${lines.length}',
      '',
      ...lines,
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final lines = _lines;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(tooltip: 'Refresh', onPressed: () => setState(() {}), icon: const Icon(Icons.refresh)),
          IconButton(
            tooltip: 'Copy',
            onPressed: lines.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: _report(lines)));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text('${lines.length} lines copied')));
                  },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () => setState(Log.clear),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text('Detailed logs'),
            subtitle: const Text('Video, recordings and network steps. Passwords are never logged.'),
            value: settings.detailedLogs,
            onChanged: (v) => settings.update(detailedLogs: v),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Tip: tap Clear, reproduce the problem (open a camera or a recording), come back, '
              'then Copy and paste the text into the chat.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final f in _filters.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f),
                      selected: f == _filter,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: lines.isEmpty
                ? const Center(
                    child: Text('No log lines', style: TextStyle(color: AppColors.textMuted)),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    itemCount: lines.length,
                    itemBuilder: (_, i) => SelectableText(
                      lines[lines.length - 1 - i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
