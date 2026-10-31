import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'core/app_services.dart';
import 'features/auth/auth_controller.dart';
import 'features/settings/settings_controller.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class HomeGuardApp extends StatefulWidget {
  const HomeGuardApp({super.key, required this.services, required this.auth, required this.settings});

  final AppServices services;
  final AuthController auth;
  final SettingsController settings;

  @override
  State<HomeGuardApp> createState() => _HomeGuardAppState();
}

class _HomeGuardAppState extends State<HomeGuardApp> with WidgetsBindingObserver {
  late final GoRouter _router = buildRouter(widget.auth);
  DateTime? _backgroundedAt;
  Timer? _lockTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final minutes = widget.settings.autoLockMinutes;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      _lockTimer?.cancel();
      _lockTimer = Timer(Duration(minutes: minutes), widget.auth.lock);
      widget.services.intercom.stop(); // never leave the mic open in background
    } else if (state == AppLifecycleState.resumed) {
      _lockTimer?.cancel();
      final since = _backgroundedAt;
      _backgroundedAt = null;
      // Timers may not fire while suspended; enforce on resume too.
      if (since != null && DateTime.now().difference(since) >= Duration(minutes: minutes)) {
        widget.auth.lock();
      }
      widget.services.connections.invalidate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    return MultiProvider(
      providers: [
        Provider.value(value: s),
        ChangeNotifierProvider.value(value: widget.auth),
        ChangeNotifierProvider.value(value: widget.settings),
        ChangeNotifierProvider.value(value: s.registry),
        ChangeNotifierProvider.value(value: s.connections),
        ChangeNotifierProvider.value(value: s.events),
        ChangeNotifierProvider.value(value: s.intercom),
      ],
      child: MaterialApp.router(
        title: 'HomeGuard',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,
        routerConfig: _router,
        // Android 15 draws apps edge-to-edge: keep content clear of the
        // on-screen navigation buttons (Samsung) and side cut-outs. The top
        // is handled by each AppBar.
        builder: (context, child) => SafeArea(top: false, child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
