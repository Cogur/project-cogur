# HomeGuard: local-first security app

HomeGuard is a Flutter app for Android and iOS. It replaces SuperLive Plus for a Techson installation:

| Device | Model | How HomeGuard talks to it |
|---|---|---|
| NVR | TCR I12 S04-NS | **Sign-in** through the NVR's own web interface (same account as SuperLive Plus); camera list and RTSP/API settings from it; video over RTSP (`/chID={n}&streamType=main\|sub`); recordings via the TVT HTTP API |
| Cameras ×3 | (via NVR channels) | RTSP through the NVR; names and count follow the NVR automatically |
| Outdoor door station + Mifare RFID | TCTDB102 (= TVT TD-E3110) | RTSP/ONVIF video, ONVIF back-channel for talk; unlock over HTTP **or the TVT device protocol (experimental)** |
| Indoor monitor | TCTIS716 | HTTP index of SD-card snapshots/clips (sync), or manual SD-card import |

On the LAN the app needs nothing else. For remote access without any router setup there is an optional
self-hosted **[HomeGuard Bridge](tools/bridge/README.md)**: it reaches the recorder by its cloud serial
through TVT's P2P servers, like SuperLive Plus does, and serves the app over TLS. Otherwise remote access
is VPN or TLS only.

### What is verified and what is not

TVT publishes no developer documentation for these protocols. HomeGuard's TVT support is built from public
reverse-engineering work (pytvt, 2BAD/tvt, both MIT) and TVT's HTTP API guide copies that circulate under
OEM brands. Everything below is covered by tests against fakes; real-hardware status:

| Feature | Status |
|---|---|
| Sign-in with the SuperLive / web account (NVMS-9000 `reqLogin`/`doLogin`) | **Works on the TCR I12** |
| Camera list from the NVR, one-tap "switch on RTSP" | Camera list **works on the TCR I12** (4 channels) |
| Live view over RTSP | **Works on the TCR I12** (H.265). This firmware expects `MD5(password)` in upper-case hex as the Digest password for RTSP and the HTTP API; sign-in detects and remembers that |
| Recordings (HTTP API `SearchByTime`) + playback timeline | Implemented; the RTSP **playback URL form is unconfirmed** on this firmware |
| Door unlock via TVT protocol alarm output (port 9008) | **Experimental guess**: TVT documents no unlock API for the TD-E3110 |
| Remote access by serial (Bridge, P2P 2.0) | Implemented on the vendor Linux SDK; needs an x86_64 Linux host; not yet tried with this NVR |
| P2P directly in the phone app | **Not possible yet**: TVT ships the P2P client only as x86/Windows binaries; the UDP protocol is undocumented |

Settings → **Device diagnostics** produces a shareable report (no passwords, serials masked) of what each
device supports. It is the fastest way to close the remaining gaps for a specific model.

---

## Features

**Authentication & security**
- Login with the NVR's IP and **the same username/password as SuperLive Plus or the NVR web page**. HomeGuard signs in through the recorder's web interface, reads the camera list and, if the RTSP video service is off, offers to switch it on (password protected, never anonymous). Recorders without that interface (other brands, the simulator) are verified with an RTSP `DESCRIBE` against camera 1.
- Remember me (keeps username and host) and an optional **Face ID / fingerprint** unlock.
- Everything is stored in **flutter_secure_storage**: iOS Keychain (`first_unlock_this_device`, no iCloud sync) and the Android Keystore (RSA-OAEP + AES-GCM). There are no SharedPreferences and no plaintext files.
- Brute-force lockout after 5 failed logins (30 s, then doubling up to 15 min).
- Auto-lock after N minutes in background (0 = lock immediately). Without biometrics, locking also deletes the password.
- Door unlock needs a biometric confirmation (biometric-only, no PIN fallback) or a dialog, plus a 1-second **hold-to-unlock** button and a 3 s relay debounce. Every attempt is written to the local audit log.
- Android: `FLAG_SECURE` (feeds stay out of screenshots and the recent-apps thumbnail), backups and device-transfer disabled, system CAs only.
- Logs redact `user:pass@`, `Authorization` headers and credential query parameters.

**LAN priority / remote fallback** (`lib/core/network/connection_manager.dart`)
1. TCP probe of the LAN host (800 ms timeout). If it answers, that route is used.
2. Otherwise the remote route, but only if it is configured:
   - **VPN mode** (WireGuard, Tailscale, IPsec). Plain RTSP/HTTP is allowed, but *only* if the host resolves to a private or tunnel address (RFC 1918, 100.64/10, ULA). A "VPN" host that resolves to a public IP is refused, because otherwise credentials would travel in cleartext.
   - **TLS mode**. Only `rtsps://` and `https://` are used, with normal certificate validation (no "accept all certs" switch).
3. Routes are cached for 30 s. The cache is cleared on any connectivity change (Wi-Fi ↔ cellular, VPN up/down) and when the app resumes.

