import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models/device.dart';
import '../../core/network/device_http_client.dart';
import '../../core/rtsp/rtsp_client.dart';
import '../../core/security/secure_store.dart';
import '../../core/tvt/tvt_lapi_client.dart';

enum VideoAccess {
  /// RTSP accepts the account: play video.
  video,

  /// RTSP refuses it but the HTTP API serves pictures.
  pictures,

  /// Both refuse it. Nothing is retried automatically: every refused
  /// attempt raises the recorder's "illegal login" alarm (it beeps).
  refused,
}

/// One shared check per recorder and session, so four camera tiles do not
/// each hammer the recorder with refused logins.
class VideoAccessCheck {
  VideoAccessCheck._();
  static final instance = VideoAccessCheck._();

  final _results = <String, Future<VideoAccess>>{};

  /// Bumped on [reset] so tiles re-check.
  final generation = ValueNotifier<int>(0);

  /// [plain] is the account as typed; [form] the password form remembered
  /// for this device. On a refusal the other forms are tried once each
  /// (some TVT firmware wants MD5 in Digest) and a working one is reported
  /// through [onForm] so it is remembered. [pictures] builds the HTTP API
  /// client for a password form.
  Future<VideoAccess> check({
    required String key,
    required Uri rtspUri,
    required Credentials plain,
    DigestPassword form = DigestPassword.plain,
    bool tryOtherForms = true,
    TvtLapiClient Function(Credentials c)? pictures,
    int channel = 1,
    void Function(DigestPassword form)? onForm,
  }) => _results[key] ??= _run(rtspUri, plain, form, tryOtherForms, pictures, channel, onForm).then((r) {
    // Network trouble is not a verdict: allow the next tile to try again.
    if (r == null) _results.remove(key);
    return r ?? VideoAccess.video;
  });

  Future<VideoAccess?> _run(
    Uri uri,
    Credentials plain,
    DigestPassword stored,
    bool tryOthers,
    TvtLapiClient Function(Credentials c)? pictures,
    int channel,
    void Function(DigestPassword form)? onForm,
  ) async {
    final forms = [stored, if (tryOthers) ...DigestPassword.values.where((f) => f != stored)];
    for (final f in forms) {
      try {
        await RtspClient.probe(
          uri: uri,
          username: plain.username,
          password: f.apply(plain.password),
          backchannel: false,
        );
        if (f != stored) onForm?.call(f);
        return VideoAccess.video;
      } on RtspException catch (e) {
        if (!e.isAuthFailure) return VideoAccess.video; // let the player report it
      } catch (_) {
        return null;
      }
    }
    if (pictures == null) return VideoAccess.refused;
    final c = Credentials(plain.username, stored.apply(plain.password));
    try {
      await pictures(c).snapshot(channel);
      return VideoAccess.pictures;
    } on DeviceHttpException catch (e) {
      return e.statusCode == 401 || e.statusCode == 403 ? VideoAccess.refused : VideoAccess.pictures;
    } catch (_) {
      return VideoAccess.pictures;
    }
  }

  /// Forget all verdicts (user tapped retry, or signed in again).
  void reset() {
    _results.clear();
    generation.value++;
  }
}
