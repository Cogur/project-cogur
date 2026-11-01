import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/services/device_registry.dart';
import '../../core/services/intercom_service.dart';
import '../settings/settings_controller.dart';
import 'device_stream_view.dart';
import 'stream_actions.dart';

class FullscreenPlayerPage extends StatefulWidget {
  const FullscreenPlayerPage({super.key, required this.deviceId});
  final String deviceId;

  @override
  State<FullscreenPlayerPage> createState() => _FullscreenPlayerPageState();
}

class _FullscreenPlayerPageState extends State<FullscreenPlayerPage> {
  // Starts in the quality chosen in Settings; the HD/SD button switches.
  late StreamQuality _quality = context.read<SettingsController>().preferHd
      ? StreamQuality.main
      : StreamQuality.sub;
  bool _muted = false;
  bool _chrome = true;
  Timer? _hide;
  IntercomService? _talk;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _scheduleHide();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _talk = context.read<IntercomService>();
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    if (_talk?.activeDevice == widget.deviceId) _talk?.stop();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = context.watch<DeviceRegistry>().byId(widget.deviceId);
    final tag = 'full-${widget.deviceId}';
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _chrome = !_chrome);
          if (_chrome) _scheduleHide();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              maxScale: 4,
              child: DeviceStreamView(
                deviceId: widget.deviceId,
                quality: _quality,
                muted: _muted,
                fit: BoxFit.contain,
                playerTag: tag,
              ),
            ),
            AnimatedOpacity(
              opacity: _chrome ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_chrome,
                child: SafeArea(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const BackButton(color: Colors.white),
                          Expanded(
                            child: Text(
                              device?.name ?? '',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: _muted ? 'Unmute' : 'Mute',
                            color: Colors.white,
                            icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                            onPressed: () => setState(() => _muted = !_muted),
                          ),
                          TextButton(
                            onPressed: () => setState(
                              () => _quality = _quality == StreamQuality.main
                                  ? StreamQuality.sub
                                  : StreamQuality.main,
                            ),
                            child: Text(
                              _quality == StreamQuality.main ? 'HD' : 'SD',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 24),
                        child: StreamActions(deviceId: widget.deviceId, playerTag: tag),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
