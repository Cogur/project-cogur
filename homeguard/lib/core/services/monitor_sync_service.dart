import 'dart:convert';
import 'dart:typed_data';

import '../network/connection_manager.dart';
import '../network/device_http_client.dart';
import '../utils/log.dart';
import 'device_registry.dart';
import 'event_store.dart';

/// Pulls new snapshots/clips from the indoor monitor's SD card over HTTP.
///
/// The monitor's [eventIndexPath] may return either a JSON array of file
/// paths, or an HTML directory listing (`<a href="...jpg">`), which covers
/// the built-in web servers seen on most intercom firmwares. Files are
/// downloaded once, then stored and served locally.
class MonitorSyncService {
  MonitorSyncService(this._registry, this._connections, this._http, this._events);

  final DeviceRegistry _registry;
  final ConnectionManager _connections;
  final DeviceHttpClient _http;
  final EventStore _events;

  static final _href = RegExp(
    r'''href\s*=\s*["']([^"'?#]+\.(?:jpe?g|png|bmp|mp4|avi|mov|264|265))["']''',
    caseSensitive: false,
  );

  static List<String> parseIndex(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('[')) {
      return (jsonDecode(trimmed) as List).map((e) => e is Map ? '${e['path'] ?? e['url']}' : '$e').toList();
    }
    return _href.allMatches(body).map((m) => m.group(1)!).toSet().toList();
  }

  /// Returns the number of new items imported.
  Future<int> sync(String deviceId, {int maxDownloads = 50}) async {
    final device = _registry.byId(deviceId);
    if (device == null || device.eventIndexPath.isEmpty) {
      throw DeviceHttpException('No event index path configured for the indoor monitor');
    }
    final route = await _connections.require(deviceId);
    final creds = _registry.mediaCredentialsFor(deviceId);
    final indexUri = route.httpUri(device.eventIndexPath);
    final index = await _http.send('GET', indexUri, credentials: creds);
    final entries = parseIndex(index.body);

    final files = <(String, Uint8List)>[];
    for (final entry in entries.reversed) {
      final name = Uri.decodeComponent(entry.split('/').last);
      if (_events.hasSource(name)) continue;
      if (files.length >= maxDownloads) break;
      final uri = indexUri.resolve(entry);
      // Never follow an index entry off the device we authenticated to.
      if (uri.host != indexUri.host) {
        Log.w('sync', 'skipping off-device link ${Log.redactUrl(uri.toString())}');
        continue;
      }
      try {
        final res = await _http.send('GET', uri, credentials: creds);
        files.add((name, res.bodyBytes));
      } on DeviceHttpException catch (e) {
        Log.w('sync', 'download failed for $name: $e');
      }
    }
    return _events.importFiles(files, deviceId: deviceId);
  }
}
