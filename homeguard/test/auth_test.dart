import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/models/device.dart';
import 'package:homeguard/core/network/connection_manager.dart';
import 'package:homeguard/core/rtsp/rtsp_client.dart';
import 'package:homeguard/core/security/biometric_service.dart';
import 'package:homeguard/core/security/secure_store.dart';
import 'package:homeguard/core/services/device_registry.dart';
import 'package:homeguard/core/tvt/nvr_setup.dart';
import 'package:homeguard/core/tvt/tvt_web_client.dart';
import 'package:homeguard/features/auth/auth_controller.dart';
import 'package:homeguard/features/auth/login_page.dart';
import 'package:provider/provider.dart';

class FakeBiometrics extends BiometricService {
  FakeBiometrics({this.available = true, this.succeed = true});
  bool available;
  bool succeed;
  int prompts = 0;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> authenticate(String reason, {bool biometricOnly = false}) async {
    prompts++;
    return succeed;
  }
}

/// Stands in for the NVR web interface.
class FakeSetup extends NvrSetup {
  bool web = false; // false: no TVT web interface answers
  String password = 'pw';
  bool rtspOn = true;
  List<TvtChannel> channels = const [];
  int calls = 0;

  @override
  Future<NvrSetupResult> run({
    required String host,
    required int httpPort,
    required Credentials credentials,
    required bool allowEnableRtsp,
  }) async {
    calls++;
    if (!web) throw NvrSetupException('no web', unreachable: true);
    if (credentials.password != password) throw NvrSetupException('bad', authFailure: true);
    var enabled = false;
    if (!rtspOn) {
      if (!allowEnableRtsp) throw NvrSetupException('off', needsRtsp: true);
      rtspOn = enabled = true;
    }
    return NvrSetupResult(channels: channels, rtspPort: 554, rtspWasEnabled: enabled);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SecureStore store;
  late FakeBiometrics bio;
  late ConnectionManager cm;
  late DeviceRegistry registry;
  late List<Uri> verified;
  String goodPassword = 'pw';
  Set<String> up = {};
  late FakeSetup setup;

  AuthController build() => AuthController(
    store: store,
    biometrics: bio,
    registry: registry,
    connections: cm,
    setup: setup,
    verifier: (uri, c) async {
      verified.add(uri);
      if (c.password != goodPassword) throw RtspException('bad', statusCode: 401);
    },
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store = SecureStore(const FlutterSecureStorage());
    bio = FakeBiometrics();
    up = {'192.168.1.10:554'};
    verified = [];
    setup = FakeSetup();
    goodPassword = 'pw';
    cm = ConnectionManager(
      probe: (h, p, _) async => up.contains('$h:$p') ? Duration.zero : null,
      lookup: (h) async => [InternetAddress(h)],
      connectivity: const Stream<List<ConnectivityResult>>.empty(),
    );
    registry = DeviceRegistry(store, cm);
  });

  test('host normalisation', () {
    expect(AuthController.normalizeHost(' rtsp://admin:x@192.168.1.10:554/ch1 '), '192.168.1.10');
    expect(AuthController.normalizeHost('nvr.local'), 'nvr.local');
    expect(AuthController.normalizeHost('[fd00::1]:554'), 'fd00::1');
    expect(AuthController.normalizeHost('fd00::1'), 'fd00::1');
  });

  test('port parsing', () {
    expect(AuthController.parsePort('192.168.1.10:8554'), 8554);
    expect(AuthController.parsePort('rtsp://u:p@nvr.local:554/x'), 554);
    expect(AuthController.parsePort('[fd00::1]:8554'), 8554);
    expect(AuthController.parsePort('192.168.1.10'), isNull);
    expect(AuthController.parsePort('fd00::1'), isNull);
    expect(AuthController.parsePort('host:99999'), isNull);
  });

  test('custom port and camera path from the login screen are applied before verifying', () async {
    up = {'192.168.1.10:8554'};
    final auth = build();
    await auth.init();
    await auth.signIn(
      host: '192.168.1.10:8554',
      username: 'admin',
      password: 'pw',
      remember: false,
      enableBiometrics: false,
      cameraPathTemplate: '/cam{channel}_{stream}',
    );
    expect(verified.single.toString(), 'rtsp://192.168.1.10:8554/cam1_sub');
    expect(registry.byId('cam2')!.rtspPath(StreamQuality.main), '/cam2_main');
  });

