import 'dart:async';
import 'dart:typed_data';

import '../utils/log.dart';
import 'rtsp_client.dart';
import 'rtsp_message.dart';
import 'sdp.dart';

/// What arrived on one RTP video track: enough to tell "the NVR sends
/// nothing" from "it sends no keyframe" from "the decoder fails".
class RtpStats {
  RtpStats(this.codec);
  final String codec;
  int packets = 0;
  int bytes = 0;
  int rtcp = 0;
  int otherChannels = 0;
  int seqGaps = 0;
  int? lastSeq;
  int? firstTs;
  int? lastTs;
  int? firstPacketMs;
  int? firstParamSetMs;
  int? firstKeyframeMs;
  int keyframes = 0;
  final nalCounts = <String, int>{};
  final firstNals = <String>[];

  bool get hevc => codec.contains('265') || codec.contains('HEVC');

  String summary(int atMs) {
    final kbps = atMs <= 0 ? 0 : (bytes * 8 / atMs).round();
    final span = firstTs == null || lastTs == null ? '-' : '${((lastTs! - firstTs!) & 0xffffffff) / 90000} s';
    return 'at $atMs ms: $packets RTP packets, $bytes bytes (~$kbps kbit/s), rtcp $rtcp, '
        'other channels $otherChannels, seq gaps $seqGaps, media time $span, '
        'first packet ${firstPacketMs ?? '-'} ms, first VPS/SPS/PPS ${firstParamSetMs ?? '-'} ms, '
        'first keyframe ${firstKeyframeMs ?? '-'} ms, keyframes $keyframes, NAL types $nalCounts';
  }
}

/// Opens an RTSP stream with HomeGuard's own client (not the player),
/// reads the video RTP for a while and reports what it contains.
class RtpInspector {
  RtpInspector({
    required this.uri,
    required this.username,
    required this.password,
    this.listen = const Duration(seconds: 20),
    this.tag = 'rtp',
  });

  /// Stream URI without credentials.
  final Uri uri;
  final String username;
  final String password;
  final Duration listen;
  final String tag;

  final _stop = Completer<void>();
  void stop() {
    if (!_stop.isCompleted) _stop.complete();
  }

  Future<RtpStats?> run(void Function(String line) out) async {
    void say(String l) {
      Log.d(tag, l);
      out(l);
    }

    final client = RtspClient(
      uri: uri,
      username: username,
      password: password,
      connectTimeout: const Duration(seconds: 6),
      responseTimeout: const Duration(seconds: 10),
    );
    final sw = Stopwatch()..start();
    RtpStats? stats;
    try {
      say('connect ${Log.redactUrl(uri.toString())}');
      await client.connect();
      final options = await client.request('OPTIONS');
      say('OPTIONS ok in ${sw.elapsedMilliseconds} ms, server: ${options.header('server') ?? '-'}');
      final describe = await client.request('DESCRIBE', headers: {'Accept': 'application/sdp'});
      say(
        'DESCRIBE ok in ${sw.elapsedMilliseconds} ms, content-base ${describe.header('content-base') ?? '-'}',
      );
      for (final l in describe.body.split(RegExp(r'\r?\n'))) {
        if (l.trim().isNotEmpty) say('  sdp ${Log.redactUrl(l.trim())}');
      }
      final sdp = SdpSession.parse(describe.body);
      final base = describe.header('content-base') ?? describe.header('content-location') ?? uri.toString();
      final video = sdp.video.firstOrNull;
      if (video == null) {
        say('no video track in SDP');
        return null;
      }
      stats = RtpStats(video.codec);
      final setup = await client.setupInterleaved(video.resolveControl(base));
      say('SETUP ok in ${sw.elapsedMilliseconds} ms, transport ${setup.header('transport') ?? '-'}');
      final playStart = Stopwatch();
      final s = stats;
      client.onPacket = (p) => _onPacket(s, p, playStart.elapsedMilliseconds, say);
      playStart.start();
      final play = await client.request('PLAY', url: base, headers: {'Range': 'npt=0.000-'});
      say(
        'PLAY ok in ${playStart.elapsedMilliseconds} ms, range ${play.header('range') ?? '-'}, '
        'rtp-info ${play.header('rtp-info') ?? '-'}, scale ${play.header('scale') ?? '-'}',
      );
      final ticker = Timer.periodic(
        const Duration(seconds: 5),
        (_) => say(s.summary(playStart.elapsedMilliseconds)),
      );
      await Future.any([Future<void>.delayed(listen), _stop.future]);
      ticker.cancel();
      if (s.firstNals.length < 30) say('first NAL units: ${s.firstNals.join(' ')}');
      say('result ${s.summary(playStart.elapsedMilliseconds)}');
      if (s.packets == 0) {
        say('verdict: the NVR sent no video data');
      } else if (s.firstKeyframeMs == null) {
        say('verdict: video data but no keyframe: players can only show a black or partial picture');
      } else {
        say('verdict: keyframe after ${s.firstKeyframeMs} ms: the stream is decodable from there');
      }
      return s;
    } on RtspException catch (e) {
      say('failed after ${sw.elapsedMilliseconds} ms: ${e.message} ${e.detail ?? ''}');
      return stats;
    } catch (e) {
      say('failed after ${sw.elapsedMilliseconds} ms: $e');
      return stats;
    } finally {
      await client.close();
      say('closed (TEARDOWN sent)');
    }
  }

