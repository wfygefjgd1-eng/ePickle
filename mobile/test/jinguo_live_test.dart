import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/jinguo_api.dart';

/// Opt-in live probe for the 禁果短剧 adapter. Run manually when the site
/// changes:
///
///   PowerShell:  $env:LIVE_JINGUO_TEST='1'; flutter test test/jinguo_live_test.dart
///   bash:        LIVE_JINGUO_TEST=1 flutter test test/jinguo_live_test.dart
void main() {
  final enabled = Platform.environment['LIVE_JINGUO_TEST'] == '1';

  test(
    'jinguo live feed, search, detail and playback',
    () async {
      final api = JinGuoApi();

      // 1. Home / channels.
      final home = await api.fetchFeed(tagId: 'hot');
      expect(home, isNotEmpty, reason: 'home feed is empty');
      // ignore: avoid_print
      print('home OK: ${home.length} cards, first=${home.first.title}');
      expect(home.where((e) => e.thumb != null).length, greaterThan(0));

      final shortPage1 = await api.fetchFeed(tagId: 'short', page: 1);
      final shortPage2 = await api.fetchFeed(tagId: 'short', page: 2);
      expect(shortPage1, isNotEmpty);
      expect(shortPage2, isNotEmpty);
      final p1 = shortPage1.map((e) => e.url).toSet();
      final repeated = shortPage2.where((e) => p1.contains(e.url)).length;
      expect(
        repeated < shortPage2.length,
        isTrue,
        reason: 'page 2 is identical to page 1 ($repeated repeats)',
      );
      // ignore: avoid_print
      print('short OK: p1=${shortPage1.length} p2=${shortPage2.length} '
          'repeated=$repeated');

      for (final tag in const ['series', 'rank']) {
        final list = await api.fetchFeed(tagId: tag);
        expect(list, isNotEmpty, reason: '$tag feed is empty');
        // ignore: avoid_print
        print('$tag OK: ${list.length} cards');
      }

      // 2. Chinese search.
      final search = await api.search('同学');
      expect(search, isNotEmpty, reason: 'search returned nothing');
      expect(
        search.any((e) => e.url.contains('/detail/txdly')),
        isTrue,
        reason: 'search did not find txdly',
      );
      // ignore: avoid_print
      print('search OK: ${search.length} cards');

      // 3. Free series detail + first episode stream.
      final detail =
          await api.getVideoDetail('https://jinguodj.tv/detail/txdly');
      expect(detail.title, contains('同学'));
      expect(detail.streams, isNotEmpty, reason: 'free episode has no stream');
      expect(detail.thumb, isNotNull);
      expect(detail.durationSec, greaterThan(0));
      final episodes = api.episodesFor(detail.url);
      expect(episodes, isNotNull);
      expect(episodes!.length, greaterThan(1));
      // ignore: avoid_print
      print('detail OK: ${detail.title}, ${episodes.length} episodes, '
          'stream=${detail.streams.first.url}');

      await _probeHls(detail.streams.first.url, detail.streams.first.referer);

      // 4. Paid-only series → WebView fallback, not a hard failure.
      final paid =
          await api.getVideoDetail('https://jinguodj.tv/detail/gcxny');
      expect(paid.streams, isEmpty, reason: 'paid episode leaked a stream');
      expect(paid.browserPlaybackUrl, isNotNull);
      expect(paid.browserPlaybackUrl, isNotEmpty);
      // ignore: avoid_print
      print('paid OK: fallback=${paid.browserPlaybackUrl}');

      // 5. Direct episode URL skips the detail page (cache-backed).
      final episodeDetail = await api.getVideoDetail(episodes.first.url);
      // ignore: avoid_print
      print('episode reply: url=${episodeDetail.url} '
          'streams=${episodeDetail.streams.length} '
          'fallback=${episodeDetail.browserPlaybackUrl}');
      expect(episodeDetail.streams, isNotEmpty);
      // ignore: avoid_print
      print('episode OK: ${episodes.first.url}');
    },
    skip: enabled ? false : 'set LIVE_JINGUO_TEST=1 to probe jinguodj.tv',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> _probeHls(String url, String? referer) async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        if (referer != null) 'Referer': referer,
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
      },
      validateStatus: (_) => true,
    ),
  );
  final response = await dio.get<String>(url);
  expect(response.statusCode, 200);
  final body = response.data ?? '';
  expect(body, contains('#EXTM3U'));
  // Follow the master playlist to the first variant when one is present.
  final variant = body
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .firstWhere(
        (line) => line.isNotEmpty && !line.startsWith('#'),
        orElse: () => '',
      );
  if (variant.isEmpty || body.contains('#EXTINF')) return;
  final variantUrl = Uri.parse(url).resolve(variant).toString();
  final variantResponse = await dio.get<String>(variantUrl);
  expect(variantResponse.statusCode, 200);
  expect(variantResponse.data, contains('#EXTM3U'));
}
