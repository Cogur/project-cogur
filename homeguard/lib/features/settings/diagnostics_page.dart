import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/services/device_registry.dart';
import '../../core/tvt/tvt_probe.dart';
import '../../core/utils/log.dart';
import '../../theme/app_theme.dart';

/// Read-only probe of every configured device. The copyable report helps
/// add support for undocumented models (no passwords, serials masked).
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  final _lines = <String>[];
  bool _running = false;

  Future<void> _run() async {
    final registry = context.read<DeviceRegistry>();
    setState(() {
      _running = true;
      _lines.clear();
    });
    final probe = TvtProbe();
    final hosts = <String, String>{};
    for (final d in registry.devices.where((d) => d.parentId == null && d.lanHost.isNotEmpty)) {
      hosts.putIfAbsent(d.lanHost, () => d.id);
    }
    for (final e in hosts.entries) {
      final d = registry.byId(e.value)!;
      try {
        final lines = await probe.run(
          e.key,
          registry.credentialsFor(d.id),
          httpPort: d.httpPort,
          rtspPort: d.rtspPort,
        );
        if (!mounted) return;
        setState(() => _lines.addAll(['', '${d.name}:', ...lines]));
      } catch (err) {
        if (mounted) setState(() => _lines.add('${d.name}: $err'));
      }
    }
    if (mounted) {
      setState(() {
        if (_lines.where((l) => l.startsWith('Open ports: none')).length == hosts.length &&
            hosts.isNotEmpty) {
          _lines.add('\nNo device answered at all: the phone was probably not on the home Wi-Fi.');
        }
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = Log.redact(_lines.join('\n').trim());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy report',
            onPressed: report.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: report));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Report copied')));
                  },
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Checks which services each device offers (read-only, nothing is changed). Copy the report to get '
            'support for features the manufacturer does not document. Passwords are never included and cloud '
            'serials are masked. Keep the app open and the phone on the home Wi-Fi while it runs.',
            style: TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: Text(_running ? 'Checking…' : 'Run diagnostics'),
          ),
          const SizedBox(height: 16),
          if (report.isNotEmpty)
            SelectableText(report, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}
