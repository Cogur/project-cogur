import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/app_services.dart';
import '../../core/models/device.dart';
import '../../core/network/connection_manager.dart';
import '../../core/onvif/onvif_client.dart';
import '../../core/services/device_registry.dart';
import '../../core/utils/log.dart';
import '../../custom_code/actions/probe_rtsp_stream.dart';
import '../../theme/app_theme.dart';
import '../auth/auth_controller.dart';
import '../live/device_stream_view.dart';
import 'settings_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    final registry = context.watch<DeviceRegistry>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings & Network')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header('Network status'),
          const _NetworkStatusCard(),
          const _Header('Devices'),
          for (final d in registry.devices)
            ListTile(
              leading: Icon(_kindIcon(d.kind)),
              title: Text(d.name),
              subtitle: Text(_deviceSubtitle(d, registry)),
              trailing: d.enabled ? const Icon(Icons.chevron_right) : const Text('Disabled'),
              onTap: () => context.push('/settings/device/${d.id}'),
            ),
          ListTile(
            leading: const Icon(Icons.travel_explore),
            title: const Text('Discover ONVIF devices on LAN'),
            subtitle: const Text('Finds the door station and indoor monitor'),
            onTap: () => _discover(context),
          ),
          ListTile(
            leading: const Icon(Icons.network_check),
            title: const Text('Device diagnostics'),
            subtitle: const Text('What each device supports; shareable report'),
            onTap: () => context.push('/settings/diagnostics'),
          ),
          const _Header('Streaming'),
          SwitchListTile(
            title: const Text('HD video'),
            subtitle: const Text(
              'Off: SD (starts faster, fewer stalls). On: HD for live view and recordings. '
              'Fullscreen can switch either way.',
            ),
            value: settings.preferHd,
            onChanged: (v) => settings.update(preferHd: v),
          ),
          SwitchListTile(
            title: const Text('Mute audio in grid'),
            value: settings.muteGridAudio,
            onChanged: (v) => settings.update(muteGridAudio: v),
          ),
          const _Header('Security'),
          ListTile(
            leading: const Icon(Icons.timer_outlined),
            title: const Text('Auto-lock'),
            subtitle: Text(
              settings.autoLockMinutes == 0
                  ? 'Immediately when the app leaves the screen'
                  : 'After ${settings.autoLockMinutes} min in background',
            ),
            trailing: DropdownButton<int>(
              value: settings.autoLockMinutes,
              underline: const SizedBox.shrink(),
              items: const [
                0,
                1,
                5,
                15,
                30,
              ].map((m) => DropdownMenuItem(value: m, child: Text(m == 0 ? 'Now' : '$m min'))).toList(),
              onChanged: (v) => settings.update(autoLockMinutes: v),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Biometric confirmation for door unlock'),
            subtitle: const Text('Recommended. Falls back to a confirmation dialog if unavailable.'),
            value: settings.confirmUnlockWithBiometrics,
            onChanged: (v) => settings.update(confirmUnlockWithBiometrics: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.screenshot_outlined),
            title: const Text('Allow screenshots'),
            subtitle: const Text(
              'Off keeps camera pictures out of screenshots, screen recordings and recent apps',
            ),
            value: settings.allowScreenshots,
            onChanged: (v) => settings.update(allowScreenshots: v),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () => context.read<AuthController>().signOut(),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: AppColors.danger),
            title: const Text('Erase all data on this device', style: TextStyle(color: AppColors.danger)),
            subtitle: const Text('Credentials, device settings, snapshots and logs'),
            onTap: () => _wipe(context),
          ),
        ],
      ),
    );
  }

  static IconData _kindIcon(DeviceKind k) => switch (k) {
    DeviceKind.nvr => Icons.dns_outlined,
    DeviceKind.camera => Icons.videocam_outlined,
    DeviceKind.doorStation => Icons.doorbell_outlined,
    DeviceKind.indoorMonitor => Icons.tablet_android_outlined,
  };

  static String _deviceSubtitle(DeviceConfig d, DeviceRegistry r) {
    if (d.parentId != null) return 'Channel ${d.channel} via ${r.byId(d.parentId!)?.name ?? 'NVR'}';
    return d.lanHost.isEmpty ? 'Not configured' : d.lanHost;
  }

  Future<void> _discover(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text('Searching LAN…')]),
      ),
    );
    List<OnvifDevice> found;
    try {
      found = await Onvif.discover();
    } catch (e) {
      found = [];
      Log.w('onvif', 'discovery failed: $e');
    }
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (found.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('No ONVIF devices answered')));
      return;
    }
    final registry = context.read<DeviceRegistry>();
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Assign discovered device')),
            for (final d in found)
              ExpansionTile(
                leading: const Icon(Icons.router_outlined),
                title: Text(d.address.address),
                subtitle: Text(d.label.isEmpty ? d.xaddrs.first.toString() : d.label),
                children: [
                  for (final target in registry.devices.where((x) => x.parentId == null))
                    ListTile(
                      title: Text('Use as ${target.name}'),
                      onTap: () async {
                        await registry.upsert(target.copyWith(lanHost: d.address.address));
                        if (c.mounted) Navigator.pop(c);
                        messenger.showSnackBar(
                          SnackBar(content: Text('${target.name} → ${d.address.address}')),
                        );
                      },
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _wipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Erase everything?'),
        content: const Text(
          'This removes all credentials, settings and stored snapshots from this phone. '
          'Recordings on the NVR are not affected.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Erase'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final services = context.read<AppServices>();
    final auth = context.read<AuthController>();
    await services.events.wipe();
    await services.store.wipe();
    await auth.signOut(forget: true);
    await services.registry.load();
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        letterSpacing: 1.1,
        color: AppColors.textMuted,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _NetworkStatusCard extends StatefulWidget {
  const _NetworkStatusCard();
  @override
  State<_NetworkStatusCard> createState() => _NetworkStatusCardState();
}

class _NetworkStatusCardState extends State<_NetworkStatusCard> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    final conn = context.read<ConnectionManager>();
    final ids = context.read<DeviceRegistry>().devices.where((d) => d.parentId == null).map((d) => d.id);
    setState(() => _refreshing = true);
    await Future.wait(ids.map((id) => conn.resolve(id, force: true)));
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _probe(DeviceConfig d) async {
    final target = d.kind == DeviceKind.nvr
        ? context.read<DeviceRegistry>().devices.firstWhere((x) => x.parentId == d.id, orElse: () => d)
        : d;
    final result = await probeRtspStream(target.id) as Map;
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${target.name} stream'),
        content: Text(
          result['ok'] == true
              ? 'Route: ${result['route']}\n'
                    'RTSP handshake: ${result['latencyMs']} ms\n'
                    'Video: ${result['video']}\n'
                    'Audio: ${result['audio']}\n'
                    'Two-way audio back-channel: ${result['backchannel'] == true ? 'yes' : 'no'}\n'
                    'Server: ${result['server'] ?? '-'}'
              : 'Failed: ${result['error']}',
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionManager>();
    final hosts = context.watch<DeviceRegistry>().devices.where((d) => d.parentId == null && d.enabled);
    final net = conn.network.map((n) => n.name).join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('This phone'),
              subtitle: Text(net.isEmpty ? 'Checking…' : net),
              trailing: IconButton(
                tooltip: 'Re-probe all devices',
                onPressed: _refreshing ? null : _refresh,
                icon: _refreshing
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
            ),
            const Divider(height: 1),
            for (final d in hosts)
              ListTile(
                title: Text(d.name),
                subtitle: Text(_routeText(conn.cached(d.id))),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (conn.cached(d.id) case final r?) RouteBadge(route: r),
                    if (d.kind != DeviceKind.indoorMonitor)
                      IconButton(
                        tooltip: 'Probe stream',
                        icon: const Icon(Icons.speed),
                        onPressed: () => _probe(d),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _routeText(ResolvedRoute? r) {
    if (r == null) return 'Not checked';
    if (!r.reachable) return 'Unreachable';
    final ms = r.latency?.inMilliseconds;
    return '${r.host}:${r.rtspPort}${ms == null ? '' : ' · $ms ms'}';
  }
}
