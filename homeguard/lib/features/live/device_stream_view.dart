import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/device.dart';
import '../../core/network/connection_manager.dart';
import '../../core/network/device_http_client.dart';
import '../../core/services/device_registry.dart';
import '../../core/tvt/tvt_lapi_client.dart';
import '../../custom_code/widgets/rtsp_player_widget.dart';
import '../../theme/app_theme.dart';
import 'video_access.dart';

/// Resolves a device to its best route (LAN → remote) and hosts the RTSP
/// player. Re-resolves when the network changes.
class DeviceStreamView extends StatefulWidget {
  const DeviceStreamView({
    super.key,
    required this.deviceId,
    required this.quality,
    this.muted = true,
    this.fit = BoxFit.cover,
    this.playerTag,
    this.showRouteBadge = true,
  });

  final String deviceId;
  final StreamQuality quality;
  final bool muted;
  final BoxFit fit;
  final String? playerTag;
  final bool showRouteBadge;

  @override
  State<DeviceStreamView> createState() => _DeviceStreamViewState();
}

class _DeviceStreamViewState extends State<DeviceStreamView> {
  Future<ResolvedRoute>? _route;
  ConnectionManager? _connections;

  Future<VideoAccess>? _access;

  void _onAccessReset() {
    if (mounted) setState(() => _access = null);
  }

  @override
  void initState() {
    super.initState();
    VideoAccessCheck.instance.generation.addListener(_onAccessReset);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<ConnectionManager>();
    if (!identical(c, _connections)) {
      _connections?.removeListener(_onNetwork);
      _connections = c..addListener(_onNetwork);
      _resolve();
    }
  }

  void _onNetwork() {
    // Cache was invalidated (network change) → resolve again.
    if (_connections!.cached(widget.deviceId) == null) _resolve();
  }

  void _resolve({bool force = false}) {
    setState(() => _route = _connections!.resolve(widget.deviceId, force: force));
  }

  @override
  void dispose() {
    VideoAccessCheck.instance.generation.removeListener(_onAccessReset);
    _connections?.removeListener(_onNetwork);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<DeviceRegistry>();
    final device = registry.byId(widget.deviceId);
    if (device == null) return const _Placeholder(icon: Icons.help_outline, text: 'Unknown device');

    return FutureBuilder<ResolvedRoute>(
      future: _route,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Placeholder(icon: Icons.radar, text: 'Locating device…', busy: true);
        }
        final route = snap.data;
        if (route == null || !route.reachable) {
          return _Placeholder(
            icon: Icons.portable_wifi_off,
            text: 'Device unreachable',
            onRetry: () => _resolve(force: true),
          );
        }
        final creds = registry.streamCredentialsFor(device.id, viaBridge: route.bridge);
        if (creds == null) return const _Placeholder(icon: Icons.lock_outline, text: 'Not signed in');
        final path = route.streamPath(device, widget.quality);
        final lapi = route.bridge || device.kind != DeviceKind.camera
            ? null
            : TvtLapiClient(host: route.host, port: route.httpPort, secure: route.secure, credentials: creds);
        final owner = registry.credentialOwner(device.id);
        _access ??= VideoAccessCheck.instance.check(
          key: '${route.host}:${route.rtspPort}',
          rtspUri: route.rtspUri(path),
          plain: registry.credentialsFor(device.id)!,
          form: route.bridge ? DigestPassword.plain : (owner?.digestPassword ?? DigestPassword.plain),
          // Only learn a form for the device whose own account this is (a
          // door station borrowing the NVR account must not change the NVR's).
          tryOtherForms: !route.bridge && owner != null && owner.id == (device.parentId ?? device.id),
          pictures: lapi == null
              ? null
              : (c) => TvtLapiClient(
                  host: route.host,
                  port: route.httpPort,
                  secure: route.secure,
                  credentials: c,
                ),
          channel: device.channel,
          onForm: (f) => registry.upsert(owner!.copyWith(digestPassword: f)),
        );
        return FutureBuilder<VideoAccess>(
          future: _access,
          builder: (context, access) {
            if (access.connectionState != ConnectionState.done) {
              return const _Placeholder(icon: Icons.radar, text: 'Connecting…', busy: true);
            }
            final Widget content = switch (access.data ?? VideoAccess.video) {
              VideoAccess.video => RtspPlayerWidget(
                key: ValueKey('${widget.deviceId}-${widget.quality.name}-${route.host}'),
                rtspUrl: route.rtspUrl(path, creds),
                muted: widget.muted,
                fit: widget.fit,
                playerTag: widget.playerTag,
              ),
              VideoAccess.pictures when lapi != null => _SnapshotView(
                key: ValueKey('snap-${widget.deviceId}-${route.host}'),
                client: lapi,
                channel: device.channel,
                fit: widget.fit,
                onRetryVideo: VideoAccessCheck.instance.reset,
              ),
              _ => _Placeholder(
                icon: Icons.no_encryption_gmailerrorred_outlined,
                text: device.parentId == null && device.kind != DeviceKind.nvr
                    ? '${device.name} refuses this login.\nSet its own username/password:\nSettings → ${device.name} → Credentials'
                    : 'The NVR refuses this login for video.\nDetails: Settings → Device diagnostics',
                onRetry: VideoAccessCheck.instance.reset,
              ),
            };
            return Stack(
              fit: StackFit.expand,
              children: [
                content,
                if (widget.showRouteBadge) Positioned(top: 8, right: 8, child: RouteBadge(route: route)),
              ],
            );
          },
        );
      },
    );
  }
}