  test('successful sign-in verifies against camera 1 sub-stream and stores credentials', () async {
    final auth = build();
    await auth.init();
    expect(auth.status, AuthStatus.signedOut);
    await auth.signIn(
      host: '192.168.1.10',
      username: 'admin',
      password: 'pw',
      remember: true,
      enableBiometrics: true,
    );
    expect(auth.status, AuthStatus.authenticated);
    expect(verified.single.toString(), 'rtsp://192.168.1.10:554/chID=1&streamType=sub&linkType=tcp');
    expect((await store.readCredentials('nvr'))!.password, 'pw');
    expect((await store.readRemembered())!.biometricEnabled, isTrue);
  });

  test('remembered + biometric launch starts locked and unlocks with biometrics', () async {
    final first = build();
    await first.init();
    await first.signIn(
      host: '192.168.1.10',
      username: 'admin',
      password: 'pw',
      remember: true,
      enableBiometrics: true,
    );

    registry = DeviceRegistry(store, cm);
    final second = build();
    await second.init();
    expect(second.status, AuthStatus.locked);
    bio.succeed = false;
    expect(await second.unlockWithBiometrics(), isFalse);
    expect(second.status, AuthStatus.locked);
    bio.succeed = true;
    expect(await second.unlockWithBiometrics(), isTrue);
    expect(second.status, AuthStatus.authenticated);
  });

  test('without remember-me the password does not survive a relaunch', () async {
    final first = build();
    await first.init();
    await first.signIn(
      host: '192.168.1.10',
      username: 'admin',
      password: 'pw',
      remember: false,
      enableBiometrics: false,
    );
    registry = DeviceRegistry(store, cm);
    final second = build();
    await second.init();
    expect(second.status, AuthStatus.signedOut);
    expect(await store.readCredentials('nvr'), isNull);
  });

  test('wrong password is rejected and repeated failures trigger a lockout', () async {
    final auth = build();
    await auth.init();
    for (var i = 0; i < 5; i++) {
      await expectLater(
        auth.signIn(
          host: '192.168.1.10',
          username: 'admin',
          password: 'x',
          remember: false,
          enableBiometrics: false,
        ),
        throwsA(
          isA<LoginException>().having(
            (e) => e.message,
            'message',
            startsWith('Invalid username or password'),
          ),
        ),
      );
    }
    expect(auth.lockoutRemaining, isNotNull);
    await expectLater(
      auth.signIn(
        host: '192.168.1.10',
        username: 'admin',
        password: 'pw',
        remember: false,
        enableBiometrics: false,
      ),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', startsWith('Too many attempts'))),
    );
    expect(await store.readCredentials('nvr'), isNull);
  });

  test('403 is reported as a permission problem and does not count toward lockout', () async {
    final auth = AuthController(
      store: store,
      biometrics: bio,
      registry: registry,
      connections: cm,
      verifier: (uri, c) async =>
          throw RtspException('forbidden', statusCode: 403, detail: 'RTSP 403 Forbidden'),
    );
    await auth.init();
    for (var i = 0; i < 6; i++) {
      await expectLater(
        auth.signIn(
          host: '192.168.1.10',
          username: 'a',
          password: 'pw',
          remember: false,
          enableBiometrics: false,
        ),
        throwsA(isA<LoginException>().having((e) => e.message, 'message', contains('live-view'))),
      );
    }
    expect(auth.lockoutRemaining, isNull);
  });

  test('unreachable NVR gives an actionable error', () async {
    up = {};
    final auth = build();
    await auth.init();
    await expectLater(
      auth.signIn(
        host: '192.168.1.99',
        username: 'a',
        password: 'pw',
        remember: false,
        enableBiometrics: false,
      ),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', contains('same Wi-Fi'))),
    );
  });

  test('web page reachable but RTSP closed explains the port setting', () async {
    up = {'192.168.1.200:80'};
    final auth = build();
    await auth.init();
    await expectLater(
      auth.signIn(
        host: '192.168.1.200',
        username: 'a',
        password: 'pw',
        remember: false,
        enableBiometrics: false,
      ),
      throwsA(isA<LoginException>().having((e) => e.message, 'message', contains('video (RTSP) port 554'))),
    );
  });

