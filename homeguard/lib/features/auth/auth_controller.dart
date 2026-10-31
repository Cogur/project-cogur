import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/models/device.dart';
import '../../core/network/connection_manager.dart';
import '../../core/rtsp/rtsp_client.dart';
import '../../core/security/biometric_service.dart';
import '../../core/security/secure_store.dart';
import '../../core/services/device_registry.dart';
import '../../core/tvt/nvr_setup.dart';
import '../../core/tvt/tvt_web_client.dart';
import '../../core/utils/log.dart';

enum AuthStatus { initializing, signedOut, locked, authenticated }

/// Verifies NVR credentials. Production uses an RTSP DESCRIBE (works on every
/// TVT/Techson recorder, no vendor HTTP API needed); tests inject a fake.
typedef CredentialVerifier = Future<void> Function(Uri rtspUri, Credentials c);

Future<void> rtspCredentialVerifier(Uri uri, Credentials c) async {
  // Plain DESCRIBE only: some recorders reject the ONVIF back-channel
  // "Require" header, which must not be mistaken for a bad login.
  await RtspClient.probe(uri: uri, username: c.username, password: c.password, backchannel: false);
}

class LoginException implements Exception {
  LoginException(this.message, {this.needsRtspConsent = false});
  final String message;

  /// The password is right but the NVR's RTSP service is off. Ask the user,
  /// then call `signIn(..., allowEnableRtsp: true)`.
  final bool needsRtspConsent;
  @override
  String toString() => message;
}

class AuthController extends ChangeNotifier {
  AuthController({
    required SecureStore store,
    required BiometricService biometrics,
    required DeviceRegistry registry,
    required ConnectionManager connections,
    CredentialVerifier verifier = rtspCredentialVerifier,
    NvrSetup? setup,
  }) : _store = store,
       _setup = setup ?? NvrSetup(),
       _bio = biometrics,
       _registry = registry,
       _connections = connections,
       _verify = verifier;

  final SecureStore _store;
  final BiometricService _bio;
  final DeviceRegistry _registry;
  final ConnectionManager _connections;
  final CredentialVerifier _verify;
  final NvrSetup _setup;
  String? _notice;

  AuthStatus _status = AuthStatus.initializing;
  RememberedLogin? _remembered;
  bool _biometricAvailable = false;
  int _failures = 0;
  DateTime? _lockoutUntil;

  AuthStatus get status => _status;

  /// One-off message for the user after sign-in (e.g. "RTSP was enabled").
  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  RememberedLogin? get remembered => _remembered;
  bool get biometricAvailable => _biometricAvailable;
  bool get canUseBiometricUnlock => _biometricAvailable && (_remembered?.biometricEnabled ?? false);

