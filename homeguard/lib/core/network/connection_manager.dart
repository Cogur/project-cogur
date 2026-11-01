import 'dart:async';

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/device.dart';
import '../security/secure_store.dart';
import '../utils/log.dart';
import 'reachability.dart';

enum RouteKind { lan, remote, unreachable }

typedef HostLookup = Future<List<InternetAddress>> Function(String host);

class DeviceUnreachableException implements Exception {
  DeviceUnreachableException(this.device, this.reason);
  final DeviceConfig device;
  final String reason;
  @override
  String toString() => '${device.name} is unreachable: $reason';
}

/// Where and how to talk to a device right now.
class ResolvedRoute {
  const ResolvedRoute({
    required this.kind,
    required this.host,
    required this.rtspPort,
    required this.httpPort,
    required this.secure,
    required this.latency,
    required this.checkedAt,
    this.bridge = false,
  });

  const ResolvedRoute.unreachable(this.checkedAt)
    : kind = RouteKind.unreachable,
      host = '',
      rtspPort = 0,
      httpPort = 0,
      secure = false,
      bridge = false,
      latency = null;

  final RouteKind kind;
  final String host;
  final int rtspPort;
  final int httpPort;

  /// True when the transport itself is encrypted (rtsps/https).
  final bool secure;

  /// Route goes through a HomeGuard Bridge (different stream names, HTTPS API).
  final bool bridge;
  final Duration? latency;
  final DateTime checkedAt;

  bool get reachable => kind != RouteKind.unreachable;

  String streamPath(DeviceConfig d, StreamQuality q) => bridge ? d.bridgePath(q) : d.rtspPath(q);
  String get rtspScheme => secure ? 'rtsps' : 'rtsp';
  String get httpScheme => secure ? 'https' : 'http';

  Uri httpUri(String pathAndQuery) =>
      Uri.parse('$httpScheme://${_bracket(host)}:$httpPort${_slash(pathAndQuery)}');

  /// RTSP URL for the native player, credentials embedded (never logged).
  String rtspUrl(String path, Credentials? c) {
    final auth = c == null || c.isEmpty
        ? ''
        : '${Uri.encodeComponent(c.username)}:${Uri.encodeComponent(c.password)}@';
    return '$rtspScheme://$auth${_bracket(host)}:$rtspPort${_slash(path)}';
  }

  /// RTSP URL without credentials, for the control client.
  Uri rtspUri(String path) => Uri.parse('$rtspScheme://${_bracket(host)}:$rtspPort${_slash(path)}');

  static String _slash(String p) => p.startsWith('/') ? p : '/$p';
  static String _bracket(String h) => h.contains(':') && !h.startsWith('[') ? '[$h]' : h;
}

/// Resolves every device to the best available route: LAN first, then the
/// configured secure remote path. Results are cached briefly and invalidated
/// whenever the phone's network changes (Wi-Fi ↔ cellular, VPN up/down).
class ConnectionManager extends ChangeNotifier {
  ConnectionManager({
    TcpProbe probe = defaultTcpProbe,
    HostLookup lookup = InternetAddress.lookup,
    Stream<List<ConnectivityResult>>? connectivity,
    this.lanTimeout = const Duration(milliseconds: 1500),
    this.remoteTimeout = const Duration(seconds: 3),
    this.cacheTtl = const Duration(seconds: 30),
  }) : _probe = probe,
       _lookup = lookup {
    _connSub = (connectivity ?? Connectivity().onConnectivityChanged).listen((r) {
      _network = r;
      Log.d('net', 'connectivity changed: $r');
      invalidate();
    });
  }

  final TcpProbe _probe;
  final HostLookup _lookup;
  final Duration lanTimeout;
  final Duration remoteTimeout;
  final Duration cacheTtl;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  List<ConnectivityResult> _network = const [];
  final Map<String, ResolvedRoute> _routes = {};
  final Map<String, Future<ResolvedRoute>> _inflight = {};
  int _generation = 0;
  List<DeviceConfig> _devices = const [];

  List<ConnectivityResult> get network => _network;
  bool get offline => _network.isNotEmpty && _network.every((r) => r == ConnectivityResult.none);

  ResolvedRoute? cached(String deviceId) => _routes[_hostDevice(deviceId)?.id ?? deviceId];

  void updateDevices(List<DeviceConfig> devices) {
    _devices = devices;
    invalidate();
  }

  DeviceConfig? device(String id) => _devices.where((d) => d.id == id).firstOrNull;

