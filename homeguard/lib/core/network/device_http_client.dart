import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../rtsp/digest_auth.dart';
import '../security/secure_store.dart';
import '../utils/log.dart';

class DeviceHttpException implements Exception {
  DeviceHttpException(this.message, {this.statusCode, this.body});
  final String message;
  final int? statusCode;

  /// What the device sent with the error (often says what it disliked).
  final String? body;
  @override
  String toString() => message;
}

/// HTTP client for device CGI/API calls with Basic/Digest authentication.
///
/// Every request has a hard timeout; a hung relay endpoint must never freeze
/// the door-unlock button.
class DeviceHttpClient {
  DeviceHttpClient({http.Client? inner, this.timeout = const Duration(seconds: 5)})
    : _inner = inner ?? http.Client();

  final http.Client _inner;
  final Duration timeout;

  Future<http.Response> send(
    String method,
    Uri uri, {
    Credentials? credentials,
    String? body,
    Map<String, String> headers = const {},
  }) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw DeviceHttpException('Unsupported scheme ${uri.scheme}');
    }
    Future<http.Response> attempt(String? authorization) async {
      final req = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(headers);
      if (authorization != null) req.headers['Authorization'] = authorization;
      if (body != null && body.isNotEmpty) req.body = body;
      final streamed = await _inner.send(req).timeout(timeout);
      return http.Response.fromStream(streamed).timeout(timeout);
    }

    try {
      var res = await attempt(null);
      if (res.statusCode == 401 && credentials != null && !credentials.isEmpty) {
        final challenge = AuthChallenge.pickBest(
          (res.headers['www-authenticate'] ?? '').split(RegExp(r',\s*(?=(?:Digest|Basic)\s)')),
        );
        if (challenge == null) {
          throw DeviceHttpException('Device uses an unsupported auth scheme', statusCode: 401);
        }
        final auth = DigestAuthenticator(
          username: credentials.username,
          password: credentials.password,
        ).authorize(challenge: challenge, method: method, uri: _requestUri(uri));
        res = await attempt(auth);
      }
      Log.d('http', '$method ${Log.redactUrl(uri.toString())} → ${res.statusCode}');
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw DeviceHttpException('Device rejected the credentials', statusCode: res.statusCode);
      }
      if (res.statusCode >= 400) {
        throw DeviceHttpException(
          'Device returned HTTP ${res.statusCode}',
          statusCode: res.statusCode,
          body: res.body,
        );
      }
      return res;
    } on TimeoutException {
      throw DeviceHttpException('${uri.host} did not answer within ${timeout.inSeconds}s');
    } on SocketException catch (e) {
      throw DeviceHttpException('Cannot reach ${uri.host}: ${e.osError?.message ?? e.message}');
    } on HandshakeException catch (e) {
      throw DeviceHttpException('TLS certificate rejected for ${uri.host}: ${e.message}');
    } on http.ClientException catch (e) {
      throw DeviceHttpException('Request to ${uri.host} failed: ${e.message}');
    }
  }

  static String _requestUri(Uri uri) => uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

  void close() => _inner.close();
}
