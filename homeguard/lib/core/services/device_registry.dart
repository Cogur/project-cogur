import 'package:flutter/foundation.dart';

import '../models/device.dart';
import '../network/connection_manager.dart';
import '../security/secure_store.dart';

/// Owns the device topology and per-device credentials.
class DeviceRegistry extends ChangeNotifier {
  DeviceRegistry(this._store, this._connections);

  final SecureStore _store;
  final ConnectionManager _connections;
  List<DeviceConfig> _devices = const [];
  final Map<String, Credentials> _creds = {};

  List<DeviceConfig> get devices => _devices;
  List<DeviceConfig> get videoDevices => _devices.where((d) => d.hasVideo && d.enabled).toList();
  DeviceConfig? byId(String id) => _devices.where((d) => d.id == id).firstOrNull;
  DeviceConfig? firstOfKind(DeviceKind k) => _devices.where((d) => d.kind == k).firstOrNull;
  List<DeviceConfig> get unlockable => _devices.where((d) => d.canUnlock && d.enabled).toList();
  bool get loaded => _devices.isNotEmpty;

  Future<void> load() async {
    _devices = await _store.readDevices() ?? DeviceConfig.defaultTopology();
    _creds.clear();
    for (final d in _devices.where((d) => d.parentId == null)) {
      final c = await _store.readCredentials(d.id);
      if (c != null) _creds[d.id] = c;
    }
    _connections.updateDevices(_devices);
    notifyListeners();
  }

  /// Credentials for [deviceId]; cameras inherit their NVR's. Door station
  /// and indoor monitor fall back to the NVR account when none are set,
  /// which matches typical single-account Techson installs.
  Credentials? credentialsFor(String deviceId) {
    final d = byId(deviceId);
    if (d == null) return null;
    final owner = d.parentId ?? d.id;
    return _creds[owner] ?? _creds['nvr'];
  }

  /// Credentials for RTSP and device HTTP (Digest) calls: the password in the
  /// form the owning device expects (see [DigestPassword]).
  Credentials? mediaCredentialsFor(String deviceId) {
    final d = byId(deviceId);
    if (d == null) return null;
    final owner = d.parentId ?? d.id;
    final ownerId = _creds.containsKey(owner) ? owner : 'nvr';
    final c = _creds[ownerId];
    if (c == null) return null;
    final mode = byId(ownerId)?.digestPassword ?? DigestPassword.plain;
    return mode == DigestPassword.plain ? c : Credentials(c.username, mode.apply(c.password));
  }

  /// The device whose stored account (and Digest password form) is used for
  /// [deviceId]: itself, its recorder, or the NVR as fallback.
  DeviceConfig? credentialOwner(String deviceId) {
    final d = byId(deviceId);
    if (d == null) return null;
    final owner = d.parentId ?? d.id;
    return byId(_creds.containsKey(owner) ? owner : 'nvr');
  }

  /// A HomeGuard Bridge checks its own account as typed; the recorder itself
  /// may want the Digest form.
  Credentials? streamCredentialsFor(String deviceId, {required bool viaBridge}) =>
      viaBridge ? credentialsFor(deviceId) : mediaCredentialsFor(deviceId);

  bool hasOwnCredentials(String deviceId) => _creds.containsKey(deviceId);

  Future<void> setCredentials(String deviceId, Credentials? c) async {
    if (c == null || c.isEmpty) {
      _creds.remove(deviceId);
      await _store.deleteCredentials(deviceId);
    } else {
      _creds[deviceId] = c;
      await _store.writeCredentials(deviceId, c);
    }
    notifyListeners();
  }

  Future<void> upsert(DeviceConfig device) async {
    final i = _devices.indexWhere((d) => d.id == device.id);
    _devices = [..._devices];
    if (i < 0) {
      _devices.add(device);
    } else {
      _devices[i] = device;
    }
    await _store.writeDevices(_devices);
    _connections.updateDevices(_devices);
    notifyListeners();
  }

  /// Called after a successful login: records the NVR host the user typed.
  Future<void> configureNvr(String host, Credentials c) async {
    if (!loaded) await load();
    final nvr = firstOfKind(DeviceKind.nvr)!;
    await upsert(nvr.copyWith(lanHost: host));
    await setCredentials(nvr.id, c);
  }

  /// Drops cached credentials from memory (on lock / logout).
  void clearMemory() {
    _creds.clear();
  }
}
