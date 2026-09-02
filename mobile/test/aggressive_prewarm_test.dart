import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/app_settings.dart';
import 'package:epickle/services/feed_list_cache.dart';
import 'package:epickle/services/media_prewarm.dart';
import 'package:epickle/models/video_item.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings.aggressivePrewarm', () {
    test('defaults to ON (unset key); an explicit OFF stays off', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettings();
      await s.load();
      expect(s.aggressivePrewarm, isTrue);

      // User explicitly turned it off once — that choice must win forever.
      final off = AppSettings();
      SharedPreferences.setMockInitialValues(
          {'aggressive_prewarm_enabled': false});
      await off.load();
      expect(off.aggressivePrewarm, isFalse);
    });

    test('persists across a reload', () async {
      SharedPreferences.setMockInitialValues({});
      final s = AppSettings();
      await s.load();
      await s.setAggressivePrewarm(false);
      expect(s.aggressivePrewarm, isFalse);

      final fresh = AppSettings();
      await fresh.load();
      expect(fresh.aggressivePrewarm, isFalse);

      await fresh.setAggressivePrewarm(true);
      final again = AppSettings();
      await again.load();
      expect(again.aggressivePrewarm, isTrue);
    });
  });

  group('FeedListSnapshot.sourcePage', () {
    test('defaults to null and survives capped()', () {
      final items = const [
        VideoItem(url: 'https://x.test/a', title: 'A'),
        VideoItem(url: 'https://x.test/b', title: 'B'),
      ];
      final plain = FeedListSnapshot(
        items: items,
        seen: {'a', 'b'},
        index: 0,
      );
      expect(plain.sourcePage, isNull);
      expect(plain.capped(60).sourcePage, isNull);

      final staged = FeedListSnapshot(
        items: items,
        seen: {'a', 'b'},
        index: 0,
        sourcePage: 7,
      );
      // capped() must carry the staged page so the randomized feed can
      // continue at sourcePage + 1 after consuming the snapshot.
      expect(staged.capped(60).sourcePage, 7);
      expect(staged.capped(1).sourcePage, 7);
    });
  });

  group('MediaPrewarm', () {
    test('is off by default and take() on an empty pool is null', () {
      final prewarm = MediaPrewarm.instance;
      expect(prewarm.enabled, isFalse);
      expect(prewarm.take('https://x.test/a', 'https://cdn.test/a.m3u8'),
          isNull);
    });

    test('setEnabled(false) stays a safe no-op', () {
      MediaPrewarm.instance.setEnabled(false);
      expect(MediaPrewarm.instance.enabled, isFalse);
      MediaPrewarm.instance.setEnabled(false);
      expect(MediaPrewarm.instance.enabled, isFalse);
    });
  });
}