  group('NVR web sign-in (SuperLive account)', () {
    setUp(() => up.add('192.168.1.10:80')); // the web page answers
    Future<void> signIn(AuthController auth, {String password = 'pw', bool allowEnableRtsp = false}) =>
        auth.signIn(
          host: '192.168.1.10',
          username: 'admin',
          password: password,
          remember: false,
          enableBiometrics: false,
          allowEnableRtsp: allowEnableRtsp,
        );

    test('web sign-in is skipped when the web page does not answer', () async {
      setup.web = true;
      up.remove('192.168.1.10:80');
      final auth = build();
      await auth.init();
      await signIn(auth);
      expect(setup.calls, 0);
      expect(auth.status, AuthStatus.authenticated);
    });

    test('wrong web password is rejected before any RTSP attempt', () async {
      setup.web = true;
      final auth = build();
      await auth.init();
      await expectLater(
        signIn(auth, password: 'nope'),
        throwsA(isA<LoginException>().having((e) => e.message, 'msg', contains('SuperLive'))),
      );
      expect(verified, isEmpty);
    });

    test('RTSP off asks for consent, then is switched on and noticed', () async {
      setup
        ..web = true
        ..rtspOn = false;
      final auth = build();
      await auth.init();
      await expectLater(
        signIn(auth),
        throwsA(isA<LoginException>().having((e) => e.needsRtspConsent, 'consent', isTrue)),
      );
      expect(auth.status, AuthStatus.signedOut);
      await signIn(auth, allowEnableRtsp: true);
      expect(auth.status, AuthStatus.authenticated);
      expect(auth.takeNotice(), contains('switched on'));
      expect(auth.takeNotice(), isNull);
    });

    test('camera list follows the NVR: names, extra channels, missing ones disabled', () async {
      setup
        ..web = true
        ..channels = const [
          TvtChannel(number: 1, name: 'Gate', id: '{1}'),
          TvtChannel(number: 3, name: ' ', id: '{3}'),
          TvtChannel(number: 4, name: 'Garden', id: '{4}'),
        ];
      final auth = build();
      await auth.init();
      await signIn(auth);
      expect(registry.byId('cam1')!.name, 'Gate');
      expect(registry.byId('cam2')!.enabled, isFalse);
      expect(registry.byId('cam3')!.name, 'Camera 3');
      expect(registry.byId('cam4')!.name, 'Garden');
      expect(registry.byId('cam4')!.parentId, 'nvr');
      expect(registry.videoDevices.map((d) => d.id), containsAll(['cam1', 'cam3', 'cam4']));
      expect(registry.videoDevices.map((d) => d.id), isNot(contains('cam2')));
    });

    test('firmware wanting the MD5 password form in Digest is detected and remembered', () async {
      setup.web = true;
      goodPassword = DigestPassword.md5Upper.apply('pw');
      final auth = build();
      await auth.init();
      await signIn(auth);
      expect(auth.takeNotice(), isNull);
      expect(registry.byId('nvr')!.digestPassword, DigestPassword.md5Upper);
      expect(registry.mediaCredentialsFor('cam2')!.password, goodPassword);
      expect(registry.credentialsFor('cam2')!.password, 'pw'); // web/TVT logins keep the plain one
      expect(registry.streamCredentialsFor('cam2', viaBridge: true)!.password, 'pw');
      // Next sign-in starts with the remembered form: one RTSP attempt, no refusal.
      verified.clear();
      await signIn(auth);
      expect(verified, hasLength(1));
    });

    test('RTSP refusing a password the web login accepted still signs in, with a notice', () async {
      setup.web = true;
      goodPassword = 'something-else'; // RTSP relay rejects the account
      final auth = build();
      await auth.init();
      await signIn(auth);
      expect(auth.status, AuthStatus.authenticated);
      expect(auth.takeNotice(), contains('refused'));
    });
  });

  test('remote VPN route is used when LAN is down', () async {
    up = {'10.8.0.2:554'};
    final auth = build();
    await auth.init();
    await auth.signIn(
      host: '192.168.1.10',
      username: 'a',
      password: 'pw',
      remember: false,
      enableBiometrics: false,
      remoteHost: '10.8.0.2',
      remoteMode: RemoteMode.vpn,
    );
    expect(verified.single.host, '10.8.0.2');
    expect(cm.cached('nvr')!.kind, RouteKind.remote);
  });

  test('lock without biometrics drops the stored password', () async {
    bio.available = false;
    final auth = build();
    await auth.init();
    await auth.signIn(
      host: '192.168.1.10',
      username: 'a',
      password: 'pw',
      remember: true,
      enableBiometrics: false,
    );
    await auth.lock();
    expect(auth.status, AuthStatus.signedOut);
    expect(await store.readCredentials('nvr'), isNull);
    expect((await store.readRemembered())!.username, 'a');
  });

  testWidgets('login form validates required fields', (tester) async {
    final auth = build();
    await auth.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: auth,
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    await tester.ensureVisible(find.text('Connect securely'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect securely'));
    await tester.pump();
    expect(find.text('Required'), findsNWidgets(3));
    expect(find.text('Face ID / fingerprint sign-in'), findsOneWidget);
  });
}
