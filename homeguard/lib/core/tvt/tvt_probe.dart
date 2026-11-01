import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/device.dart';
import '../rtsp/rtsp_client.dart';
import '../security/secure_store.dart';
import 'tvt_lapi_client.dart';
import 'tvt_net_client.dart';
import 'tvt_web_client.dart';

/// Read-only fact finding on one device, for the diagnostics screen. It never
/// changes settings. The report is what is needed to add support for a model
/// whose API is not documented (e.g. the door station's unlock command).
class TvtProbe {
  TvtProbe({this.timeout = const Duration(seconds: 2)});
  final Duration timeout;

  static const ports = {
    80: 'HTTP',
    443: 'HTTPS',
    554: 'RTSP',
    6036: 'TVT (recorder)',
    9008: 'TVT (camera/intercom)',
    8000: 'alt. HTTP/SDK',
    5060: 'SIP',
  };

  Future<bool> _open(String host, int port) async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Masks the middle of a cloud serial so a report can be shared.
  static String mask(String s) =>
      s.length <= 6 ? '***' : '${s.substring(0, 3)}***${s.substring(s.length - 3)}';

  /// Stream paths tried in order. Stops at the first auth failure so a
  /// wrong password cannot run into the recorder's login lockout.
  static const rtspPaths = [
    '/chID=1&streamType=sub&linkType=tcp',
    '/chID=1&streamType=main&linkType=tcp',
    '/chID=1&streamType=main',
    '/chID=01&streamType=main',
    '/profile1',
  ];

  /// Returns the password form RTSP accepted, or null. On a refusal it tries
  /// the MD5 forms once each and then stops: every refused attempt is an
  /// "illegal login" on the recorder (it may beep or lock the account).
  Future<DigestPassword?> _probeRtsp(String host, int port, Credentials creds, List<String> out) async {
    var form = DigestPassword.plain;
    Future<RtspProbeResult> probe(String path, DigestPassword f) => RtspClient.probe(
      uri: Uri.parse('rtsp://$host:$port$path'),
      username: creds.username,
      password: f.apply(creds.password),
      timeout: const Duration(seconds: 4),
      backchannel: false,
    );
    for (final path in rtspPaths) {
      try {
        RtspProbeResult r;
        try {
          r = await probe(path, form);
        } on RtspException catch (e) {
          if (!e.isAuthFailure || path != rtspPaths.first) rethrow;
          out.add('RTSP $path: ${e.message}${e.detail == null ? '' : ' (${e.detail})'}');
          RtspProbeResult? found;
          for (final f in [DigestPassword.md5Upper, DigestPassword.md5Lower]) {
            try {
              found = await probe(path, f);
              form = f;
              break;
            } on RtspException catch (e2) {
              out.add('  with ${f.name} password form: ${e2.message}');
              if (!e2.isAuthFailure) break;
            }
          }
          if (found == null) {
            out.add('  stopped probing to avoid locking the account');
            return null;
          }
          r = found;
        }
        out.add(
          'RTSP $path${form == DigestPassword.plain ? '' : ' (${form.name} password form)'}: OK, '
          'video ${r.videoCodec}, audio ${r.audioCodec}${r.server == null ? '' : ', server ${r.server}'}',
        );
        if (path.contains('streamType=main') || path == rtspPaths[1]) return form;
      } on RtspException catch (e) {
        out.add('RTSP $path: ${e.message}${e.detail == null ? '' : ' (${e.detail})'}');
        if (e.isAuthFailure) return null;
      }
    }
    return form;
  }