  /// Remaining lockout after repeated failed logins (null when not locked).
  Duration? get lockoutRemaining {
    final until = _lockoutUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  Future<void> init() async {
    _biometricAvailable = await _bio.isAvailable();
    _remembered = await _store.readRemembered();
    await _registry.load();
    if (_remembered == null) {
      // Not remembered: never keep a password across app launches.
      await _registry.setCredentials('nvr', null);
    }
    _status = canUseBiometricUnlock && _registry.credentialsFor('nvr') != null
        ? AuthStatus.locked
        : AuthStatus.signedOut;
    notifyListeners();
  }

  /// Normalizes "rtsp://192.168.1.20:554/" or "nvr.local" to a bare host.
  static String normalizeHost(String input) {
    var h = input.trim();
    h = h.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false), '');
    h = h.split('/').first;
    if (h.contains('@')) h = h.split('@').last;
    // Strip a :port suffix but keep IPv6 literals intact.
    if (h.startsWith('[')) return h.substring(1, h.indexOf(']'));
    if (':'.allMatches(h).length == 1) h = h.split(':').first;
    return h;
  }

  /// Port typed after the host ("192.168.1.10:8554"), if any.
  static int? parsePort(String input) {
    var h = input.trim().replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false), '');
    h = h.split('/').first;
    if (h.contains('@')) h = h.split('@').last;
    final m = RegExp(r'^(?:\[[^\]]+\]|[^:]+):(\d{1,5})$').firstMatch(h);
    final port = int.tryParse(m?.group(1) ?? '');
    return port != null && port > 0 && port <= 65535 ? port : null;
  }

  Future<void> signIn({
    required String host,
    required String username,
    required String password,
    required bool remember,
    required bool enableBiometrics,
    String remoteHost = '',
    RemoteMode remoteMode = RemoteMode.disabled,
    String cameraPathTemplate = '',
    bool allowEnableRtsp = false,
    int? webPort,
  }) async {
    final wait = lockoutRemaining;
    if (wait != null) {
      throw LoginException('Too many attempts. Try again in ${wait.inSeconds + 1}s.');
    }
    final lanHost = normalizeHost(host);
    final remote = normalizeHost(remoteHost);
    if (lanHost.isEmpty && remote.isEmpty) {
      throw LoginException('Enter the NVR local IP address or domain');
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw LoginException('Enter username and password');
    }
    final creds = Credentials(username.trim(), password);

    // Apply topology first so route resolution sees the hosts.
    final nvr = _registry.firstOfKind(DeviceKind.nvr)!;
    await _registry.upsert(
      nvr.copyWith(
        lanHost: lanHost,
        remoteHost: remote,
        remoteMode: remote.isEmpty ? RemoteMode.disabled : remoteMode,
        rtspPort: parsePort(host),
        httpPort: webPort,
        // HomeGuard Bridge defaults (tools/bridge/docker-compose.yml).
        rtspsPort: remoteMode == RemoteMode.bridge && nvr.rtspsPort == 322 ? 8322 : null,
        httpsPort: remoteMode == RemoteMode.bridge && nvr.httpsPort == 443 ? 8443 : null,
      ),
    );
    final template = cameraPathTemplate.trim();
    if (template.isNotEmpty) {
      for (final cam in _registry.devices.where((d) => d.parentId == nvr.id).toList()) {
        if (cam.rtspPathTemplate != template) {
          await _registry.upsert(cam.copyWith(rtspPathTemplate: template));
        }
      }
    }

    // 1. The recorder's own web login: same account as SuperLive Plus and the
    //    NVR web page. Gives a definite yes/no on the password, the camera
    //    list, and lets the app switch RTSP on without any admin menus.
    NvrSetupResult? setup;
    final webPortToUse = webPort ?? nvr.httpPort;
    if (lanHost.isNotEmpty && await _connections.isPortOpen(lanHost, webPortToUse)) {
      try {
        setup = await _setup.run(
          host: lanHost,
          httpPort: webPortToUse,
          credentials: creds,
          allowEnableRtsp: allowEnableRtsp,
        );
      } on NvrSetupException catch (e) {
        if (e.authFailure) {
          _registerFailure();
          throw LoginException(
            'Invalid username or password. Use the same account as in SuperLive Plus or on the NVR web page.',
          );
        }
        if (e.needsRtsp) {
          throw LoginException(
            'Signed in, but the NVR\'s video service (RTSP) is switched off. HomeGuard can switch it on for you '
            '(password protected, no anonymous access).',
            needsRtspConsent: true,
          );
        }
        // No TVT web interface here (other brand, simulator): plain RTSP check.
        Log.w('auth', 'web sign-in skipped: $e');
      }
    }
    if (setup != null) await _applySetup(nvr.id, setup, keepRtspPort: parsePort(host) != null);

    var route = await _connections.resolve(nvr.id, force: true);
    // A freshly enabled RTSP service needs a few seconds to start listening.
    for (var i = 0; !route.reachable && (setup?.rtspWasEnabled ?? false) && i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      route = await _connections.resolve(nvr.id, force: true);
    }
    if (!route.reachable) {
      final configured = _registry.firstOfKind(DeviceKind.nvr)!;
      // Distinguish "wrong address / not on Wi-Fi" from "NVR found, but its
      // RTSP video port is closed or different" — the common case on TVT
      // recorders where RTSP is disabled or moved in the port settings.
      if (lanHost.isNotEmpty && await _connections.isPortOpen(lanHost, configured.httpPort)) {
        throw LoginException(
          'Found the NVR at $lanHost, but its video (RTSP) port ${configured.rtspPort} does not answer. '
          'On the NVR open Function Panel → Network → Port: enable RTSP and check the RTSP port. '
          'If it is not ${configured.rtspPort}, enter it after the IP, e.g. $lanHost:8554.',
        );
      }
      throw LoginException(
        lanHost.isNotEmpty && remote.isEmpty
            ? 'NVR not found at $lanHost. Check the IP and that the phone is on the same Wi-Fi.'
            : 'NVR is unreachable on both local and remote addresses.',
      );
    }
    final firstCamera = _registry.devices.firstWhere(
      (d) => d.parentId == nvr.id && d.enabled,
      orElse: () => nvr,
    );
    final storedForm = _registry.byId(nvr.id)!.digestPassword;
    try {
      await _verify(
        route.rtspUri(route.streamPath(firstCamera, StreamQuality.sub)),
        Credentials(creds.username, storedForm.apply(creds.password)),
      );
      if (setup?.rtspWasEnabled ?? false) _notice = 'The NVR\'s video service was switched on.';
    } on RtspException catch (e) {
      final detail = e.detail == null ? '' : '\n\nNVR replied: ${e.detail}';
      if (setup != null && e.isAuthFailure) {
        // The web login already proved the password. Some TVT firmware wants
        // the MD5 form in Digest; try those once each (every refusal counts
        // as an illegal login on the recorder), else let the user in anyway.
        final variant = await _detectDigestVariant(route, firstCamera, creds, tried: storedForm);
        if (variant != null) {
          await _registry.upsert(_registry.byId(nvr.id)!.copyWith(digestPassword: variant));
          Log.w('auth', 'RTSP accepts the ${variant.name} password form');
        } else {
          Log.w('auth', 'web login ok but RTSP refused: ${e.detail ?? e.message}');
          _notice =
              'Signed in. The NVR accepted the password but its video service refused it, so live view may '
              'not start. Check the user\'s "Remote preview" permission on the NVR.$detail';
        }
      } else if (e.statusCode == 401) {
        _registerFailure();
        throw LoginException(
          'Invalid username or password. Check upper/lower case — the video service is case-sensitive.$detail',
        );
      } else if (e.statusCode == 403) {
        throw LoginException(
          'The NVR accepted the connection but refused this user. On the NVR, check that the user has '
          'live-view / remote preview permission (Account and Authority → Edit User).$detail',
        );
      } else {
        throw LoginException('NVR did not respond correctly: ${e.message}$detail');
      }
    }

    _failures = 0;
    _lockoutUntil = null;
    await _registry.setCredentials(nvr.id, creds);
    final bio = enableBiometrics && _biometricAvailable;
    if (bio && !await _bio.authenticate('Confirm to enable biometric sign-in')) {
      throw LoginException('Biometric confirmation was cancelled');
    }
    _remembered = remember || bio
        ? RememberedLogin(username: creds.username, host: lanHost, biometricEnabled: bio)
        : null;
    await _store.writeRemembered(_remembered);
    Log.w('auth', 'signed in via ${route.kind.name}');
    _status = AuthStatus.authenticated;
    notifyListeners();
  }

  Future<DigestPassword?> _detectDigestVariant(
    ResolvedRoute route,
    DeviceConfig cam,
    Credentials c, {
    required DigestPassword tried,
  }) async {
    for (final v in DigestPassword.values.where((v) => v != tried)) {
      try {
        await _verify(
          route.rtspUri(route.streamPath(cam, StreamQuality.sub)),
          Credentials(c.username, v.apply(c.password)),
        );
        return v;
      } on RtspException catch (e) {
        if (!e.isAuthFailure) return null;
      }
    }
    return null;
  }

  /// Mirrors the NVR's channel list (names, count) into the topology, the way
  /// SuperLive shows cameras without manual setup.
  Future<void> _applySetup(String nvrId, NvrSetupResult setup, {required bool keepRtspPort}) async {
    final nvr = _registry.byId(nvrId)!;
    if (!keepRtspPort && setup.rtspPort != nvr.rtspPort) {
      await _registry.upsert(nvr.copyWith(rtspPort: setup.rtspPort));
    }
    if (setup.channels.isEmpty) return;
    final cams = _registry.devices.where((d) => d.parentId == nvrId).toList();
    final template = cams.firstOrNull?.rtspPathTemplate ?? DeviceConfig.tvtRtspTemplate;
    final wanted = {for (final c in setup.channels) c.number: c};
    for (final cam in cams) {
      final ch = wanted.remove(cam.channel);
      final updated = ch == null
          ? cam.copyWith(enabled: false)
          : cam.copyWith(name: _name(ch), enabled: true);
      if (updated.name != cam.name || updated.enabled != cam.enabled) await _registry.upsert(updated);
    }
    for (final ch in wanted.values) {
      var id = 'cam${ch.number}';
      while (_registry.byId(id) != null) {
        id = '${id}x';
      }
      await _registry.upsert(
        DeviceConfig(
          id: id,
          name: _name(ch),
          kind: DeviceKind.camera,
          parentId: nvrId,
          channel: ch.number,
          rtspPathTemplate: template,
        ),
      );
    }
  }

  static String _name(TvtChannel c) => c.name.trim().isEmpty ? 'Camera ${c.number}' : c.name.trim();

  void _registerFailure() {
    _failures++;
    if (_failures >= 5) {
      // 30s, 60s, 120s ... capped at 15 minutes.
      final seconds = min(900, 30 * pow(2, _failures - 5).toInt());
      _lockoutUntil = DateTime.now().add(Duration(seconds: seconds));
    }
    notifyListeners();
  }

  Future<bool> unlockWithBiometrics() async {
    if (!canUseBiometricUnlock) return false;
    final ok = await _bio.authenticate('Unlock HomeGuard');
    if (!ok) return false;
    await _registry.load();
    if (_registry.credentialsFor('nvr') == null) {
      _status = AuthStatus.signedOut;
      notifyListeners();
      return false;
    }
    _status = AuthStatus.authenticated;
    notifyListeners();
    return true;
  }

  /// Re-locks after inactivity. With biometrics the session can be resumed;
  /// without, the password must be entered again.
  Future<void> lock() async {
    if (_status != AuthStatus.authenticated) return;
    _registry.clearMemory();
    if (canUseBiometricUnlock) {
      _status = AuthStatus.locked;
    } else {
      await _registry.setCredentials('nvr', null);
      _status = AuthStatus.signedOut;
    }
    notifyListeners();
  }

  Future<void> signOut({bool forget = false}) async {
    await _registry.setCredentials('nvr', null);
    _registry.clearMemory();
    if (forget) {
      _remembered = null;
      await _store.writeRemembered(null);
    } else if (_remembered != null) {
      // Password is gone, so biometric unlock can no longer restore a session.
      _remembered = RememberedLogin(
        username: _remembered!.username,
        host: _remembered!.host,
        biometricEnabled: false,
      );
      await _store.writeRemembered(_remembered);
    }
    _status = AuthStatus.signedOut;
    notifyListeners();
  }
}