**Live feeds**
- A responsive grid (2 or 3 columns) shows the 3 cameras and the door station. It uses sub-streams by default to save bandwidth and CPU.
- Fullscreen player: main stream, pinch-zoom, HD/SD toggle and mute.
- Overlay quick actions: **Talk** (two-way intercom), **Snapshot**, **Unlock**.
- The player (libmpv via media_kit) is tuned for low latency: TCP-interleaved RTSP, cache off, `nobuffer`/`low_delay`, short probing.
- Resilience:
  - A stall watchdog reconnects after 8 s without frames.
  - Reconnects use exponential back-off (1 s → 30 s).
  - The stream is released in background, which frees NVR stream slots.
  - Error messages are readable (auth failed, timeout, path not found…).
  - The live player's protocol whitelist is limited to RTSP/RTP/TCP/TLS.

**Two-way audio**
- Uses the standard ONVIF RTSP audio back-channel (`Require: www.onvif.org/ver20/backchannel`).
- Microphone audio (8 kHz PCM16, with echo cancellation and noise suppression) is encoded to G.711 µ-law or A-law. It is then sent as RTP packets (40 ms each) interleaved on the RTSP TCP connection, with keep-alives.
- The microphone is closed whenever the app leaves the foreground.

**Events & snapshots**
- Timeline grouped by day, with filter chips: *Face Detected, Motion, Call Received, Manual Snapshot, Door Unlocked, RFID Access*.
- Detail view: zoomable snapshot (up to 6×), local clip playback (file-only whitelist), timestamp, device and type tags, delete.
- Sources:
  - Snapshots taken in the app.
  - **Sync from the indoor monitor** over HTTP. The index can be a JSON list or an HTML directory listing. Links that point to other hosts are never followed.
  - **Import from the SD card** with the file picker.
- Event type and timestamp are inferred from device file names (e.g. `20260115_083012_FACE.jpg`).
- Data lives in the app sandbox with an atomic index write. A corrupt index does not crash the app. A size cap evicts the oldest events.

**Access control**
- Door-station preview with talk, snapshot and unlock buttons.
- Hold-to-unlock for each configured relay.
- Access log: unlocks, failed unlocks, RFID events and calls.

**Settings & network status**
- Status for each device: route (LAN, VPN, TLS or OFF), address and TCP latency.
- **RTSP probe**: handshake latency, video and audio codecs, whether a back-channel is present, server string.
- ONVIF **WS-Discovery** (UDP multicast) to find the door station and indoor monitor and assign them.
- **Detect via ONVIF**: GetProfiles + GetStreamUri with a WS-Security digest token. It fills in the door station's real RTSP path.
- Device editor (LAN/remote host, ports, channel, RTSP template, relay endpoint, method and body, event index path, credentials for each device).
- Erase-all (credentials, settings, snapshots).

---

## Architecture

```
lib/
  main.dart / app.dart / router.dart   composition, go_router (StatefulShellRoute, 4 tabs), auto-lock
  core/
    app_services.dart                  composition root (Provider + AppServices.instance for FF actions)
    models/                            DeviceConfig (topology), SecurityEvent
    security/                          SecureStore (keystore), BiometricService
    network/                           ConnectionManager (LAN→VPN/TLS), DeviceHttpClient (digest), reachability
    rtsp/                              RtspClient, stream parser, SDP, digest auth  ← pure Dart, unit-tested
    onvif/                             WS-Discovery (UDP), Media service SOAP + WS-Security
    audio/g711.dart                    µ-law / A-law encoders
    services/                          DeviceRegistry, EventStore, DoorRelay, Intercom, MonitorSync, Recordings
    tvt/                               TVT/Techson protocols in pure Dart (Android + iOS):
                                         tvt_web_client    NVMS-9000 web interface (login, cameras, RTSP/API Server)
                                         tvt_lapi_client   TVT HTTP API (recording search, snapshot, NAT/cloud info)
                                         tvt_net_protocol  binary device protocol, ports 6036/9008 (login, HTTP
                                         tvt_net_client    tunnel, alarm outputs) with a pluggable transport
                                         nvr_setup         sign-in flow; tvt_probe: diagnostics
    bridge/                            client for the HomeGuard Bridge HTTPS API
  custom_code/                         FlutterFlow-shaped custom code
    actions/                           triggerDoorUnlock, checkLanReachability, probeRtspStream,
                                       captureSnapshot, toggleIntercom, discoverOnvifDevices
    widgets/rtsp_player_widget.dart    resilient low-latency RTSP player
  features/                            auth, shell, live, playback, events, access, settings (UI + controllers)
tools/
  simulator/                           fake NVR (RTSP + web interface + HTTP API), intercom, TVT protocol, monitor
  bridge/                              HomeGuard Bridge: P2P login by serial on the vendor Linux SDK (Docker)
  theme/                               dark-first security palette
```

State management is Provider with `ChangeNotifier` controllers, the same pattern FlutterFlow's `FFAppState` uses. All network and protocol code sits behind small interfaces: the TCP probe, DNS lookup, credential verifier, file root and secure storage can all be swapped in tests.

See [`docs/FLUTTERFLOW.md`](docs/FLUTTERFLOW.md) for moving the custom widget and actions into a FlutterFlow project.

