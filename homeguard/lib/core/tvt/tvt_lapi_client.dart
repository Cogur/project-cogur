import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../network/device_http_client.dart';
import '../security/secure_store.dart';
import '../utils/log.dart';

class RecordSegment {
  const RecordSegment({required this.channel, required this.start, required this.end, this.type = ''});
  final int channel;
  final DateTime start;
  final DateTime end;

  /// e.g. `manual`, `schedule`, `motion`, `alarm` (firmware dependent).
  final String type;

  Duration get length => end.difference(start);
  bool contains(DateTime t) => !t.isBefore(start) && t.isBefore(end);
}

class TvtNatInfo {
  const TvtNatInfo({required this.enabled, this.serial, this.status, this.server});
  final bool enabled;

  /// Cloud ID shown in SuperLive Plus ("add by serial / QR code").
  final String? serial;
  final String? status;
  final String? server;
}

/// Client for the TVT "HTTP API" (`/LAPI/V1.0/...` and the flat
/// `/GetSnapshot/{ch}` form), enabled on the recorder as **API Server**.
///
/// The command set follows TVT's *HTTP API Protocol User Guide for IP Media
/// Device* (v1.5–2.0; copies circulate under OEM brands) as implemented in
/// pytvt. Firmware differs, so callers should check [supportedApis] first.
class TvtLapiClient {
  TvtLapiClient({
    required this.host,
    required this.credentials,
    this.port = 80,
    this.secure = false,
    DeviceHttpClient? http,
  }) : _http = http ?? DeviceHttpClient(timeout: const Duration(seconds: 8));

  final String host;
  final Credentials credentials;
  final int port;
  final bool secure;
  final DeviceHttpClient _http;
  Set<String>? _apis;

  Uri _uri(String path) => Uri(scheme: secure ? 'https' : 'http', host: host, port: port, path: path);

  /// Firmware answers either `/LAPI/V1.0/<group>/<name>` or the flat
  /// `/<CommandName>[/channel]` form of the HTTP API guide; remembered once seen.
  bool? _flat;

  /// Which URL form the device answered: `flat`, `LAPI`, or null if unknown.
  String? get urlStyle => _flat == null ? null : (_flat! ? 'flat' : 'LAPI');

  Future<XmlDocument> _post(String path, [String body = '', String? flat]) async {
    Future<http.Response> send(String p) => _http.send(
      'POST',
      _uri(p),
      credentials: credentials,
      body: body.isEmpty ? null : '<?xml version="1.0" encoding="utf-8"?>$body',
      headers: const {'Content-Type': 'application/xml', 'Accept': 'application/xml'},
    );
    http.Response res;
    if (_flat == true && flat != null) {
      res = await send(flat);
    } else {
      try {
        res = await send('/LAPI/V1.0$path');
        _flat = false;
      } on DeviceHttpException catch (e) {
        if (e.statusCode != 404 || flat == null) rethrow;
        res = await send(flat);
        _flat = true;
      }
    }
    final doc = XmlDocument.parse(res.body);
    final status = doc.findAllElements('statusCode').firstOrNull?.innerText.trim();
    if (status != null && status != '200' && status != '0') {
      final text = doc.findAllElements('statusString').firstOrNull?.innerText.trim() ?? '';
      throw DeviceHttpException('$path: device status $status $text'.trim());
    }
    return doc;
  }

  /// API names the device advertises, e.g. `SearchByTime`, `GetSnapshot`.
  Future<Set<String>> supportedApis() async {
    if (_apis != null) return _apis!;
    final doc = await _post('/System/SupportedAPIs', '', '/GetSupportedAPIs');
    // LAPI: <apiName>; HTTP API 2.0: <applicationInterfaces><item>.
    return _apis = {
      for (final e in [...doc.findAllElements('apiName'), ...doc.findAllElements('item')])
        if (e.innerText.trim().isNotEmpty) e.innerText.trim(),
    };
  }

  /// Leaf values of the device info, whatever the envelope (`<DeviceInfo>`
  /// or the `<config xmlns="http://www.ipc.com/ver10">` form).
  Future<Map<String, String>> deviceInfo() async {
    final doc = await _post('/System/DeviceInfo', '', '/GetDeviceInfo');
    return {
      for (final e in doc.rootElement.descendants.whereType<XmlElement>())
        if (e.childElements.isEmpty && e.innerText.trim().isNotEmpty) e.name.local: e.innerText.trim(),
    };
  }

