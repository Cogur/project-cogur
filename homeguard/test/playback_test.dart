import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/models/device.dart';
import 'package:homeguard/core/models/security_event.dart';
import 'package:homeguard/core/network/connection_manager.dart';
import 'package:homeguard/core/network/device_http_client.dart';
import 'package:homeguard/core/security/secure_store.dart';
import 'package:homeguard/core/services/device_registry.dart';
import 'package:homeguard/core/services/door_relay_service.dart';
import 'package:homeguard/core/services/event_store.dart';
import 'package:homeguard/core/services/recording_service.dart';
import 'package:homeguard/core/tvt/tvt_lapi_client.dart';
import 'package:homeguard/core/tvt/tvt_net_client.dart';
import 'package:homeguard/core/tvt/tvt_net_protocol.dart';
import 'package:xml/xml.dart';

import 'support/fake_tvt.dart';

/// HTTP API (LAPI) with Basic auth: recording search only.
class FakeLapi {
  late HttpServer server;
  String? lastBody;
  bool apiServerOff = false;

  /// Firmware that only answers the flat `/SearchByTime/<ch>` form.
  bool flatOnly = false;
  final paths = <String>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      if (req.headers.value('authorization') != 'Basic ${base64.encode(utf8.encode('admin:pw'))}') {
        req.response
          ..statusCode = 401
          ..headers.set('WWW-Authenticate', 'Basic realm="nvr"');
        return req.response.close();
      }
      paths.add(req.uri.path);
      final wanted = flatOnly
          ? RegExp(r'^/SearchByTime/\d+$')
          : RegExp(r'^/LAPI/V1\.0/Playback/SearchByTime$');
      if (apiServerOff || !wanted.hasMatch(req.uri.path)) {
        req.response.statusCode = 404;
        return req.response.close();
      }
      lastBody = body;
      req.response.write(
        '<?xml version="1.0"?><SearchByTimeResponse><ResponseStatus><statusCode>200</statusCode></ResponseStatus>'
        '<RecordSegment><channelID>2</channelID><startTime>2026-10-30 08:00:00</startTime>'
        '<endTime>2026-10-30 08:20:00</endTime><recordType>motion</recordType></RecordSegment>'
        '<RecordSegment><channelID>2</channelID><startTime>2026-10-30T07:00:00</startTime>'
        '<endTime>2026-10-30T07:30:00</endTime><recordType>schedule</recordType></RecordSegment>'
        '<RecordSegment><startTime>broken</startTime><endTime>2026-10-30T07:30:00</endTime></RecordSegment>'
        '</SearchByTimeResponse>',
      );
      await req.response.close();
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These tests talk to real loopback servers; undo the binding's HTTP mock.
  setUp(() => HttpOverrides.global = null);

  late DeviceRegistry registry;
  late ConnectionManager cm;