  /// Cameras stream through their NVR; everything else is its own host.
  DeviceConfig? _hostDevice(String deviceId) {
    final d = device(deviceId);
    if (d == null) return null;
    return d.parentId == null ? d : device(d.parentId!) ?? d;
  }

  void invalidate() {
    _generation++;
    _routes.clear();
    _inflight.clear();
    notifyListeners();
  }

  /// One-off TCP check, used for diagnostics (e.g. "web page answers but
  /// the video port is closed").
  Future<bool> isPortOpen(String host, int port) async => await _probe(host, port, lanTimeout) != null;

  Future<ResolvedRoute> resolve(String deviceId, {bool force = false}) {
    final host = _hostDevice(deviceId);
    if (host == null) {
      return Future.value(ResolvedRoute.unreachable(DateTime.now()));
    }
    final hit = _routes[host.id];
    if (!force && hit != null && DateTime.now().difference(hit.checkedAt) < cacheTtl) {
      return Future.value(hit);
    }
    // Block body: returning the removed future from whenComplete would make
    // the in-flight future wait on itself.
    return _inflight[host.id] ??= _resolve(host).whenComplete(() {
      _inflight.remove(host.id);
    });
  }

  /// Like [resolve] but throws when nothing answers.
  Future<ResolvedRoute> require(String deviceId) async {
    final r = await resolve(deviceId);
    if (!r.reachable) {
      final d = _hostDevice(deviceId);
      throw DeviceUnreachableException(
        d ?? device(deviceId)!,
        d?.remoteMode == RemoteMode.disabled
            ? 'not found on the local network'
            : 'not reachable on LAN or remote route',
      );
    }
    return r;
  }

  Future<ResolvedRoute> _resolve(DeviceConfig d) async {
    final gen = _generation;
    final now = DateTime.now();
    ResolvedRoute? result;

    // 1. LAN — lowest latency, never leaves the building.
    if (d.lanHost.isNotEmpty) {
      final port = d.kind == DeviceKind.indoorMonitor ? d.httpPort : d.rtspPort;
      // Wi-Fi intercoms answer slower than the wired recorder.
      final wireless = d.kind == DeviceKind.doorStation || d.kind == DeviceKind.indoorMonitor;
      final rtt = await _probe(d.lanHost, port, wireless ? lanTimeout * 2 : lanTimeout);
      if (rtt != null) {
        result = ResolvedRoute(
          kind: RouteKind.lan,
          host: d.lanHost,
          rtspPort: d.rtspPort,
          httpPort: d.httpPort,
          secure: false,
          latency: rtt,
          checkedAt: now,
        );
      }
    }

    // 2. Remote — only over a trusted tunnel or TLS.
    if (result == null &&
        d.remoteMode != RemoteMode.disabled &&
        d.remoteHost.isNotEmpty &&
        (d.remoteMode != RemoteMode.vpn || await _isTunnelAddress(d.remoteHost))) {
      final tls = d.remoteMode != RemoteMode.vpn;
      final rtspPort = tls ? d.rtspsPort : d.rtspPort;
      final httpPort = tls ? d.httpsPort : d.httpPort;
      final port = d.kind == DeviceKind.indoorMonitor ? httpPort : rtspPort;
      final rtt = await _probe(d.remoteHost, port, remoteTimeout);
      if (rtt != null) {
        result = ResolvedRoute(
          kind: RouteKind.remote,
          host: d.remoteHost,
          rtspPort: rtspPort,
          httpPort: httpPort,
          secure: tls,
          bridge: d.remoteMode == RemoteMode.bridge,
          latency: rtt,
          checkedAt: now,
        );
      }
    }

    result ??= ResolvedRoute.unreachable(now);
    if (gen == _generation) {
      final previous = _routes[d.id];
      _routes[d.id] = result;
      if (previous?.kind != result.kind) {
        Log.w('net', '${d.name}: route ${previous?.kind.name ?? '-'} → ${result.kind.name}');
      }
      notifyListeners();
    }
    return result;
  }

  /// VPN mode sends plain RTSP/HTTP, so the remote host must resolve to a
  /// private/tunnel address (WireGuard 10.x, Tailscale 100.64/10, ULA …).
  /// A public address means the "VPN" is a misconfiguration that would leak
  /// credentials in cleartext, so the route is refused.
  Future<bool> _isTunnelAddress(String host) async {
    try {
      final addrs = await _lookup(host).timeout(const Duration(seconds: 2));
      final ok = addrs.isNotEmpty && addrs.every(isPrivateAddress);
      if (!ok) {
        Log.w('net', 'VPN route $host resolves to a public address — refusing plaintext; use TLS mode');
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }
}
