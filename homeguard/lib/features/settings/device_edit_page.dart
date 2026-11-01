import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/onvif/onvif_client.dart';
import '../../core/security/secure_store.dart';
import '../../core/services/device_registry.dart';
import '../../theme/app_theme.dart';
import '../live/video_access.dart';

class DeviceEditPage extends StatefulWidget {
  const DeviceEditPage({super.key, required this.deviceId});
  final String deviceId;

  @override
  State<DeviceEditPage> createState() => _DeviceEditPageState();
}

class _DeviceEditPageState extends State<DeviceEditPage> {
  final _form = GlobalKey<FormState>();
  late DeviceConfig _d;
  late final Map<String, TextEditingController> _c;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _detecting = false;

  @override
  void initState() {
    super.initState();
    final registry = context.read<DeviceRegistry>();
    _d = registry.byId(widget.deviceId)!;
    _c = {
      'name': TextEditingController(text: _d.name),
      'lan': TextEditingController(text: _d.lanHost),
      'remote': TextEditingController(text: _d.remoteHost),
      'http': TextEditingController(text: '${_d.httpPort}'),
      'https': TextEditingController(text: '${_d.httpsPort}'),
      'rtsp': TextEditingController(text: '${_d.rtspPort}'),
      'rtsps': TextEditingController(text: '${_d.rtspsPort}'),
      'channel': TextEditingController(text: '${_d.channel}'),
      'template': TextEditingController(text: _d.rtspPathTemplate),
      'unlock': TextEditingController(text: _d.unlockPath),
      'unlockBody': TextEditingController(text: _d.unlockBody),
      'events': TextEditingController(text: _d.eventIndexPath),
      'alarmOut': TextEditingController(text: '${_d.alarmOutput}'),
      'hold': TextEditingController(text: '${_d.unlockHoldMs}'),
      'netPort': TextEditingController(text: '${_d.netPort}'),
    };
    if (registry.hasOwnCredentials(_d.id)) _user.text = registry.credentialsFor(_d.id)?.username ?? '';
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  int _int(String k, int fallback) => int.tryParse(_c[k]!.text.trim()) ?? fallback;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final registry = context.read<DeviceRegistry>();
    final updated = _d.copyWith(
      name: _c['name']!.text.trim(),
      lanHost: _c['lan']!.text.trim(),
      remoteHost: _c['remote']!.text.trim(),
      httpPort: _int('http', 80),
      httpsPort: _int('https', 443),
      rtspPort: _int('rtsp', 554),
      rtspsPort: _int('rtsps', 322),
      channel: _int('channel', 1),
      rtspPathTemplate: _c['template']!.text.trim(),
      unlockPath: _c['unlock']!.text.trim(),
      unlockBody: _c['unlockBody']!.text,
      eventIndexPath: _c['events']!.text.trim(),
      alarmOutput: _int('alarmOut', 0),
      unlockHoldMs: _int('hold', 1000),
      netPort: _int('netPort', 9008),
    );
    await registry.upsert(updated);
    if (_d.parentId == null && _user.text.trim().isNotEmpty && _pass.text.isNotEmpty) {
      // A new account may use a different password form: learn it afresh.
      await registry.upsert(updated.copyWith(digestPassword: DigestPassword.plain));
      await registry.setCredentials(_d.id, Credentials(_user.text.trim(), _pass.text));
    }
    // Tiles re-check access with the new settings, no manual refresh needed.
    VideoAccessCheck.instance.reset();
    if (mounted) Navigator.of(context).pop();
  }