  Future<void> setUpRegistry({required int httpPort, RemoteMode remote = RemoteMode.disabled}) async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = SecureStore(const FlutterSecureStorage());
    cm = ConnectionManager(
      probe: (h, p, _) async => h == '127.0.0.1' || h == 'bridge.example.com' ? Duration.zero : null,
      lookup: (h) async => [InternetAddress.loopbackIPv4],
      connectivity: const Stream<List<ConnectivityResult>>.empty(),
    );
    registry = DeviceRegistry(store, cm);
    await registry.load();
    final nvr = registry.byId('nvr')!;
    await registry.upsert(
      nvr.copyWith(
        lanHost: remote == RemoteMode.disabled ? '127.0.0.1' : '',
        httpPort: httpPort,
        remoteHost: remote == RemoteMode.disabled ? '' : 'bridge.example.com',
        remoteMode: remote,
        httpsPort: 8443,
        rtspsPort: 8322,
      ),
    );
    await registry.setCredentials('nvr', const Credentials('admin', 'pw'));
  }

  test('TVT playback path carries channel, start and length', () {
    const cam = DeviceConfig(id: 'cam2', name: 'Cam', kind: DeviceKind.camera, parentId: 'nvr', channel: 2);
    final s = RecordSegment(
      channel: 2,
      start: DateTime(2026, 10, 30, 8, 5, 9),
      end: DateTime(2026, 10, 30, 8, 7, 9),
    );
    expect(
      RecordingService.playbackPath(cam, s),
      // Playback chID is 0-based (camera 2 → chID=1), per the HTTP API guide.
      '/chID=1&date=2026-10-30&time=08:05:09&timelen=120&streamType=main&action=playback&linkType=tcp',
    );
  });

  test('segments are found in any envelope (config/item form of the HTTP API guide)', () {
    final doc = XmlDocument.parse(
      '<config version="1.0" xmlns="http://www.ipc.com/ver10" status="success">'
      '<recData type="list" count="2">'
      '<item><startTime type="string">2026-10-31 10:00:00</startTime><endTime type="string">2026-10-31 10:30:00</endTime>'
      '<recType>motion</recType></item>'
      '<item><startTime>2026-10-31 08:00:00</startTime><stopTime>2026-10-31 09:00:00</stopTime></item>'
      '<item><starttime type="string" seconds="15" recType="intel detection"><![CDATA[2026-10-31 11:00:00]]></starttime>'
      '<endtime><![CDATA[2026-10-31 11:00:15]]></endtime></item>'
      '</recData></config>',
    );
    final segs = TvtLapiClient.parseSegments(doc, 4);
    expect(segs.map((s) => s.start.hour), [8, 10, 11]);
    expect(segs[1].type, 'motion');
    expect(segs.last.type, 'intel detection'); // as the real NVR reports it
    expect(segs.first.channel, 4);
  });

  test('LAN search uses the HTTP API and seeking keeps the segment end', () async {
    final lapi = FakeLapi();
    await lapi.start();
    addTearDown(() => lapi.server.close(force: true));
    await setUpRegistry(httpPort: lapi.server.port);
    final recs = await RecordingService(registry, cm).search('cam2', DateTime(2026, 10, 30, 15));
    expect(lapi.lastBody, contains('<recTypes type="list">'));
    expect(lapi.lastBody, contains('<starttime type="string"><![CDATA[2026-10-30 00:00:00]]></starttime>'));
    expect(lapi.lastBody, contains('<endtime type="string"><![CDATA[2026-10-30 23:59:59]]></endtime>'));
    expect(recs.map((r) => r.segment.start.hour), [7, 8]); // sorted, broken one dropped
    expect(recs.last.segment.type, 'motion');
    expect(recs.first.route.kind, RouteKind.lan);

    final sought = RecordingService.seek(recs.first, DateTime(2026, 10, 30, 7, 10));
    expect(sought.segment.end, recs.first.segment.end);
    expect(sought.path, contains('time=07:10:00&timelen=1200'));
  });

  test('firmware with flat HTTP API URLs is found and remembered', () async {
    final lapi = FakeLapi()..flatOnly = true;
    await lapi.start();
    addTearDown(() => lapi.server.close(force: true));
    await setUpRegistry(httpPort: lapi.server.port);
    final client = TvtLapiClient(
      host: '127.0.0.1',
      port: lapi.server.port,
      credentials: const Credentials('admin', 'pw'),
    );
    final day = DateTime(2026, 10, 30);
    expect(await client.searchByTime(3, day, day.add(const Duration(hours: 23))), hasLength(2));
    expect(client.urlStyle, 'flat');
    lapi.paths.clear();
    await client.searchByTime(3, day, day.add(const Duration(hours: 23)));
    expect(lapi.paths.where((p) => p.startsWith('/LAPI')), isEmpty);
    expect(lapi.paths.last, '/SearchByTime/3');
  });

  test('API Server switched off is reported so the app can offer to enable it', () async {
    final lapi = FakeLapi()..apiServerOff = true;
    await lapi.start();
    addTearDown(() => lapi.server.close(force: true));
    await setUpRegistry(httpPort: lapi.server.port);
    await expectLater(
      RecordingService(registry, cm).search('cam1', DateTime(2026, 10, 30)),
      throwsA(isA<RecordingException>().having((e) => e.needsApiServer, 'needsApiServer', isTrue)),
    );
  });

  test('bridge route streams use bridge names and bridge playback paths', () async {
    await setUpRegistry(httpPort: 80, remote: RemoteMode.bridge);
    final route = await cm.resolve('cam3', force: true);
    expect(route.bridge, isTrue);
    expect(route.secure, isTrue);
    expect(route.rtspPort, 8322);
    expect(route.streamPath(registry.byId('cam3')!, StreamQuality.sub), '/nvr_ch3_sub');
    expect(route.rtspUri('/nvr_ch3_sub').toString(), 'rtsps://bridge.example.com:8322/nvr_ch3_sub');

    final r = Recording(
      segment: RecordSegment(channel: 3, start: DateTime(2026, 10, 30, 8), end: DateTime(2026, 10, 30, 9)),
      device: registry.byId('cam3')!,
      path: '/nvr_ch3_pb_20261030080000_20261030090000',
      route: route,
    );
    expect(
      RecordingService.seek(r, DateTime(2026, 10, 30, 8, 30)).path,
      '/nvr_ch3_pb_20261030083000_20261030090000',
    );
  });

  test('door unlock over the TVT protocol logs in and pulses the alarm output', () async {
    final dev = FakeTvtDevice(protocolVer: 11, password: 'pw');
    await dev.start();
    addTearDown(dev.stop);
    await setUpRegistry(httpPort: 80);
    final door = registry.byId('door')!;
    await registry.upsert(
      door.copyWith(
        lanHost: '127.0.0.1',
        unlockVia: UnlockMethod.tvtAlarmOutput,
        alarmOutput: 1,
        unlockHoldMs: 200,
        netPort: dev.server.port,
      ),
    );
    final tmp = await Directory.systemTemp.createTemp('hg-door');
    addTearDown(() => tmp.delete(recursive: true));
    final events = EventStore(root: () async => tmp);
    final relay = DoorRelayService(registry, cm, DeviceHttpClient(), events, tvt: TvtNetClient.connect);
    final res = await relay.unlock('door');
    expect(res.ok, isTrue, reason: res.message);
    final cmds = dev.received.map((p) => p.cmd).toList();
    expect(cmds, containsAllInOrder([TvtCmd.headLogin, TvtCmd.alarmOutStart, TvtCmd.alarmOutStop]));
    final start = dev.received.firstWhere((p) => p.cmd == TvtCmd.alarmOutStart);
    expect(start.data, [1, 0, 0, 0]);
    expect(events.events.first.type, EventType.doorUnlocked);
  });

  test('door unlock with a wrong password fails and is audited', () async {
    final dev = FakeTvtDevice(password: 'other');
    await dev.start();
    addTearDown(dev.stop);
    await setUpRegistry(httpPort: 80);
    await registry.upsert(
      registry
          .byId('door')!
          .copyWith(lanHost: '127.0.0.1', unlockVia: UnlockMethod.tvtAlarmOutput, netPort: dev.server.port),
    );
    final tmp = await Directory.systemTemp.createTemp('hg-door');
    addTearDown(() => tmp.delete(recursive: true));
    final events = EventStore(root: () async => tmp);
    final res = await DoorRelayService(registry, cm, DeviceHttpClient(), events).unlock('door');
    expect(res.ok, isFalse);
    expect(res.message, contains('Invalid'));
    expect(dev.received.where((p) => p.cmd == TvtCmd.alarmOutStart), isEmpty);
    expect(events.events.first.note, contains('FAILED'));
  });
}
