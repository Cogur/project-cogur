import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/models/security_event.dart';
import 'features/access/access_control_page.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/login_page.dart';
import 'features/events/event_detail_page.dart';
import 'features/events/events_page.dart';
import 'features/live/fullscreen_player_page.dart';
import 'features/live/live_grid_page.dart';
import 'features/playback/playback_page.dart';
import 'features/settings/device_edit_page.dart';
import 'features/settings/diagnostics_page.dart';
import 'features/settings/logs_page.dart';
import 'features/settings/settings_page.dart';
import 'features/shell/home_shell.dart';

GoRouter buildRouter(AuthController auth) {
  return GoRouter(
    initialLocation: '/live',
    refreshListenable: auth,
    redirect: (context, state) {
      final atLogin = state.matchedLocation == '/login';
      switch (auth.status) {
        case AuthStatus.initializing:
          return state.matchedLocation == '/splash' ? null : '/splash';
        case AuthStatus.signedOut || AuthStatus.locked:
          return atLogin ? null : '/login';
        case AuthStatus.authenticated:
          return atLogin || state.matchedLocation == '/splash' ? '/live' : null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const _Splash()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => HomeShell(shell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/live',
                builder: (_, _) => const LiveGridPage(),
                routes: [
                  GoRoute(
                    path: ':deviceId',
                    parentNavigatorKey: _rootKey,
                    builder: (_, s) => FullscreenPlayerPage(deviceId: s.pathParameters['deviceId']!),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/playback', builder: (_, _) => const PlaybackPage())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/events',
                builder: (_, _) => const EventsPage(),
                routes: [
                  GoRoute(
                    path: 'detail',
                    parentNavigatorKey: _rootKey,
                    builder: (_, s) => EventDetailPage(event: s.extra! as SecurityEvent),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [GoRoute(path: '/access', builder: (_, _) => const AccessControlPage())],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsPage(),
                routes: [
                  GoRoute(path: 'logs', parentNavigatorKey: _rootKey, builder: (_, _) => const LogsPage()),
                  GoRoute(
                    path: 'diagnostics',
                    parentNavigatorKey: _rootKey,
                    builder: (_, _) => const DiagnosticsPage(),
                  ),
                  GoRoute(
                    path: 'device/:deviceId',
                    parentNavigatorKey: _rootKey,
                    builder: (_, s) => DeviceEditPage(deviceId: s.pathParameters['deviceId']!),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
    navigatorKey: _rootKey,
  );
}

final _rootKey = GlobalKey<NavigatorState>();

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Icon(Icons.shield_outlined, size: 64)));
}
