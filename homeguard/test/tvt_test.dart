import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/tvt/tvt_net_client.dart';
import 'package:homeguard/core/security/secure_store.dart';
import 'package:homeguard/core/tvt/tvt_net_protocol.dart';
import 'package:homeguard/core/tvt/tvt_probe.dart';
import 'package:homeguard/core/tvt/tvt_web_client.dart';

import 'support/fake_tvt.dart';

void main() {
  group('web interface (NVMS-9000)', () {
    test('password hash is SHA512(upper(MD5)#nonce)', () {
      final md5Hex = md5.convert(utf8.encode('Secret1')).toString().toUpperCase();
      expect(
        TvtWebClient.hashPassword('Secret1', 'n1'),
        sha512.convert(utf8.encode('$md5Hex#n1')).toString(),
      );
    });

    test('logs in, lists channels in order, enables RTSP without anonymous access', () async {
      final fake = FakeTvtWeb();
      await fake.start();
      addTearDown(fake.stop);
      final c = TvtWebClient(host: '127.0.0.1', port: fake.port, username: 'admin', password: 'Secret1');
      await c.login();
      final ch = await c.channels();
      expect(ch.map((c) => c.number), [1, 2]);
      expect(ch.first.name, 'Gate & Drive');
      expect(ch.first.online, isTrue);
      expect(ch.last.online, isFalse);
      expect(ch.first.ip, '10.0.0.11');
      expect((await c.rtspServer()).enabled, isFalse);
      await c.enableRtsp();
      expect(fake.lastRtspEdit, contains('<anonymousAccess>false</anonymousAccess>'));
      expect((await c.rtspServer()).enabled, isTrue);
    });

    test('wrong password is reported as an auth failure', () async {
      final fake = FakeTvtWeb();
      await fake.start();
      addTearDown(fake.stop);
      final c = TvtWebClient(host: '127.0.0.1', port: fake.port, username: 'admin', password: 'nope');
      await expectLater(
        c.login(),
        throwsA(isA<TvtWebException>().having((e) => e.authFailure, 'auth', true)),
      );
    });

    test('legacy firmware falls back to base64 + Basic auth', () async {
      final fake = FakeTvtWeb(legacy: true);
      await fake.start();
      addTearDown(fake.stop);
      final c = TvtWebClient(host: '127.0.0.1', port: fake.port, username: 'admin', password: 'Secret1');
      await c.login();
      expect((await c.channels()).length, 2);
    });

    test('unreachable host is not an auth failure', () async {
      final c = TvtWebClient(host: '127.0.0.1', port: 1, username: 'a', password: 'b');
      await expectLater(
        c.login(),
        throwsA(isA<TvtWebException>().having((e) => e.unreachable, 'unreachable', true)),
      );
    });

    test('CDATA escapes the terminator', () {
      expect(TvtWebClient.cdata('a]]>b'), '<![CDATA[a]]]]><![CDATA[>b]]>');
    });
  });

  group('binary protocol', () {
    test('codec frames and parses packets split across chunks', () {
      final bytes = [
        ...TvtCodec.encode(0x1234, [9, 8, 7], 5, 6),
        ...TvtCodec.heartbeat(),
      ];
      final p = TvtStreamParser()..add(TvtCodec.heartbeat());
      p.packets.clear();
      for (final b in bytes) {
        p.add([b]);
      }
      expect(p.packets.length, 2);
      expect(p.packets.first.cmd, 0x1234);
      expect(p.packets.first.cmdId, 5);
      expect(p.packets.first.data, [9, 8, 7]);
      expect(p.packets.last.isHeartbeat, isTrue);
    });

    test('rejects a non-TVT stream', () {
      expect(() => TvtStreamParser().add(ascii.encode('HTTP/1.1 400 Bad')), throwsFormatException);
    });

    test('head-variant username XOR keeps zero padding', () {
      final u = TvtCodec.headUsername('admin', 1234);
      expect(u.length, 64);
      expect(u.sublist(5).every((b) => b == 0), isTrue);
      expect(u[0], 'a'.codeUnitAt(0) ^ '1'.codeUnitAt(0));
    });

    for (final variant in [(3, 'classic'), (11, 'head')]) {
      test('${variant.$2} login, HTTP tunnel and alarm output', () async {
        final dev = FakeTvtDevice(protocolVer: variant.$1);
        await dev.start();
        addTearDown(dev.stop);
        final c = await TvtNetClient.connect('127.0.0.1', dev.server.port);
        addTearDown(c.close);
        final info = await c.login('admin', 'pw');
        if (variant.$1 >= 11) {
          expect(info.deviceName, 'NVR-SN');
          expect(info.channels, [1, 2]);
        } else {
          expect(info.deviceName, 'MyNVR');
          expect(info.mac, 'AA:BB:CC:DD:EE:FF');
        }
        expect(utf8.decode(await c.http('/queryIPCInfo')), '{"ok":true}');
        await c.pulseAlarmOut(0, const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          dev.received.map((p) => p.cmd),
          containsAllInOrder([TvtCmd.alarmOutStart, TvtCmd.alarmOutStop]),
        );
      });

      test('${variant.$2} wrong password fails as auth error', () async {
        final dev = FakeTvtDevice(protocolVer: variant.$1);
        await dev.start();
        addTearDown(dev.stop);
        final c = await TvtNetClient.connect('127.0.0.1', dev.server.port);
        addTearDown(c.close);
        await expectLater(
          c.login('admin', 'bad'),
          throwsA(isA<TvtNetException>().having((e) => e.authFailure, 'auth', true)),
        );
      });
    }

    test('times out on a port that is not a TVT device', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((_) {});
      final c = TvtNetClient(
        await TcpTvtTransport.connect('127.0.0.1', server.port),
        timeout: const Duration(milliseconds: 300),
      );
      addTearDown(c.close);
      await expectLater(c.login('a', 'b'), throwsA(isA<TvtNetException>()));
    });
  });

  test('stream parser rejects oversized packet lengths', () {
    final b = Uint8List(8)..setRange(0, 4, ascii.encode('1111'));
    ByteData.sublistView(b).setUint32(4, 0x7fffffff, Endian.little);
    expect(() => (TvtStreamParser()..add(TvtCodec.heartbeat())).add(b), throwsFormatException);
  });

  test('diagnostics find the web UI live-view WebSocket and commands', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final files = {
        '/': '<html><script>location.href="./page/index.html"</script></html>',
        '/page/index.html': '<script data-main="../js/main" src="../js/require.js"></script>',
        '/js/require.js': '/* loader */',
        '/js/main.js': 'define(["app/live/preview.js"],function(){})',
        '/js/app/live/preview.js.unused': '',
        '/js/app/live/preview.js': 'var s=new WebSocket("ws://"+location.host+"/requestWebsocketConnection");Communication.Request({url:"queryLiveStream",data:x})',
      };
      final body = files[req.uri.path];
      req.response.statusCode = body == null ? 404 : 200;
      if (body != null) req.response.write(body);
      await req.response.close();
    });
    final out = await TvtProbe(timeout: const Duration(milliseconds: 300))
        .run('127.0.0.1', const Credentials('admin', 'x'), httpPort: server.port, rtspPort: 1);
    final report = out.join('\n');
    expect(report, contains('Web UI scan: 5 files'));
    expect(report, contains('/js/app/live/preview.js'));
    expect(report, contains('queryLiveStream'));
    expect(report, contains('requestWebsocketConnection'));
  });
}
