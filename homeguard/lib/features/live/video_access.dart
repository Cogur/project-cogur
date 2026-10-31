import 'dart:async';

import 'package:flutter/foundation.dart';

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

  Future<VideoAccess> check({
    required String key,
    required Uri rtspUri,
    required Credentials credentials,
    TvtLapiClient? pictures,
    int channel = 1,
  }) => _results[key] ??= _run(rtspUri, credentials, pictures, channel).then((r) {
    // Network trouble is not a verdict: allow the next tile to try again.
    if (r == null) _results.remove(key);
    return r ?? VideoAccess.video;
  });

  Future<VideoAccess?> _run(Uri uri, Credentials c, TvtLapiClient? pictures, int channel) async {
    try {
      await RtspClient.probe(uri: uri, username: c.username, password: c.password, backchannel: false);
      return VideoAccess.video;
    } on RtspException catch (e) {
      if (!e.isAuthFailure) return VideoAccess.video; // let the player report it
    } catch (_) {
      return null;
    }
    if (pictures == null) return VideoAccess.refused;
    try {
      await pictures.snapshot(channel);
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
