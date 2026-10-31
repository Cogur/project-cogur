import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/models/security_event.dart';
import '../../core/services/device_registry.dart';
import '../../core/services/event_store.dart';
import '../../theme/app_theme.dart';
import '../events/event_widgets.dart';
import '../live/device_stream_view.dart';
import '../live/stream_actions.dart';
import 'unlock_flow.dart';

class AccessControlPage extends StatelessWidget {
  const AccessControlPage({super.key});

  static const _accessTypes = {EventType.doorUnlocked, EventType.rfidAccess, EventType.doorbellRing};

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final door = registry.firstOfKind(DeviceKind.doorStation);
    final targets = registry.unlockable;
    final log = context
        .watch<EventStore>()
        .events
        .where((e) => _accessTypes.contains(e.type) || (e.note?.startsWith('Unlock FAILED') ?? false))
        .take(30)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Access Control')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (door != null && door.enabled)
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        DeviceStreamView(
                          deviceId: door.id,
                          quality: StreamQuality.sub,
                          playerTag: 'access-door',
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 8,
                          child: StreamActions(deviceId: door.id, playerTag: 'access-door', compact: true),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.doorbell_outlined),
                    title: Text(door.name),
                    subtitle: const Text('Tap to open fullscreen with talk'),
                    trailing: const Icon(Icons.open_in_full),
                    onTap: () => context.push('/live/${door.id}'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (targets.isEmpty)
            Card(
              child: ListTile(
                leading: const Icon(Icons.lock_open),
                title: const Text('Set up door unlock'),
                subtitle: Text(
                  'Opens ${door?.name ?? 'the door station'} settings. Under "Door relay" choose '
                  '"Unlock via": TVT protocol (experimental) or an HTTP/CGI request.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: door == null ? null : () => context.push('/settings/device/${door.id}'),
              ),
            )
          else
            for (final t in targets) ...[
              _HoldToUnlock(
                label: 'Hold to unlock ${t.name}',
                onUnlock: () => confirmAndUnlock(context, t.id),
              ),
              const SizedBox(height: 12),
            ],
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              'Access log',
              style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textMuted),
            ),
          ),
          if (log.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No access events recorded on this device yet.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ),
          for (final e in log)
            ListTile(
              dense: true,
              leading: Icon(eventIcon(e.type), color: eventColor(e.type)),
              title: Text(e.note ?? e.type.label, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(DateFormat.MMMd().add_Hms().format(e.timestamp)),
              onTap: e.mediaPath == null ? null : () => context.push('/events/detail', extra: e),
            ),
        ],
      ),
    );
  }
}

/// Requires a 1-second press so a pocket tap cannot open the door.
class _HoldToUnlock extends StatefulWidget {
  const _HoldToUnlock({required this.label, required this.onUnlock});
  final String label;
  final Future<void> Function() onUnlock;

  @override
  State<_HoldToUnlock> createState() => _HoldToUnlockState();
}

class _HoldToUnlockState extends State<_HoldToUnlock> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))
        ..addStatusListener((s) async {
          if (s == AnimationStatus.completed) {
            await widget.onUnlock();
            if (mounted) _ctrl.reset();
          }
        });

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        if (!_ctrl.isCompleted) _ctrl.reverse();
      },
      onTapCancel: () {
        if (!_ctrl.isCompleted) _ctrl.reverse();
      },
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) => Container(
          height: 64,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.secure.withValues(alpha: 0.6)),
            gradient: LinearGradient(
              stops: [_ctrl.value, _ctrl.value],
              colors: [AppColors.secure.withValues(alpha: 0.45), AppColors.secure.withValues(alpha: 0.08)],
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_open, color: AppColors.secure),
              const SizedBox(width: 10),
              Text(widget.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