  /// Reads the real stream path via ONVIF GetProfiles/GetStreamUri.
  Future<void> _detectStream() async {
    final registry = context.read<DeviceRegistry>();
    final messenger = ScaffoldMessenger.of(context);
    final host = _c['lan']!.text.trim();
    if (host.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Enter the LAN host first')));
      return;
    }
    final creds = _pass.text.isNotEmpty
        ? Credentials(_user.text.trim(), _pass.text)
        : registry.credentialsFor(_d.id) ?? const Credentials('', '');
    setState(() => _detecting = true);
    try {
      final xaddr = Uri.parse('http://$host:${_int('http', 80)}/onvif/device_service');
      final profiles = await Onvif.getProfiles(xaddr, username: creds.username, password: creds.password);
      if (profiles.isEmpty) throw Exception('No media profiles');
      // Profile 0 is the main stream; profile 1 (if present) the sub stream.
      final main = await Onvif.getStreamUri(
        xaddr,
        profiles.first.token,
        username: creds.username,
        password: creds.password,
      );
      if (main == null) throw Exception('Device returned no stream URI');
      var template = main.hasQuery ? '${main.path}?${main.query}' : main.path;
      if (profiles.length > 1) {
        final sub = await Onvif.getStreamUri(
          xaddr,
          profiles[1].token,
          username: creds.username,
          password: creds.password,
        );
        final subPath = sub == null ? null : (sub.hasQuery ? '${sub.path}?${sub.query}' : sub.path);
        template = _templateFrom(template, subPath);
      }
      setState(() {
        _c['template']!.text = template;
        if (main.hasPort) _c['rtsp']!.text = '${main.port}';
      });
      messenger.showSnackBar(SnackBar(content: Text('Detected ${profiles.length} profile(s)')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('ONVIF detection failed: $e')));
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  /// Turns "…/main…" + "…/sub…" style pairs into a `{stream}` template.
  static String _templateFrom(String main, String? sub) {
    if (sub == null) return main;
    for (final (m, s) in const [('main', 'sub'), ('Main', 'Sub'), ('0', '1'), ('01', '02'), ('101', '102')]) {
      if (main.replaceFirst(m, s) == sub) {
        return main.replaceFirst(m, m == 'main' || m == 'Main' ? '{stream}' : '{streamIndex}');
      }
    }
    return main;
  }

  Widget _field(String key, String label, {String? hint, bool number = false, int maxLines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: _c[key],
      keyboardType: number ? TextInputType.number : TextInputType.text,
      autocorrect: false,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label, hintText: hint),
      validator: number
          ? (v) {
              final n = int.tryParse(v ?? '');
              return n == null || n < 1 || n > 65535 ? 'Invalid' : null;
            }
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isCamera = _d.parentId != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(_d.name),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field('name', 'Display name'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: _d.enabled,
              onChanged: (v) => setState(() => _d = _d.copyWith(enabled: v)),
            ),
            if (isCamera) ...[
              _field('channel', 'NVR channel', number: true),
              _field('template', 'RTSP path template', hint: DeviceConfig.tvtRtspTemplate),
              const _Hint(
                'Placeholders: {channel}, {channel0}, {stream} (main/sub), {streamIndex} (0/1). '
                'Host, ports and credentials come from the NVR.',
              ),
            ] else ...[
              const _Section('Local network (preferred)'),
              _field('lan', 'LAN IP / hostname', hint: '192.168.1.50'),
              Row(
                children: [
                  Expanded(child: _field('rtsp', 'RTSP port', number: true)),
                  const SizedBox(width: 12),
                  Expanded(child: _field('http', 'HTTP port', number: true)),
                ],
              ),
              const _Section('Remote fallback'),
              DropdownButtonFormField<RemoteMode>(
                initialValue: _d.remoteMode,
                decoration: const InputDecoration(labelText: 'Remote mode'),
                items: const [
                  DropdownMenuItem(value: RemoteMode.disabled, child: Text('Disabled (LAN only)')),
                  DropdownMenuItem(value: RemoteMode.vpn, child: Text('VPN tunnel')),
                  DropdownMenuItem(value: RemoteMode.tls, child: Text('TLS only (rtsps/https)')),
                  DropdownMenuItem(value: RemoteMode.bridge, child: Text('HomeGuard Bridge (P2P)')),
                ],
                onChanged: (m) => setState(() => _d = _d.copyWith(remoteMode: m)),
              ),
              const SizedBox(height: 12),
              if (_d.remoteMode != RemoteMode.disabled) _field('remote', 'Remote host / domain'),
              if (_d.remoteMode == RemoteMode.tls || _d.remoteMode == RemoteMode.bridge)
                Row(
                  children: [
                    Expanded(child: _field('rtsps', 'RTSPS port', number: true)),
                    const SizedBox(width: 12),
                    Expanded(child: _field('https', 'HTTPS port', number: true)),
                  ],
                ),
              if (_d.kind == DeviceKind.doorStation) ...[
                const _Section('Stream'),
                _field('template', 'RTSP path template'),
                OutlinedButton.icon(
                  onPressed: _detecting ? null : _detectStream,
                  icon: _detecting
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_fix_high),
                  label: const Text('Detect via ONVIF'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Two-way audio (ONVIF back-channel)'),
                  value: _d.supportsTalk,
                  onChanged: (v) => setState(() => _d = _d.copyWith(supportsTalk: v)),
                ),
              ],
              if (_d.kind == DeviceKind.doorStation || _d.kind == DeviceKind.indoorMonitor) ...[
                const _Section('Door relay'),
                DropdownButtonFormField<UnlockMethod>(
                  initialValue: _d.unlockVia,
                  decoration: const InputDecoration(labelText: 'Unlock via'),
                  items: const [
                    DropdownMenuItem(value: UnlockMethod.http, child: Text('HTTP / CGI request')),
                    DropdownMenuItem(
                      value: UnlockMethod.tvtAlarmOutput,
                      child: Text('TVT protocol, alarm output (experimental)'),
                    ),
                  ],
                  onChanged: (m) => setState(() => _d = _d.copyWith(unlockVia: m)),
                ),
                const SizedBox(height: 12),
                if (_d.unlockVia == UnlockMethod.tvtAlarmOutput) ...[
                  Row(
                    children: [
                      Expanded(child: _field('alarmOut', 'Alarm output (0 = first)', number: true)),
                      const SizedBox(width: 12),
                      Expanded(child: _field('hold', 'Hold (ms)', number: true)),
                      const SizedBox(width: 12),
                      Expanded(child: _field('netPort', 'Device port', number: true)),
                    ],
                  ),
                  const _Hint(
                    'For TVT-made intercoms (e.g. Techson TCTDB102 / TVT TD-E3110) that have no documented unlock '
                    'API: HomeGuard signs in with the device protocol (port 9008, same account as SuperLive) and '
                    'pulses the relay output. Test it once with the door in view.',
                  ),
                ] else ...[
                  _field(
                    'unlock',
                    'Unlock endpoint (path + query)',
                    hint: '/cgi-bin/accessControl.cgi?action=openDoor&channel=1',
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _d.unlockMethod,
                    decoration: const InputDecoration(labelText: 'HTTP method'),
                    items: const [
                      'GET',
                      'POST',
                      'PUT',
                    ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                    onChanged: (m) => setState(() => _d = _d.copyWith(unlockMethod: m)),
                  ),
                  const SizedBox(height: 12),
                  if (_d.unlockMethod != 'GET') _field('unlockBody', 'Request body (optional)', maxLines: 3),
                  const _Hint(
                    'Use the relay API documented for your door station firmware. '
                    'The request is sent with Digest/Basic auth to the resolved LAN or secure remote address.',
                  ),
                ],
              ],
              if (_d.kind == DeviceKind.indoorMonitor) ...[
                const _Section('Event storage'),
                _field('events', 'SD-card index path', hint: '/sdcard/snapshot/'),
                const _Hint('A JSON file list or an HTML directory listing of stored snapshots and clips.'),
              ],
              const _Section('Credentials'),
              if (_d.kind != DeviceKind.nvr) const _Hint('Leave empty to use the NVR account.'),
              TextFormField(
                controller: _user,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Username'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Password (unchanged if empty)'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primary),
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
  );
}