class RouteBadge extends StatelessWidget {
  const RouteBadge({super.key, required this.route});
  final ResolvedRoute route;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (route.kind) {
      RouteKind.lan => ('LAN', AppColors.secure, Icons.lan),
      RouteKind.remote when route.bridge => ('P2P', AppColors.warning, Icons.hub_outlined),
      RouteKind.remote => (route.secure ? 'TLS' : 'VPN', AppColors.warning, Icons.vpn_lock),
      RouteKind.unreachable => ('OFF', AppColors.danger, Icons.link_off),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, required this.text, this.busy = false, this.onRetry});
  final IconData icon;
  final String text;
  final bool busy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          busy
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(icon, color: Colors.white54),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}

/// About one picture per second from the recorder's HTTP API.
class _SnapshotView extends StatefulWidget {
  const _SnapshotView({
    super.key,
    required this.client,
    required this.channel,
    required this.fit,
    required this.onRetryVideo,
  });
  final TvtLapiClient client;
  final int channel;
  final BoxFit fit;
  final VoidCallback onRetryVideo;

  @override
  State<_SnapshotView> createState() => _SnapshotViewState();
}

class _SnapshotViewState extends State<_SnapshotView> {
  Uint8List? _jpeg;
  String? _error;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_stopped) {
      final started = DateTime.now();
      try {
        final jpeg = await widget.client.snapshot(widget.channel);
        if (!mounted) return;
        setState(() {
          _jpeg = jpeg;
          _error = null;
        });
      } on DeviceHttpException catch (e) {
        if (!mounted) return;
        setState(() => _error = '$e');
        // Refused login: stop, every attempt counts as an illegal login.
        if (e.statusCode == 401 || e.statusCode == 403) return;
        await Future<void>.delayed(const Duration(seconds: 4));
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = '$e');
        await Future<void>.delayed(const Duration(seconds: 4));
      }
      final wait = const Duration(seconds: 1) - DateTime.now().difference(started);
      if (!wait.isNegative) await Future<void>.delayed(wait);
    }
  }

  @override
  void dispose() {
    _stopped = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: _jpeg == null ? null : Image.memory(_jpeg!, fit: widget.fit, gaplessPlayback: true),
        ),
        if (_jpeg == null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error == null ? 'Loading picture…' : 'Video and picture unavailable:\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ),
        Positioned(
          left: 8,
          bottom: 8,
          child: GestureDetector(
            onTap: widget.onRetryVideo,
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.all(Radius.circular(6)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  'PICTURE 1/s · tap for video',
                  style: TextStyle(color: AppColors.warning, fontSize: 10),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