  /// Reads the recorder's own web UI scripts (public static files) and lists
  /// how its browser live view talks to the device: WebSocket addresses and
  /// live/stream/preview commands. Read-only.
  Future<void> _scanWebUi(String host, int port, List<String> out) async {
    final client = http.Client();
    final root = Uri(scheme: 'http', host: host, port: port, path: '/');
    try {
      Future<String?> get(Uri uri) async {
        try {
          final res = await client.get(uri).timeout(timeout * 3);
          if (res.statusCode != 200 || res.bodyBytes.length > 6 * 1024 * 1024) return null;
          return utf8.decode(res.bodyBytes, allowMalformed: true);
        } catch (_) {
          return null;
        }
      }

      // Pages and scripts referenced from the start page, resolved like a
      // browser would (relative paths, redirects via meta/JS location).
      final refPattern = RegExp(r"""["'(]([A-Za-z0-9_./~-]+\.(?:js|html?)(?:\?[^"')\s]*)?)["')]""");
      final seen = <String>{};
      final queue = <Uri>[root];
      final files = <String>[];
      final snippets = <String>{};
      final commands = <String>{};
      while (queue.isNotEmpty && files.length < 60) {
        final uri = queue.removeAt(0);
        final key = uri.path;
        if (!seen.add(key)) continue;
        final text = await get(uri);
        if (text == null) continue;
        files.add('$key (${(text.length / 1024).toStringAsFixed(0)} kB)');
        for (final m in RegExp(
          r'(?:new WebSocket|wss?://|websocket)',
          caseSensitive: false,
        ).allMatches(text)) {
          if (snippets.length >= 15) break;
          final a = (m.start - 60).clamp(0, text.length);
          final b = (m.end + 90).clamp(0, text.length);
          snippets.add('$key: ${text.substring(a, b).replaceAll(RegExp(r'\s+'), ' ')}');
        }
        for (final m in RegExp(r"""url\s*:\s*["']([A-Za-z0-9_/.]+)["']""").allMatches(text)) {
          final c = m[1]!;
          if (RegExp('live|stream|preview|play|socket|snap|jpeg|pic', caseSensitive: false).hasMatch(c)) {
            commands.add(c);
          }
        }
        for (final m in refPattern.allMatches(text)) {
          final ref = m[1]!;
          if (ref.startsWith('//')) continue;
          final next = uri.resolve(ref);
          if (next.host == host && next.port == port && !seen.contains(next.path) && queue.length < 120) {
            queue.add(next.replace(query: ''));
          }
        }
        // require.js data-main without extension
        for (final m in RegExp(r"""data-main\s*=\s*["']([^"']+)["']""").allMatches(text)) {
          final ref = m[1]!;
          queue.add(uri.resolve(ref.endsWith('.js') ? ref : '$ref.js'));
        }
      }
      out.add('Web UI scan: ${files.length} files');
      out.add('  files: ${files.take(25).join(', ')}${files.length > 25 ? ', …' : ''}');
      if (commands.isNotEmpty) {
        out.add('  live-related commands: ${(commands.toList()..sort()).take(40).join(', ')}');
      }
      for (final sn in snippets) {
        out.add('  ws: $sn');
      }
    } finally {
      client.close();
    }
  }

