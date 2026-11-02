import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/app_services.dart';
import 'core/utils/log.dart';
import 'features/auth/auth_controller.dart';
import 'features/settings/settings_controller.dart';

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    MediaKit.ensureInitialized();
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);

    FlutterError.onError = (details) {
      Log.e('flutter', details.exceptionAsString());
      FlutterError.presentError(details);
    };

    final services = AppServices.instance = AppServices();
    final settings = SettingsController(services.store);
    final auth = AuthController(
      store: services.store,
      biometrics: services.biometrics,
      registry: services.registry,
      connections: services.connections,
    );

    // Settings first: tiles built with the default (SD) and then switched
    // to the saved HD choice reopened every camera once at start.
    await settings.load();
    runApp(HomeGuardApp(services: services, auth: auth, settings: settings));

    await services.events.load();
    await auth.init();
  }, (error, stack) => Log.e('zone', '$error'));
}
