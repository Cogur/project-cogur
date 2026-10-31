import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Device kinds in a Techson / TVT-style installation.
enum DeviceKind {
  /// Network video recorder (e.g. TCR I12 S04-NS). Owns the camera channels.
  nvr,

  /// Camera recorded by the NVR; streams are pulled via the NVR channel.
  camera,

  /// Outdoor door station with RFID reader (e.g. TCTDB102).
  doorStation,

  /// Indoor monitor that stores event snapshots (e.g. TCTIS716).
  indoorMonitor,
}

/// How the app may reach a device when it is not on the local network.
enum RemoteMode {
  /// LAN only. Nothing is ever sent across the internet.
  disabled,

  /// The remote host is inside a trusted tunnel (WireGuard, Tailscale,
  /// IPsec). Plain RTSP/HTTP is allowed because the tunnel encrypts it.
  vpn,

  /// Direct exposure over the internet. Only `https://` and `rtsps://` are
  /// permitted; plaintext connections are refused.
  tls,

  /// Through a HomeGuard Bridge (`tools/bridge`), which reaches the recorder
  /// by its cloud serial like SuperLive Plus does. TLS only, like [tls], but
  /// with the bridge's stream names and HTTPS API.
  bridge,
}

enum StreamQuality { main, sub }

/// What some TVT firmware expects as the "password" in RTSP/HTTP Digest:
/// the plain password, or the MD5 hex its web login also uses.
enum DigestPassword {
  plain,
  md5Upper,
  md5Lower;

  String apply(String password) => switch (this) {
    plain => password,
    md5Upper => md5.convert(utf8.encode(password)).toString().toUpperCase(),
    md5Lower => md5.convert(utf8.encode(password)).toString(),
  };
}

/// How the door relay is fired.
enum UnlockMethod {
  /// HTTP/CGI request to [DeviceConfig.unlockPath] (most OEM intercoms).
  http,

  /// TVT device protocol (port 9008): pulse alarm output
  /// [DeviceConfig.alarmOutput]. Experimental: TVT intercoms such as the
  /// TD-E3110 / Techson TCTDB102 expose no documented unlock API.
  tvtAlarmOutput,
}

class DeviceConfig {
  const DeviceConfig({
    required this.id,
    required this.name,
    required this.kind,
    this.parentId,
    this.lanHost = '',
    this.remoteHost = '',
    this.remoteMode = RemoteMode.disabled,
    this.httpPort = 80,
    this.httpsPort = 443,
    this.rtspPort = 554,
    this.rtspsPort = 322,
    this.channel = 1,
    this.rtspPathTemplate = tvtRtspTemplate,
    this.unlockPath = '',
    this.unlockMethod = 'GET',
    this.unlockBody = '',
    this.unlockVia = UnlockMethod.http,
    this.alarmOutput = 0,
    this.unlockHoldMs = 1000,
    this.netPort = 9008,
    this.digestPassword = DigestPassword.plain,
    this.eventIndexPath = '',
    this.supportsTalk = false,
    this.enabled = true,
  });

  /// RTSP path template used by TVT-family recorders (SuperLive Plus devices).
  /// `{channel}` is 1-based, `{stream}` is `main` or `sub`.
  static const tvtRtspTemplate = '/chID={channel}&streamType={stream}&linkType=tcp';

  /// Stream path of TVT cameras and door stations (`{profile}` = 1 main, 2 sub).
  static const doorStationTemplate = '/profile{profile}';

  /// The door-station default of earlier versions, which no TVT intercom serves.
  static const legacyDoorTemplate = '/live/{stream}';

  final String id;
  final String name;
  final DeviceKind kind;

  /// For cameras: the NVR they stream through. Hosts, ports and credentials
  /// are inherited from the parent.
  final String? parentId;
  final String lanHost;
  final String remoteHost;
  final RemoteMode remoteMode;
  final int httpPort;
  final int httpsPort;
  final int rtspPort;
  final int rtspsPort;
  final int channel;
  final String rtspPathTemplate;

  /// Relay trigger, relative to the device HTTP root, e.g.
  /// `/cgi-bin/accessControl.cgi?action=openDoor&channel=1`.
  final String unlockPath;
  final String unlockMethod;
  final String unlockBody;

  /// Relay mechanism. ([unlockMethod] is the HTTP verb of the `http` way.)
  final UnlockMethod unlockVia;
  final int alarmOutput;
  final int unlockHoldMs;

  /// TVT device protocol port: 9008 on cameras/intercoms, 6036 on recorders.
  final int netPort;

  /// Password form for RTSP/HTTP Digest on this device (detected at sign-in).
  final DigestPassword digestPassword;

  /// HTTP path on the indoor monitor that lists stored snapshots.
  final String eventIndexPath;
  final bool supportsTalk;
  final bool enabled;

  bool get hasVideo => kind == DeviceKind.camera || kind == DeviceKind.doorStation;
  bool get canUnlock => unlockVia == UnlockMethod.tvtAlarmOutput || unlockPath.isNotEmpty;

  /// Stream name on a HomeGuard Bridge: `/<recorder id>_ch<N>_<main|sub>`.
  String bridgePath(StreamQuality quality) => '/${parentId ?? id}_ch${channel}_${quality.name}';

  String rtspPath(StreamQuality quality) => rtspPathTemplate
      .replaceAll('{channel}', '$channel')
      .replaceAll('{channel0}', '${channel - 1}')
      .replaceAll('{stream}', quality.name)
      .replaceAll('{streamIndex}', quality == StreamQuality.main ? '0' : '1')
      .replaceAll('{profile}', quality == StreamQuality.main ? '1' : '2');