  /// One request, never throwing: `HTTP 200: <first characters>` for
  /// diagnostics of undocumented firmware.
  Future<String> raw(String method, String path, [String body = '']) async {
    try {
      final res = await _http.send(
        method,
        _uri(path),
        credentials: credentials,
        body: body.isEmpty ? null : '<?xml version="1.0" encoding="utf-8"?>$body',
        headers: const {'Content-Type': 'application/xml'},
      );
      final text = res.body.replaceAll(RegExp(r'\s+'), ' ');
      return 'HTTP ${res.statusCode}: ${text.length > 300 ? '${text.substring(0, 300)}…' : text}';
    } on DeviceHttpException catch (e) {
      final b = (e.body ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      return b.isEmpty ? e.message : '${e.message}: ${b.length > 300 ? '${b.substring(0, 300)}…' : b}';
    }
  }

  /// Recording types for [configSearchBody], as the guide's examples list
  /// them; [recordTypes] asks the device for its own list.
  static const defaultRecordTypes = ['manual', 'schedule', 'motion', 'sensor', 'intel detection'];

  /// Body of the TVT HTTP API time search (`/SearchByTime/<ch>`): the
  /// `recTypes` list is required, without it the device answers
  /// "Invalid XML Content".
  static String configSearchBody(DateTime from, DateTime to, {List<String> recTypes = defaultRecordTypes}) =>
      '<config version="1.0" xmlns="http://www.ipc.com/ver10"><search>'
      '<recTypes type="list"><itemType type="recType"></itemType>'
      '${recTypes.map((t) => '<item>$t</item>').join()}</recTypes>'
      '<starttime type="string"><![CDATA[${formatTime(from, isoT: false)}]]></starttime>'
      '<endtime type="string"><![CDATA[${formatTime(to, isoT: false)}]]></endtime>'
      '</search></config>';

  List<String>? _recTypes;

  /// The device's recording types (`/GetRecordType`), else the defaults.
  Future<List<String>> recordTypes() async {
    if (_recTypes != null) return _recTypes!;
    try {
      final res = await _http.send('POST', _uri('/GetRecordType'), credentials: credentials);
      final types = [
        for (final e in XmlDocument.parse(res.body).findAllElements('item'))
          if (e.innerText.trim().isNotEmpty && e.innerText.trim() != 'nic broken') e.innerText.trim(),
      ];
      return _recTypes = types.isEmpty ? defaultRecordTypes : types;
    } catch (_) {
      return _recTypes = defaultRecordTypes;
    }
  }

  Future<TvtNatInfo> natInfo() async {
    XmlDocument doc;
    try {
      doc = await _post('/Network/NAT');
    } on DeviceHttpException {
      doc = await _post('/Network/NATConfig');
    }
    String pick(List<String> names) {
      for (final n in names) {
        final v = doc.findAllElements(n).firstOrNull?.innerText.trim();
        if (v != null && v.isNotEmpty) return v;
      }
      return '';
    }

    final enabled = pick(['enabled', 'natEnabled', 'enable']).toLowerCase();
    final serial = pick(['natSerial', 'serialNumber', 'cloudSN', 'p2pSerial', 'deviceSerial']);
    return TvtNatInfo(
      enabled: enabled == 'true' || enabled == '1',
      serial: serial.isEmpty ? null : serial,
      status: pick(['natStatus', 'status']),
      server: pick(['visitAddress', 'serverAddress']),
    );
  }

  /// Days of [year]/[month] that have recordings on [channel]. The real
  /// NVR (HTTP API 2.0) answers `<dateList><item>2026-10-7</item>…`.
  Future<Set<DateTime>> recordDates(int channel, int year, int month) async {
    final doc = await _post(
      '/Playback/SearchRecordDate',
      '<config version="2.0.0" xmlns="http://www.ipc.com/ver10"><search>'
          '<year>$year</year><month>$month</month></search></config>',
      '/SearchRecordDate/$channel',
    );
    final out = <DateTime>{};
    for (final e in [...doc.findAllElements('item'), ...doc.findAllElements('date')]) {
      final t = e.innerText.trim();
      final p = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(t);
      final d = p != null
          ? DateTime(int.parse(p[1]!), int.parse(p[2]!), int.parse(p[3]!))
          : _dayOfMonth(t, year, month);
      if (d != null) out.add(d);
    }
    return out;
  }

  static DateTime? _dayOfMonth(String t, int year, int month) {
    final day = int.tryParse(t);
    return day == null || day < 1 || day > 31 ? null : DateTime(year, month, day);
  }

  /// Device-local wall-clock time, formatted as the HTTP API expects.
  static String formatTime(DateTime t, {bool isoT = true}) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}${isoT ? 'T' : ' '}'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Recording segments of [channel] between [from] and [to].
  /// Which request body the device accepted for time search (remembered).
  int? _searchStyle;