  Future<List<String>> run(String host, Credentials? creds, {int httpPort = 80, int rtspPort = 554}) async {
    final out = <String>['# $host'];
    final open = <int>{};
    await Future.wait(
      {...ports.keys, httpPort}.map((p) async {
        if (await _open(host, p)) open.add(p);
      }),
    );
    out.add(
      'Open ports: ${open.isEmpty ? 'none' : (open.toList()..sort()).map((p) => '$p (${ports[p] ?? 'HTTP'})').join(', ')}',
    );

    for (final p in [6036, 9008].where(open.contains)) {
      try {
        final c = await TvtNetClient.connect(host, p);
        try {
          final init = await Future.any([
            Future.doWhile(() async {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              return c.init == null;
            }).then((_) => c.init),
            Future<void>.delayed(timeout).then((_) => null),
          ]);
          if (init == null) {
            out.add('Port $p: no TVT greeting');
            continue;
          }
          out.add(
            'Port $p: TVT protocol v${init.protocolVer}, device type ${init.devType}, '
            'product ${init.productType}, login encryption ${init.loginEncrypt}',
          );
          if (creds != null) {
            try {
              final info = await c.login(creds.username, creds.password);
              out.add('  login OK${info.channels.isEmpty ? '' : ', channels ${info.channels}'}');
              // HTTP through the logged-in session: needs no Digest password.
              for (final path in ['/GetSnapshot/1', '/LAPI/V1.0/System/DeviceInfo']) {
                try {
                  final body = await c.http(path).timeout(const Duration(seconds: 4));
                  final head = String.fromCharCodes(body.take(60).where((b) => b >= 32 && b < 127));
                  out.add('  tunnel $path: ${body.length} bytes${head.isEmpty ? '' : ' "$head"'}');
                } catch (e) {
                  out.add('  tunnel $path: ${e is TimeoutException ? 'no answer' : e}');
                }
              }
            } on TvtNetException catch (e) {
              out.add('  login: $e');
            }
          }
        } finally {
          await c.close();
        }
      } on TvtNetException catch (e) {
        out.add('Port $p: $e');
      }
    }

    DigestPassword? form;
    if (creds != null && await _open(host, rtspPort)) form = await _probeRtsp(host, rtspPort, creds, out);

    if (open.contains(httpPort) && creds != null) {
      final web = TvtWebClient(
        host: host,
        port: httpPort,
        username: creds.username,
        password: creds.password,
      );
      try {
        await web.login();
        out.add('Web interface (NVMS-9000): login OK');
        try {
          final chans = await web.channels();
          out.add(
            '  Channels: ${chans.map((c) => '${c.number} ${c.online ? 'online' : 'OFFLINE'}${c.model.isEmpty ? '' : ' ${c.model}'}').join('; ')}',
          );
        } on TvtWebException catch (e) {
          out.add('  Channels: $e');
        }
        try {
          final r = await web.rtspServer();
          out.add('  RTSP service: ${r.enabled ? 'on' : 'off'}, port ${r.port}, ${r.authType}');
        } on TvtWebException catch (e) {
          out.add('  RTSP settings: $e');
        }
        try {
          out.add('  API Server: ${await web.apiServerEnabled() ? 'on' : 'off'}');
        } on TvtWebException catch (e) {
          out.add('  API Server: $e');
        }
      } on TvtWebException catch (e) {
        out.add('Web interface (NVMS-9000): ${e.notTvt ? 'not present' : e}');
      } finally {
        web.close();
      }

      await _scanWebUi(host, httpPort, out);

      final lapi = TvtLapiClient(
        host: host,
        port: httpPort,
        credentials: Credentials(creds.username, (form ?? DigestPassword.plain).apply(creds.password)),
      );
      try {
        final apis = (await lapi.supportedApis()).toList()..sort();
        out.add('HTTP API: ${apis.length} commands');
        out.add('  ${apis.join(', ')}');
        final door = apis.where(
          (a) => RegExp('door|lock|relay|alarmout|output', caseSensitive: false).hasMatch(a),
        );
        if (door.isNotEmpty) out.add('  Door/relay candidates: ${door.join(', ')}');
      } catch (e) {
        out.add('HTTP API command list: $e');
      }
      try {
        final info = await lapi.deviceInfo();
        out.add('HTTP API (${lapi.urlStyle} URLs): device info OK, ${info.length} fields');
        final model = info['deviceModel'] ?? info['model'] ?? info['productModel'];
        if (model != null) out.add('  model $model');
      } catch (e) {
        out.add('HTTP API device info: $e');
      }
      out.add('  raw device info: ${await lapi.raw('POST', '/GetDeviceInfo')}');
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, now.day);
      final end = day.add(const Duration(hours: 23, minutes: 59, seconds: 59));
      const ns = 'xmlns="http://www.ipc.com/ver10"';
      final types = await lapi.recordTypes();
      out.add('  record types: ${types.join(', ')}');
      final searches = <String, (String, String)>{
        'config + recTypes': ('/SearchByTime/1', TvtLapiClient.configSearchBody(day, end, recTypes: types)),
      };
      for (final e in searches.entries) {
        out.add('  raw ${e.key}: ${await lapi.raw('POST', e.value.$1, e.value.$2)}');
      }
      try {
        final segs = await lapi.searchByTime(1, day, end);
        out.add(
          '  recordings today (camera 1): ${segs.length}${segs.isEmpty ? '' : ', first ${segs.first.start} – ${segs.first.end} ${segs.first.type}'}',
        );
      } catch (e) {
        out.add('  recordings today (camera 1): $e');
      }
      final month =
          '<config version="2.0.0" $ns><search><year>${now.year}</year><month>${now.month}</month></search></config>';
      out.add('  raw SearchRecordDate: ${await lapi.raw('POST', '/SearchRecordDate/1', month)}');

      try {
        final jpeg = await lapi.snapshot(1);
        out.add('HTTP API snapshot (camera 1): OK, ${jpeg.length ~/ 1024} kB');
      } catch (e) {
        out.add('HTTP API snapshot (camera 1): $e');
      }
      try {
        final nat = await lapi.natInfo();
        out.add(
          'Cloud (P2P): ${nat.enabled ? 'on' : 'off'}'
          '${nat.serial == null ? '' : ', serial ${mask(nat.serial!)}'}'
          '${nat.status == null || nat.status!.isEmpty ? '' : ', status ${nat.status}'}',
        );
      } catch (_) {
        // Not every model exposes NAT settings over the HTTP API.
      }
    }
    return out;
  }
}
