import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../utils/log.dart';
import 'digest_auth.dart';
import 'rtsp_message.dart';
import 'sdp.dart';

class RtspException implements Exception {
  RtspException(this.message, {this.statusCode, this.detail});
  final String message;
  final int? statusCode;

  /// What the device actually answered (status line, auth schemes, server),
  /// shown to the user so login problems can be diagnosed without tools.
  final String? detail;

  bool get isAuthFailure => statusCode == 401 || statusCode == 403;

  @override
  String toString() =>
      statusCode == null ? 'RtspException: $message' : 'RtspException($statusCode): $message';
}

/// Result of an RTSP DESCRIBE probe.
class RtspProbeResult {
  RtspProbeResult({required this.latency, required this.sdp, required this.server});

  final Duration latency;
  final SdpSession sdp;
  final String? server;

  String get videoCodec => sdp.video.firstOrNull?.codec ?? 'none';
  String get audioCodec => sdp.audio.where((m) => m.direction != 'sendonly').firstOrNull?.codec ?? 'none';
  bool get hasBackchannel => sdp.backchannel != null;
}

/// A small RTSP/1.0 control client over TCP (or TLS for `rtsps://`).
///
/// Video decoding is left to the native player (libmpv via media_kit). This
/// client covers what the player cannot do: credential verification, stream
/// diagnostics, and the ONVIF audio back-channel used for two-way talk.
class RtspClient {
  RtspClient({
    required this.uri,
    required this.username,
    required this.password,
    this.connectTimeout = const Duration(seconds: 4),
    this.responseTimeout = const Duration(seconds: 6),
    this.userAgent = 'HomeGuard/1.0',
  });

  /// Stream URI **without** embedded credentials.
  final Uri uri;
  final String username;
  final String password;
  final Duration connectTimeout;
  final Duration responseTimeout;
  final String userAgent;

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  final _parser = RtspStreamParser();
  final _waiters = <int, Completer<RtspResponse>>{};
  int _cseq = 0;
  String? _session;
  AuthChallenge? _challenge;
  late final DigestAuthenticator _auth = DigestAuthenticator(username: username, password: password);
  Timer? _keepAlive;
  bool _closed = false;

  bool get isConnected => _socket != null && !_closed;

  /// Receives interleaved RTP/RTCP packets after PLAY (diagnostics).
  void Function(InterleavedPacket packet)? onPacket;

  /// SETUP of one track over the RTSP connection; keeps the session id.
  Future<RtspResponse> setupInterleaved(String url, {int channel = 0}) async {
    final r = await request(
      'SETUP',
      url: url,
      headers: {'Transport': 'RTP/AVP/TCP;unicast;interleaved=$channel-${channel + 1}'},
    );
    _session = r.session;
    return r;
  }

