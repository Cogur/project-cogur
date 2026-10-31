import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../audio/g711.dart';
import '../models/device.dart';
import '../network/connection_manager.dart';
import '../rtsp/rtsp_client.dart';
import '../utils/log.dart';
import 'device_registry.dart';

enum TalkState { idle, connecting, talking, error }

/// Push-to-talk / toggle intercom over the ONVIF RTSP audio back-channel.
///
/// Microphone PCM (8 kHz mono, 16-bit) → G.711 → RTP → interleaved on the
/// RTSP TCP connection. Incoming audio is heard through the live player.
class IntercomService extends ChangeNotifier {
  IntercomService(this._registry, this._connections, {AudioRecorder Function()? recorder})
    : _recorderFactory = recorder ?? AudioRecorder.new;

  final DeviceRegistry _registry;
  final ConnectionManager _connections;
  final AudioRecorder Function() _recorderFactory;

  TalkState _state = TalkState.idle;
  String? _error;
  String? _deviceId;
  RtspClient? _client;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _mic;

  TalkState get state => _state;
  String? get error => _error;
  String? get activeDevice => _deviceId;

  Future<void> start(String deviceId) async {
    if (_state == TalkState.connecting || _state == TalkState.talking) await stop();
    final device = _registry.byId(deviceId);
    if (device == null) return;
    _set(TalkState.connecting, deviceId: deviceId);

    try {
      final recorder = _recorderFactory();
      _recorder = recorder;
      if (!await recorder.hasPermission()) {
        throw RtspException('Microphone permission denied');
      }
      final route = await _connections.require(deviceId);
      final client = RtspClient(
        uri: route.rtspUri(route.streamPath(device, StreamQuality.main)),
        username: _registry.mediaCredentialsFor(deviceId)?.username ?? '',
        password: _registry.mediaCredentialsFor(deviceId)?.password ?? '',
      );
      _client = client;
      await client.connect();
      final pt = await client.startBackchannel();
      final pcm = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 8000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
      _mic = pcm.listen(
        (chunk) => client.sendAudio(G711.encodePcm16(chunk, alaw: pt == 8)),
        onError: (Object e) => _fail('Microphone error: $e'),
      );
      _set(TalkState.talking, deviceId: deviceId);
    } on RtspException catch (e) {
      await _fail(e.message);
    } on DeviceUnreachableException catch (e) {
      await _fail(e.toString());
    } catch (e) {
      await _fail('Talk failed: $e');
    }
  }

  Future<void> stop() async {
    await _mic?.cancel();
    _mic = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    await _recorder?.dispose();
    _recorder = null;
    await _client?.close();
    _client = null;
    _set(TalkState.idle);
  }

  Future<void> _fail(String message) async {
    Log.w('talk', message);
    await stop();
    _error = message;
    _state = TalkState.error;
    notifyListeners();
  }

  void _set(TalkState s, {String? deviceId}) {
    _state = s;
    _deviceId = deviceId;
    if (s != TalkState.error) _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
