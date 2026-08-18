import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'screens/home_page.dart';
import 'services/app_settings.dart';
import 'services/app_route_observer.dart';
import 'services/generic_site_api.dart';
import 'services/huangguo_api.dart';
import 'services/layout_settings.dart';
import 'services/mitao_api.dart';
import 'services/phub_api.dart';
import 'services/player_chrome.dart';
import 'services/translator.dart';
import 'services/watch_history.dart';
import 'services/xvideos_api.dart';

/// Video player shell (home list + site feeds + search).
class PlayerApp extends StatelessWidget {
  const PlayerApp({
    super.key,
    required this.settings,
    required this.layout,
    required this.history,
  });

  final AppSettings settings;
  final LayoutSettings layout;
  final WatchHistory history;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<LayoutSettings>.value(value: layout),
        ChangeNotifierProvider<WatchHistory>.value(value: history),
        ChangeNotifierProvider(create: (_) => PlayerChrome()),
        Provider(create: (_) => PhubApi()),
        Provider(create: (_) => XvideosApi()),
        Provider(create: (_) => MitaoApi()),
        Provider(create: (_) => HuangGuoApi(settings: settings)),
        Provider(create: (_) => GenericSiteApi()),
        Provider(create: (_) => Translator()),
      ],
      child: MaterialApp(
        title: 'ePickle',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: Colors.black,
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF6B35),
            secondary: Color(0xFFFF6B35),
            surface: Colors.black,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            systemOverlayStyle: SystemUiOverlayStyle(
              statusBarColor: Colors.black,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
            ),
          ),
          iconButtonTheme: IconButtonThemeData(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(Colors.white54),
              overlayColor: WidgetStatePropertyAll(Colors.white12),
              backgroundColor: WidgetStatePropertyAll(Colors.transparent),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              overlayColor: Colors.white12,
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              overlayColor: Colors.white12,
            ),
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white12,
              foregroundColor: Colors.white70,
              overlayColor: Colors.white24,
            ),
          ),
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
              TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            },
          ),
        ),
        home: const HomePage(),
        navigatorObservers: [appRouteObserver],
      ),
    );
  }
}
