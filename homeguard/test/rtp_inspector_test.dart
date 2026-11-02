import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:homeguard/core/rtsp/rtp_inspector.dart';

/// Minimal RTSP server: answers the inspector and sends a few H.265 RTP
/// packets (P frame, VPS, then a fragmented IDR) over the TCP connection.
Future<ServerSocket> _server() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((sock) {
    var buf = '';
    sock.listen((data) {
      buf += latin1.decode(data);
      while (buf.contains('\r\n\r\n')) {
        final end = buf.indexOf('\r\n\r\n');
        final req = buf.substring(0, end);
        buf = buf.substring(end + 4);
        final method = req.split(' ').first;
        final cseq = RegExp(r'CSeq: (\d+)').firstMatch(req)!.group(1);
        var headers = 'CSeq: $cseq\r\n';
        var body = '';
        if (method == 'DESCRIBE') {
          body = 'v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H265/90000\r\na=control:track1\r\n';
          headers += 'Content-Type: application/sdp\r\nContent-Base: rtsp://127.0.0.1/x/\r\n';
        }
        if (method == 'SETUP')
          headers += 'Session: 42;timeout=60\r\nTransport: RTP/AVP/TCP;interleaved=0-1\r\n';
        if (method == 'PLAY') headers += 'Range: npt=0.000-\r\n';
        sock.add(latin1.encode('RTSP/1.0 200 OK\r\n${headers}Content-Length: ${body.length}\r\n\r\n$body'));
        if (method == 'PLAY') {
          var seq = 0;
          void rtp(List<int> payload) {
            final p = [0x80, 96, (seq >> 8) & 0xff, seq++ & 0xff, 0, 0, 0, 1, 0, 0, 0, 7, ...payload];
            sock.add(Uint8List.fromList([0x24, 0, p.length >> 8, p.length & 0xff, ...p]));
          }

          rtp([0x02, 0x01, 0xaa]); // TRAIL_R (P/B)
          rtp([32 << 1, 0x01, 0xbb]); // VPS
          rtp([49 << 1, 0x01, 0x80 | 19, 0xcc]); // FU start of IDR_W_RADL
          rtp([49 << 1, 0x01, 19, 0xdd]); // FU continuation: not counted
        }
      }
    });
  });
  return server;
}

void main() {
  test('RTP inspector counts packets, parameter sets and keyframes', () async {
    final server = await _server();
    addTearDown(server.close);
    final lines = <String>[];
    final stats = await RtpInspector(
      uri: Uri.parse('rtsp://127.0.0.1:${server.port}/x'),
      username: 'u',
      password: 'p',
      listen: const Duration(milliseconds: 400),
    ).run(lines.add);
    expect(stats, isNotNull);
    expect(stats!.packets, 4);
    expect(stats.nalCounts, {'P/B': 1, 'VPS': 1, 'IDR': 1});
    expect(stats.keyframes, 1);
    expect(stats.firstKeyframeMs, isNotNull);
    expect(lines.any((l) => l.startsWith('verdict: keyframe')), isTrue, reason: lines.join('\n'));
  });
}
