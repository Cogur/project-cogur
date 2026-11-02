import 'package:flutter/foundation.dart';

/// Logging that never leaks credentials.
///
/// Debug builds print to the console. Warnings and errors always go to an
/// in-memory ring buffer; with [verbose] on (Settings → Detailed logs) debug
/// lines do too, so the user can copy them from Settings → Logs. Nothing is
/// written to disk and everything is redacted.
abstract final class Log {
  static const _capacity = 6000;
  static final List<String> _ring = [];

  /// Keep debug lines (video, playback, network) for the Logs screen.
  static bool verbose = false;

  static List<String> get recent => List.unmodifiable(_ring);

  static void clear() => _ring.clear();

  static void d(String tag, String message) {
    if (verbose) {
      _keep('D', tag, message);
    } else if (kDebugMode) {
      debugPrint('[$tag] ${redact(message)}');
    }
  }

  static void w(String tag, String message) => _keep('W', tag, message);
  static void e(String tag, String message) => _keep('E', tag, message);

  static String _time() {
    final t = DateTime.now();
    String two(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${two(t.millisecond, 3)}';
  }

  static void _keep(String level, String tag, String message) {
    final line = '${_time()} $level/$tag ${redact(message)}';
    if (kDebugMode) debugPrint(line);
    _ring.add(line);
    if (_ring.length > _capacity) _ring.removeRange(0, _ring.length - _capacity);
  }

  static final _userInfo = RegExp(r'([a-z][a-z0-9+.-]*://)[^/@\s]+@', caseSensitive: false);
  static final _authHeader = RegExp(r'(Authorization:\s*)(\S+\s+)?[^\r\n]+', caseSensitive: false);
  static final _queryCreds = RegExp(
    r'([?&](?:password|pwd|pass|token|user|username)=)[^&\s]+',
    caseSensitive: false,
  );

  /// Strips `user:pass@` from URLs, auth headers and credential query params.
  static String redact(String input) => input
      .replaceAllMapped(_userInfo, (m) => '${m[1]}***@')
      .replaceAllMapped(_authHeader, (m) => '${m[1]}***')
      .replaceAllMapped(_queryCreds, (m) => '${m[1]}***');

  static String redactUrl(String url) => redact(url);
}
