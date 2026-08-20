import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:epickle/screens/site_feed_page.dart';
import 'package:epickle/services/app_settings.dart';
import 'package:epickle/services/mirror_ranker.dart';
import 'package:epickle/services/player_chrome.dart';
import 'package:epickle/services/source_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('long-press first tab opens the mirror picker sheet',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    MirrorRanker.instance.reset();
    await MirrorRanker.instance.load();

    final site = SourceCatalog.xvideos;
    // flutter_test blocks real HTTP (returns 400), so the feed inside shows
    // its error state — irrelevant for the bottom-bar gesture under test.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: PlayerChrome()),
          ChangeNotifierProvider.value(value: AppSettings()),
        ],
        child: MaterialApp(
          home: SiteFeedPage(site: site),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // NavigationBar wraps every destination in a Tooltip whose long-press
    // recognizer used to win the gesture arena; with tooltip: '' the long
    // press must reach our GestureDetector.
    await tester.longPress(find.byType(NavigationDestination).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('自动优选（最快镜像）'), findsOneWidget,
        reason: 'long-pressing the first tab must open the mirror picker');
    expect(find.text('切换为本站访问域名'), findsOneWidget);

    // Every mirror of this site is offered in the sheet.
    for (final base in site.mirrors) {
      final host = Uri.tryParse(base)?.host ?? base;
      expect(find.text(host), findsWidgets,
          reason: 'mirror $host must be listed in the picker');
    }
  });
}