  static void _onPacket(RtpStats s, InterleavedPacket p, int ms, void Function(String) say) {
    if (p.channel == 1) {
      s.rtcp++;
      return;
    }
    if (p.channel != 0) {
      s.otherChannels++;
      return;
    }
    final b = p.payload;
    if (s.packets == 0) {
      s.firstPacketMs = ms;
      say('first packet at $ms ms, ${b.length} bytes, head ${_hex(b, 16)}');
    }
    s.packets++;
    s.bytes += b.length;
    if (b.length < 12 || (b[0] >> 6) != 2) return;
    final cc = b[0] & 0x0f;
    final ext = (b[0] & 0x10) != 0;
    final seq = (b[2] << 8) | b[3];
    final ts = ByteData.sublistView(b).getUint32(4);
    if (s.lastSeq != null && seq != ((s.lastSeq! + 1) & 0xffff)) s.seqGaps++;
    s.lastSeq = seq;
    s.firstTs ??= ts;
    s.lastTs = ts;
    var off = 12 + 4 * cc;
    if (ext && b.length >= off + 4) off += 4 + 4 * ((b[off + 2] << 8) | b[off + 3]);
    if (off >= b.length) return;
    final payload = Uint8List.sublistView(b, off);
    for (final nal in s.hevc ? _hevcNals(payload) : _avcNals(payload)) {
      _countNal(s, nal, ms, say);
    }
  }

  /// NAL unit types starting in this packet (aggregates opened, fragments
  /// counted on their start).
  static List<int> _hevcNals(Uint8List p) {
    if (p.length < 2) return const [];
    final type = (p[0] >> 1) & 0x3f;
    if (type == 48) {
      final out = <int>[];
      var i = 2;
      while (i + 2 < p.length) {
        final size = (p[i] << 8) | p[i + 1];
        if (i + 2 >= p.length) break;
        out.add((p[i + 2] >> 1) & 0x3f);
        i += 2 + size;
      }
      return out;
    }
    if (type == 49) {
      if (p.length < 3 || (p[2] & 0x80) == 0) return const [];
      return [p[2] & 0x3f];
    }
    return [type];
  }

  static List<int> _avcNals(Uint8List p) {
    if (p.isEmpty) return const [];
    final type = p[0] & 0x1f;
    if (type == 24) {
      final out = <int>[];
      var i = 1;
      while (i + 2 < p.length) {
        final size = (p[i] << 8) | p[i + 1];
        out.add(p[i + 2] & 0x1f);
        i += 2 + size;
      }
      return out;
    }
    if (type == 28) {
      if (p.length < 2 || (p[1] & 0x80) == 0) return const [];
      return [p[1] & 0x1f];
    }
    return [type];
  }

  static void _countNal(RtpStats s, int type, int ms, void Function(String) say) {
    final name = s.hevc ? _hevcName(type) : _avcName(type);
    s.nalCounts[name] = (s.nalCounts[name] ?? 0) + 1;
    final param = s.hevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
    final key = s.hevc ? (type >= 16 && type <= 21) : type == 5;
    if (param) s.firstParamSetMs ??= ms;
    if (key) {
      s.keyframes++;
      if (s.firstKeyframeMs == null) {
        s.firstKeyframeMs = ms;
        say('first keyframe ($name) at $ms ms');
      }
    }
    if (s.firstNals.length < 30) {
      s.firstNals.add('$name@$ms');
      if (s.firstNals.length == 30) say('first NAL units: ${s.firstNals.join(' ')}');
    }
  }

  static String _hevcName(int t) => switch (t) {
    32 => 'VPS',
    33 => 'SPS',
    34 => 'PPS',
    35 => 'AUD',
    39 || 40 => 'SEI',
    19 || 20 => 'IDR',
    21 => 'CRA',
    16 || 17 || 18 => 'BLA',
    < 10 => 'P/B',
    _ => 'T$t',
  };

  static String _avcName(int t) => switch (t) {
    7 => 'SPS',
    8 => 'PPS',
    5 => 'IDR',
    6 => 'SEI',
    9 => 'AUD',
    1 => 'P/B',
    _ => 'T$t',
  };

  static String _hex(Uint8List b, int n) =>
      b.take(n).map((v) => v.toRadixString(16).padLeft(2, '0')).join(' ');
}