  Future<List<RecordSegment>> searchByTime(int channel, DateTime from, DateTime to) async {
    String lapiBody(bool isoT) =>
        '<SearchByTime><channelID>$channel</channelID>'
        '<startTime>${formatTime(from, isoT: isoT)}</startTime>'
        '<endTime>${formatTime(to, isoT: isoT)}</endTime></SearchByTime>';
    final types = await recordTypes();
    final styles = <Future<XmlDocument> Function()>[
      () => _post(
        '/Playback/SearchByTime',
        configSearchBody(from, to, recTypes: types),
        '/SearchByTime/$channel',
      ),
      () => _post('/Playback/SearchByTime', lapiBody(true), '/SearchByTime/$channel'),
      () => _post('/Playback/SearchByTime', lapiBody(false), '/SearchByTime/$channel'),
    ];
    final order = [?_searchStyle, ...List.generate(styles.length, (i) => i)];
    XmlDocument? doc;
    DeviceHttpException? last;
    for (final i in order.toSet()) {
      try {
        doc = await styles[i]();
        _searchStyle = i;
        break;
      } on DeviceHttpException catch (e) {
        // 400: wrong body form for this firmware; anything else is final.
        if (e.statusCode != 400 && !e.message.contains('device status')) rethrow;
        Log.d('lapi', 'SearchByTime form $i rejected ($e)');
        last = e;
      }
    }
    if (doc == null) throw last ?? DeviceHttpException('Recording search failed');
    return parseSegments(doc, channel);
  }

  /// Any element with start/end time children is a segment, whatever the
  /// firmware calls the envelope (`RecordSegment`, `item`, …).
  static List<RecordSegment> parseSegments(XmlDocument doc, int channel) {
    String? child(XmlElement e, RegExp name) =>
        e.childElements.where((c) => name.hasMatch(c.name.local)).firstOrNull?.innerText.trim();
    final startName = RegExp(r'^start.?time$', caseSensitive: false);
    final endName = RegExp(r'^(end|stop).?time$', caseSensitive: false);
    final out = <RecordSegment>[];
    for (final e in doc.descendants.whereType<XmlElement>()) {
      final s = _parseTime(child(e, startName) ?? '');
      final end = _parseTime(child(e, endName) ?? '');
      if (s == null || end == null || !end.isAfter(s)) continue;
      out.add(
        RecordSegment(
          channel:
              int.tryParse(child(e, RegExp(r'^(channelID|chl?id|channel)$', caseSensitive: false)) ?? '') ??
              channel,
          start: s,
          end: end,
          type: child(e, RegExp(r'type$', caseSensitive: false)) ?? '',
        ),
      );
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static DateTime? _parseTime(String t) => DateTime.tryParse(t.replaceFirst(' ', 'T'));

  /// JPEG of the live picture. Tries the documented flat URL first.
  Future<Uint8List> snapshot(int channel) async {
    DeviceHttpException? last;
    for (final path in ['/GetSnapshot/$channel', '/LAPI/V1.0/Image/Channels/$channel/Snapshot']) {
      try {
        final res = await _http.send(
          'GET',
          _uri(path),
          credentials: credentials,
          headers: const {'Accept': 'image/jpeg'},
        );
        if (res.bodyBytes.length > 100) return res.bodyBytes;
      } on DeviceHttpException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 403) rethrow;
        last = e;
      }
    }
    throw last ?? DeviceHttpException('Snapshot not available');
  }
}
