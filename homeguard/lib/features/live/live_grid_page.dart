import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/network/connection_manager.dart';
import '../../core/services/device_registry.dart';
import '../../theme/app_theme.dart';
import '../settings/settings_controller.dart';
import 'device_stream_view.dart';

class LiveGridPage extends StatelessWidget {
  const LiveGridPage({super.key});

  @override
  Widget build(BuildContext context) {
    final devices = context.watch<DeviceRegistry>().videoDevices;
    final settings = context.watch<SettingsController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live'),
        actions: [
          IconButton(
            tooltip: 'Reconnect all',
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<ConnectionManager>().invalidate(),
          ),
        ],
      ),
      body: devices.isEmpty
          ? const Center(
              child: Text('No cameras configured', style: TextStyle(color: AppColors.textMuted)),
            )
          : LayoutBuilder(
              builder: (context, c) {
                final columns = c.maxWidth > 900 ? 3 : (c.maxWidth > 500 || devices.length > 1 ? 2 : 1);
                return GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 16 / 9,
                  ),
                  itemCount: devices.length,
                  itemBuilder: (context, i) => _CameraTile(
                    device: devices[i],
                    quality: settings.preferHd ? StreamQuality.main : StreamQuality.sub,
                    muted: settings.muteGridAudio,
                  ),
                );
              },
            ),
    );
  }
}

class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.device, required this.quality, required this.muted});
  final DeviceConfig device;
  final StreamQuality quality;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DeviceStreamView(
            deviceId: device.id,
            quality: quality,
            muted: muted,
            playerTag: 'grid-${device.id}',
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    device.kind == DeviceKind.doorStation ? Icons.doorbell_outlined : Icons.videocam_outlined,
                    size: 14,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      device.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(onTap: () => context.push('/live/${device.id}')),
          ),
        ],
      ),
    );
  }
}
