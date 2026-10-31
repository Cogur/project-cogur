import '../bridge/bridge_client.dart';
import '../models/device.dart';
import '../models/security_event.dart';
import '../network/connection_manager.dart';
import '../network/device_http_client.dart';
import '../tvt/tvt_net_client.dart';
import 'device_registry.dart';
import 'event_store.dart';

class UnlockResult {
  const UnlockResult.success(this.message) : ok = true;
  const UnlockResult.failure(this.message) : ok = false;
  final bool ok;
  final String message;
}

typedef TvtConnector = Future<TvtNetClient> Function(String host, int port);

/// Fires the door station / indoor monitor relay: HTTP/CGI, the TVT device
/// protocol (alarm output), or through a HomeGuard Bridge.
///
/// Every attempt — successful or not — is written to the local audit log.
class DoorRelayService {
  DoorRelayService(this._registry, this._connections, this._http, this._events, {TvtConnector? tvt})
    : _tvt = tvt ?? TvtNetClient.connect;

  final TvtConnector _tvt;

  final DeviceRegistry _registry;
  final ConnectionManager _connections;
  final DeviceHttpClient _http;
  final EventStore _events;
  final Map<String, DateTime> _lastTrigger = {};

  /// Debounce so a double-tap cannot pulse the relay twice.
  static const cooldown = Duration(seconds: 3);

  Future<UnlockResult> unlock(String deviceId) async {
    final device = _registry.byId(deviceId);
    if (device == null || !device.canUnlock) {
      return const UnlockResult.failure('No unlock endpoint configured for this device');
    }
    final last = _lastTrigger[deviceId];
    if (last != null && DateTime.now().difference(last) < cooldown) {
      return const UnlockResult.failure('Please wait before unlocking again');
    }
    _lastTrigger[deviceId] = DateTime.now();

    try {
      final route = await _connections.require(deviceId);
      // Plain account for the bridge and the TVT protocol (they hash it
      // themselves); Digest form for direct HTTP calls.
      final creds = _registry.credentialsFor(deviceId);
      final hold = Duration(milliseconds: device.unlockHoldMs.clamp(200, 10000));
      if (route.bridge) {
        if (creds == null) throw DeviceHttpException('Not signed in');
        await BridgeClient(
          host: route.host,
          port: route.httpPort,
          credentials: creds,
          http: _http,
        ).pulseAlarmOutput(device.parentId ?? device.id, device.alarmOutput, hold);
      } else if (device.unlockVia == UnlockMethod.tvtAlarmOutput) {
        if (creds == null) throw DeviceHttpException('Not signed in');
        await _pulseTvt(route.host, device, creds.username, creds.password, hold);
      } else {
        await _http.send(
          device.unlockMethod,
          route.httpUri(device.unlockPath),
          credentials: _registry.mediaCredentialsFor(deviceId),
          body: device.unlockBody,
          headers: device.unlockBody.trimLeft().startsWith('{')
              ? const {'Content-Type': 'application/json'}
              : const {},
        );
      }
      await _events.addRecord(
        type: EventType.doorUnlocked,
        deviceId: deviceId,
        note: 'Unlocked from app via ${route.kind.name.toUpperCase()}',
      );
      return UnlockResult.success('${device.name} unlocked');
    } on DeviceUnreachableException catch (e) {
      await _audit(deviceId, e.toString());
      return UnlockResult.failure(e.toString());
    } on DeviceHttpException catch (e) {
      await _audit(deviceId, e.message);
      return UnlockResult.failure(e.message);
    } on TvtNetException catch (e) {
      await _audit(deviceId, e.message);
      return UnlockResult.failure(e.message);
    }
  }

  Future<void> _pulseTvt(String host, DeviceConfig d, String user, String pass, Duration hold) async {
    final client = await _tvt(host, d.netPort);
    try {
      await client.login(user, pass);
      await client.pulseAlarmOut(d.alarmOutput, hold);
      // Let the "off" command reach the device before logging out.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } finally {
      await client.close();
    }
  }

  Future<void> _audit(String deviceId, String reason) =>
      _events.addRecord(type: EventType.other, deviceId: deviceId, note: 'Unlock FAILED: $reason');
}