  Future<void> connect() async {
    final port = uri.hasPort ? uri.port : (uri.scheme == 'rtsps' ? 322 : 554);
    try {
      _socket = uri.scheme == 'rtsps'
          ? await SecureSocket.connect(uri.host, port, timeout: connectTimeout)
          : await Socket.connect(uri.host, port, timeout: connectTimeout);
    } on SocketException catch (e) {
      throw RtspException('Cannot reach ${uri.host}:$port (${e.osError?.message ?? e.message})');
    } on HandshakeException catch (e) {
      throw RtspException('TLS handshake with ${uri.host} failed: ${e.message}');
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket!.listen(
      _onData,
      onError: (Object e) => _failAll(RtspException('Connection error: $e')),
      onDone: () => _failAll(RtspException('Connection closed by device')),
      cancelOnError: true,
    );
  }

  void _onData(Uint8List data) {
    try {
      _parser.add(data);
    } on FormatException catch (e) {
      _failAll(RtspException('Protocol error: ${e.message}'));
      return;
    }
    for (final r in _parser.responses) {
      final waiter = _waiters.remove(r.cseq);
      if (waiter != null && !waiter.isCompleted) waiter.complete(r);
    }
    _parser.responses.clear();
    // Inbound RTP is only wanted by diagnostics (RtpInspector).
    final listener = onPacket;
    if (listener != null) _parser.packets.forEach(listener);
    _parser.packets.clear();
  }

  void _failAll(Object error) {
    for (final w in _waiters.values) {
      if (!w.isCompleted) w.completeError(error);
    }
    _waiters.clear();
  }

  Future<RtspResponse> request(String method, {String? url, Map<String, String> headers = const {}}) async {
    final target = url ?? uri.toString();
    var response = await _send(method, target, headers);
    if (response.statusCode == 401) {
      final offered = response.headerAll('www-authenticate');
      final challenge = AuthChallenge.pickBest(offered);
      if (challenge == null) {
        throw RtspException(
          'Device requires unsupported authentication',
          statusCode: 401,
          detail: _describe(response),
        );
      }
      _challenge = challenge;
      response = await _send(method, target, headers);
      // Some recorder firmwares mis-handle Digest but also offer Basic.
      // Routes are only ever LAN, VPN or TLS (see ConnectionManager), so a
      // single Basic retry does not expose credentials to the internet.
      if (response.statusCode == 401 && challenge.isDigest) {
        final basic = AuthChallenge.pickBest(
          offered.where((h) => h.trimLeft().toLowerCase().startsWith('basic')),
        );
        if (basic != null) {
          _challenge = basic;
          response = await _send(method, target, headers);
        }
      }
    }
    if (!response.ok) {
      throw RtspException(
        switch (response.statusCode) {
          401 => 'Invalid username or password',
          403 => 'Access forbidden for this user or stream',
          _ => '$method failed: ${response.statusCode} ${response.reason}',
        },
        statusCode: response.statusCode,
        detail: _describe(response),
      );
    }
    return response;
  }

  static String _describe(RtspResponse r) {
    final auth = r
        .headerAll('www-authenticate')
        .map((h) {
          final c = AuthChallenge.parse(h);
          if (c == null) return h;
          final alg = c.params['algorithm'];
          return '${c.scheme}${alg == null ? '' : ' $alg'}${c.realm.isEmpty ? '' : ' realm "${c.realm}"'}';
        })
        .join(', ');
    return [
      'RTSP ${r.statusCode} ${r.reason}'.trim(),
      if (auth.isNotEmpty) 'auth: $auth',
      if (r.header('server') != null) 'server: ${r.header('server')}',
    ].join(' · ');
  }

  Future<RtspResponse> _send(String method, String url, Map<String, String> headers) {
    final socket = _socket;
    if (socket == null || _closed) {
      throw RtspException('Not connected');
    }
    final cseq = ++_cseq;
    final lines = <String>[
      '$method $url RTSP/1.0',
      'CSeq: $cseq',
      'User-Agent: $userAgent',
      if (_session != null) 'Session: $_session',
      if (_challenge != null)
        'Authorization: ${_auth.authorize(challenge: _challenge!, method: method, uri: url)}',
      for (final e in headers.entries) '${e.key}: ${e.value}',
    ];
    final completer = Completer<RtspResponse>();
    _waiters[cseq] = completer;
    socket.add(latin1.encode('${lines.join('\r\n')}\r\n\r\n'));
    Log.d('rtsp', '$method ${Log.redactUrl(url)} (CSeq $cseq)');
    return completer.future.timeout(
      responseTimeout,
      onTimeout: () {
        _waiters.remove(cseq);
        throw RtspException('$method timed out after ${responseTimeout.inSeconds}s');
      },
    );
  }

  Future<(SdpSession, String)> describe({bool backchannel = false}) async {
    final r = await request(
      'DESCRIBE',
      headers: {'Accept': 'application/sdp', if (backchannel) 'Require': 'www.onvif.org/ver20/backchannel'},
    );
    final base = r.header('content-base') ?? r.header('content-location') ?? uri.toString();
    return (SdpSession.parse(r.body), base);
  }

  /// Connects, authenticates and DESCRIBEs the stream, then disconnects.
  static Future<RtspProbeResult> probe({
    required Uri uri,
    required String username,
    required String password,
    Duration timeout = const Duration(seconds: 4),
    bool backchannel = true,
  }) async {
    final client = RtspClient(
      uri: uri,
      username: username,
      password: password,
      connectTimeout: timeout,
      responseTimeout: timeout,
    );
    final sw = Stopwatch()..start();
    try {
      await client.connect();
      final options = await client.request('OPTIONS');
      final (sdp, _) = await client.describe(backchannel: backchannel);
      return RtspProbeResult(latency: sw.elapsed, sdp: sdp, server: options.header('server'));
    } finally {
      await client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // ONVIF audio back-channel (ONVIF Streaming Spec §5.3)
  // ---------------------------------------------------------------------------

  int _rtpSeq = 0;
  int _rtpTimestamp = 0;
  final int _ssrc = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
  int _rtpChannel = 0;
  int _payloadType = 0;

  /// Sets up the back-channel track and starts the session.
  ///
  /// Returns the negotiated payload type (0 = PCMU, 8 = PCMA).
  Future<int> startBackchannel() async {
    final (sdp, base) = await describe(backchannel: true);
    final track = sdp.backchannel;
    if (track == null) {
      throw RtspException('Device does not advertise an ONVIF audio back-channel');
    }
    _payloadType = track.payloadTypes.contains(0)
        ? 0
        : track.payloadTypes.contains(8)
        ? 8
        : throw RtspException('Back-channel codec ${track.codec} is not G.711');
    final setup = await request(
      'SETUP',
      url: track.resolveControl(base),
      headers: {
        'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1',
        'Require': 'www.onvif.org/ver20/backchannel',
      },
    );
    _session = setup.session;
    final transport = setup.header('transport') ?? '';
    final m = RegExp(r'interleaved=(\d+)').firstMatch(transport);
    _rtpChannel = int.tryParse(m?.group(1) ?? '') ?? 0;
    await request(
      'PLAY',
      url: base,
      headers: {'Range': 'npt=0.000-', 'Require': 'www.onvif.org/ver20/backchannel'},
    );
    final interval = Duration(seconds: (setup.sessionTimeout / 2).clamp(5, 30).toInt());
    _keepAlive = Timer.periodic(interval, (_) {
      request('GET_PARAMETER').catchError((Object e) {
        Log.w('rtsp', 'keep-alive failed: $e');
        return RtspResponse(statusCode: 0, reason: '', headers: {}, body: '');
      });
    });
    return _payloadType;
  }

  /// Sends one block of G.711 samples (8 kHz, so 1 byte == 1 timestamp tick).
  void sendAudio(Uint8List g711) {
    final socket = _socket;
    if (socket == null || _closed) return;
    // Keep packets ≤ 40 ms (320 samples) to limit jitter on the device.
    for (var off = 0; off < g711.length; off += 320) {
      final end = (off + 320).clamp(0, g711.length);
      final chunk = Uint8List.sublistView(g711, off, end);
      final rtp = Uint8List(12 + chunk.length);
      final v = ByteData.sublistView(rtp);
      v.setUint8(0, 0x80); // V=2
      // Marker bit flags the first packet of a talk-spurt (RFC 3551 §4.1).
      v.setUint8(1, (_rtpSeq == 0 ? 0x80 : 0) | _payloadType);
      v.setUint16(2, _rtpSeq & 0xffff);
      v.setUint32(4, _rtpTimestamp & 0xffffffff);
      v.setUint32(8, _ssrc);
      rtp.setRange(12, rtp.length, chunk);
      _rtpSeq++;
      _rtpTimestamp += chunk.length;
      final frame = Uint8List(4 + rtp.length)
        ..[0] = 0x24
        ..[1] = _rtpChannel
        ..[2] = (rtp.length >> 8) & 0xff
        ..[3] = rtp.length & 0xff
        ..setRange(4, 4 + rtp.length, rtp);
      socket.add(frame);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _keepAlive?.cancel();
    if (_session != null && _socket != null) {
      try {
        await request('TEARDOWN').timeout(const Duration(seconds: 1));
      } catch (_) {
        // Best effort: the device will time the session out anyway.
      }
    }
    _closed = true;
    _failAll(RtspException('Client closed'));
    await _sub?.cancel();
    _socket?.destroy();
    _socket = null;
  }
}