---

## Build & run

Requires Flutter 3.38+ (developed with 3.47 / Dart 3.13).

```bash
cd homeguard
flutter pub get
flutter analyze
flutter test
flutter run            # device or emulator on the same LAN as the NVR
flutter build apk --release
flutter build ipa      # needs Xcode + signing
```

### Testing on a phone (no Play Store, no real devices needed)

1. **Get the APK.** Every push that changes `homeguard/` builds a new test APK. On your phone, open <https://github.com/Cogur/sts-first-maven/releases>, tap the newest **HomeGuard Test build N**, then tap the `.apk` file under *Assets* and open it. You'll need to allow "Install unknown apps" once. It installs as **HomeGuard Test**, separately from a future Play version.
2. **Simulate the devices.** [`tools/simulator/`](tools/simulator/README.md) runs a fake NVR (3 cameras), door station, relay and indoor monitor on your PC with `docker compose up`. It also has a step-by-step test checklist.

Publishing to Google Play: see [`docs/PLAY_STORE.md`](docs/PLAY_STORE.md). It covers the signing key, the first manual upload, the privacy policy and data-safety answers, and the GitHub Actions workflow that builds and uploads signed bundles.

Platform notes:
- **Android**: minSdk 28. `MainActivity` extends `FlutterFragmentActivity` (needed by `local_auth`).
- **iOS**: the Info.plist includes the Face ID, microphone and local network usage strings. **ONVIF discovery on iOS 14+ needs the `com.apple.developer.networking.multicast` entitlement**, which you request from Apple. Without it, discovery returns nothing; enter the IPs manually.

---

## First-time setup for the Techson devices

1. **Login**: enter the NVR's LAN IP (SuperLive Plus → device → *Network Info*, e.g. `192.168.1.200`) and the account you use in SuperLive Plus.
   - If the NVR's RTSP service is off, the app asks once and switches it on.
   - Cameras appear with the names set on the NVR.
   - The default camera path is TVT's `/chID={channel}&streamType={stream}&linkType=tcp` on port 554. If your firmware uses something else, change it under Settings → Camera N.
   - **Playback** tab: the first search asks to switch on the NVR's *API Server* (needed for recording search).
2. **Door station (TCTDB102)**: Settings → *Discover ONVIF devices*, then assign the device as *Front Door*. Next, open *Front Door* → **Detect via ONVIF** to fill the RTSP path.
   - Run **Probe stream** in Network status. If it reports *back-channel: no*, the unit does not expose ONVIF two-way audio; turn off "Two-way audio".
3. **Door relay**: Settings → *Front Door* → **Unlock via**:
   - *TVT protocol, alarm output (experimental)* for the TCTDB102: LAN IP of the door station, port 9008, output 0. Test once with the door in view.
   - or *HTTP / CGI request* with the endpoint from your door station's documentation, e.g. `/cgi-bin/accessControl.cgi?action=openDoor&channel=1` (Digest/Basic auth).
4. **Indoor monitor (TCTIS716)**: set its LAN IP. If its web server exposes the SD-card snapshot folder, put that path in *SD-card index path* and use **Sync** on the Events tab. Otherwise copy the files from the SD card and use **Import**.
5. **Remote access (optional)**, either:
   - a WireGuard/Tailscale tunnel to your home network, then the NVR's tunnel address with mode **VPN tunnel**; or
   - a [HomeGuard Bridge](tools/bridge/README.md) (P2P by serial, no router setup at home), mode **Bridge**.

   Do not port-forward RTSP to the internet.

---

## Known limitations (please read)

- **Not yet validated against the physical devices.**
  - The protocol code is tested against an in-process fake NVR (digest auth, SDP, back-channel RTP framing). The connection policy, auth flow and event store are unit-tested.
  - Real-hardware testing with the TCR I12 / TCTDB102 / TCTIS716 still needs to happen.
- **Unlock and event endpoints are configurable, not hard-coded.** Techson/TVT do not publish an API for the TCTDB102 and TCTIS716. The TVT-protocol unlock is an educated guess (the SDK's alarm-output command); run *Device diagnostics* if it does not work.
- **TVT protocol support is reverse-engineered.** A firmware update can change it. The app uses the same account and permissions as the NVR web page and never changes settings without asking.
- **The Bridge uses TVT's cloud and the vendor SDK without TVT's permission.** Fine for your own devices; publishing a product built on it needs TVT's written consent.
- **Two-way talk needs ONVIF back-channel support.** If the door station only offers a proprietary or SIP intercom, talk will not work in this version. The probe tells you whether it is supported.
- **No push notifications for doorbell rings.** That would need a persistent SIP/vendor event connection or a cloud relay, and "no cloud" is a deliberate design choice here. Ring events show up after a monitor sync.
- **No local clip recording.** The app takes snapshots; clips come from the monitor or SD card.
- **iOS screenshot blocking is not implemented.** iOS has no `FLAG_SECURE` equivalent.
- **TLS remote mode requires a certificate that the OS trusts.** Self-signed NVR certificates are rejected; use VPN mode instead.
