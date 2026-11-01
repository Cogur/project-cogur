import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/security/secure_store.dart';

/// User preferences (non-secret, but stored alongside secrets in the
/// keystore so the app has a single, encrypted persistence layer).
class SettingsController extends ChangeNotifier {
  SettingsController(this._store);

  final SecureStore _store;

  int _autoLockMinutes = 5;
  bool _confirmUnlockWithBiometrics = true;
  bool _preferHd = false;
  bool _muteGridAudio = true;
  bool _allowScreenshots = false;

  static const _window = MethodChannel('homeguard/window');

  /// Minutes in background before the app re-locks. 0 = lock immediately.
  int get autoLockMinutes => _autoLockMinutes;
  bool get confirmUnlockWithBiometrics => _confirmUnlockWithBiometrics;

  /// Off (default): SD sub-stream everywhere: starts faster, fewer stalls.
  /// On: HD main stream. Fullscreen can still switch per view.
  bool get preferHd => _preferHd;
  bool get muteGridAudio => _muteGridAudio;

  /// Off by default: camera pictures stay out of screenshots, recordings and
  /// the recent-apps preview (Android FLAG_SECURE).
  bool get allowScreenshots => _allowScreenshots;

  Future<void> _applyWindow() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _window.invokeMethod<void>('setSecure', !_allowScreenshots);
    } on MissingPluginException {
      // Tests / other platforms.
    } on PlatformException {
      // Older app shell without the channel.
    }
  }

  Future<void> load() async {
    final s = await _store.readSettings();
    _autoLockMinutes = s['autoLockMinutes'] as int? ?? 5;
    _confirmUnlockWithBiometrics = s['confirmUnlock'] as bool? ?? true;
    _preferHd = s['hd'] as bool? ?? false;
    _muteGridAudio = s['muteGrid'] as bool? ?? true;
    _allowScreenshots = s['screenshots'] as bool? ?? false;
    notifyListeners();
    await _applyWindow();
  }

  Future<void> update({
    int? autoLockMinutes,
    bool? confirmUnlockWithBiometrics,
    bool? preferHd,
    bool? muteGridAudio,
    bool? allowScreenshots,
  }) async {
    _autoLockMinutes = autoLockMinutes ?? _autoLockMinutes;
    _confirmUnlockWithBiometrics = confirmUnlockWithBiometrics ?? _confirmUnlockWithBiometrics;
    _preferHd = preferHd ?? _preferHd;
    _muteGridAudio = muteGridAudio ?? _muteGridAudio;
    final windowChanged = allowScreenshots != null && allowScreenshots != _allowScreenshots;
    _allowScreenshots = allowScreenshots ?? _allowScreenshots;
    notifyListeners();
    if (windowChanged) await _applyWindow();
    await _store.writeSettings({
      'autoLockMinutes': _autoLockMinutes,
      'confirmUnlock': _confirmUnlockWithBiometrics,
      'hd': _preferHd,
      'muteGrid': _muteGridAudio,
      'screenshots': _allowScreenshots,
    });
  }
}