  DeviceConfig copyWith({
    String? name,
    String? lanHost,
    String? remoteHost,
    RemoteMode? remoteMode,
    int? httpPort,
    int? httpsPort,
    int? rtspPort,
    int? rtspsPort,
    int? channel,
    String? rtspPathTemplate,
    String? unlockPath,
    String? unlockMethod,
    String? unlockBody,
    UnlockMethod? unlockVia,
    int? alarmOutput,
    int? unlockHoldMs,
    int? netPort,
    DigestPassword? digestPassword,
    String? eventIndexPath,
    bool? supportsTalk,
    bool? enabled,
  }) => DeviceConfig(
    id: id,
    name: name ?? this.name,
    kind: kind,
    parentId: parentId,
    lanHost: lanHost ?? this.lanHost,
    remoteHost: remoteHost ?? this.remoteHost,
    remoteMode: remoteMode ?? this.remoteMode,
    httpPort: httpPort ?? this.httpPort,
    httpsPort: httpsPort ?? this.httpsPort,
    rtspPort: rtspPort ?? this.rtspPort,
    rtspsPort: rtspsPort ?? this.rtspsPort,
    channel: channel ?? this.channel,
    rtspPathTemplate: rtspPathTemplate ?? this.rtspPathTemplate,
    unlockPath: unlockPath ?? this.unlockPath,
    unlockMethod: unlockMethod ?? this.unlockMethod,
    unlockBody: unlockBody ?? this.unlockBody,
    unlockVia: unlockVia ?? this.unlockVia,
    alarmOutput: alarmOutput ?? this.alarmOutput,
    unlockHoldMs: unlockHoldMs ?? this.unlockHoldMs,
    netPort: netPort ?? this.netPort,
    digestPassword: digestPassword ?? this.digestPassword,
    eventIndexPath: eventIndexPath ?? this.eventIndexPath,
    supportsTalk: supportsTalk ?? this.supportsTalk,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'parentId': parentId,
    'lanHost': lanHost,
    'remoteHost': remoteHost,
    'remoteMode': remoteMode.name,
    'httpPort': httpPort,
    'httpsPort': httpsPort,
    'rtspPort': rtspPort,
    'rtspsPort': rtspsPort,
    'channel': channel,
    'rtspPathTemplate': rtspPathTemplate,
    'unlockPath': unlockPath,
    'unlockMethod': unlockMethod,
    'unlockBody': unlockBody,
    'unlockVia': unlockVia.name,
    'alarmOutput': alarmOutput,
    'unlockHoldMs': unlockHoldMs,
    'netPort': netPort,
    'digestPassword': digestPassword.name,
    'eventIndexPath': eventIndexPath,
    'supportsTalk': supportsTalk,
    'enabled': enabled,
  };

  factory DeviceConfig.fromJson(Map<String, Object?> j) => DeviceConfig(
    id: j['id']! as String,
    name: j['name'] as String? ?? '',
    kind: DeviceKind.values.byName(j['kind']! as String),
    parentId: j['parentId'] as String?,
    lanHost: j['lanHost'] as String? ?? '',
    remoteHost: j['remoteHost'] as String? ?? '',
    remoteMode: RemoteMode.values.asNameMap()[j['remoteMode']] ?? RemoteMode.disabled,
    httpPort: j['httpPort'] as int? ?? 80,
    httpsPort: j['httpsPort'] as int? ?? 443,
    rtspPort: j['rtspPort'] as int? ?? 554,
    rtspsPort: j['rtspsPort'] as int? ?? 322,
    channel: j['channel'] as int? ?? 1,
    rtspPathTemplate: j['rtspPathTemplate'] as String? ?? tvtRtspTemplate,
    unlockPath: j['unlockPath'] as String? ?? '',
    unlockMethod: j['unlockMethod'] as String? ?? 'GET',
    unlockBody: j['unlockBody'] as String? ?? '',
    unlockVia: UnlockMethod.values.asNameMap()[j['unlockVia']] ?? UnlockMethod.http,
    alarmOutput: j['alarmOutput'] as int? ?? 0,
    unlockHoldMs: j['unlockHoldMs'] as int? ?? 1000,
    netPort: j['netPort'] as int? ?? 9008,
    digestPassword: DigestPassword.values.asNameMap()[j['digestPassword']] ?? DigestPassword.plain,
    eventIndexPath: j['eventIndexPath'] as String? ?? '',
    supportsTalk: j['supportsTalk'] as bool? ?? false,
    enabled: j['enabled'] as bool? ?? true,
  );

  /// Initial topology: 1 NVR with 3 camera channels, a door station and an
  /// indoor monitor. Hosts are filled in on the login screen / settings.
  static List<DeviceConfig> defaultTopology({String nvrHost = ''}) => [
    DeviceConfig(id: 'nvr', name: 'NVR', kind: DeviceKind.nvr, lanHost: nvrHost),
    for (var ch = 1; ch <= 3; ch++)
      DeviceConfig(id: 'cam$ch', name: 'Camera $ch', kind: DeviceKind.camera, parentId: 'nvr', channel: ch),
    const DeviceConfig(
      id: 'door',
      name: 'Front Door',
      kind: DeviceKind.doorStation,
      // TVT-made door stations (Techson TCTDB102 = TVT TD-E3110) serve
      // /profile1 (main) and /profile2 (sub); ONVIF detection can override.
      rtspPathTemplate: doorStationTemplate,
      supportsTalk: true,
    ),
    const DeviceConfig(id: 'monitor', name: 'Indoor Monitor', kind: DeviceKind.indoorMonitor),
  ];
}
