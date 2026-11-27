import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/utils/http_headers.dart';
import 'package:epickle/utils/playback_helpers.dart';

void main() {
  test('page headers look like iOS Safari navigation', () {
    final headers = AppHttpHeaders.forSite('https://fixture.test/watch/42');

    expect(AppHttpHeaders.userAgent, contains('iPhone'));
    expect(AppHttpHeaders.browser, isNot(contains('Origin')));
    expect(headers, isNot(contains('Origin')));
    expect(headers['Referer'], 'https://fixture.test/');
  });

  test('media headers retain the exact detail page as referer', () {
    final headers = AppHttpHeaders.forMediaUrl(
      'https://cdn.fixture.test/video/master.m3u8',
      pageUrl: 'https://fixture.test/watch/42?token=abc',
    );

    expect(headers['Referer'], 'https://fixture.test/watch/42?token=abc');
    expect(headers['Origin'], 'https://fixture.test');
  });

  test('desktop-UA hosts switch UA for page fetches only by host', () {
    // 85ro / 91md：移动 UA 会拿到异步/精简模板（2026-11-28 实测），页面
    // 抓取必须用桌面 UA；其它站保持 iOS Safari UA。
    expect(
      AppHttpHeaders.wantsDesktopUa('https://www.85ro.com/top-rated/1/'),
      isTrue,
    );
    expect(
      AppHttpHeaders.wantsDesktopUa('https://85ro.com/v/10383.html'),
      isTrue,
    );
    expect(
      AppHttpHeaders.wantsDesktopUa(
        'https://91md.me/index.php/vod/type/id/25/page/1.html',
      ),
      isTrue,
    );
    expect(
      AppHttpHeaders.wantsDesktopUa('https://www.9191md.me/index.php'),
      isTrue,
    );
    expect(
      AppHttpHeaders.wantsDesktopUa('https://www.qinav.com/new.html'),
      isFalse,
    );
    expect(
      AppHttpHeaders.wantsDesktopUa('https://not85ro.com.example.test/'),
      isFalse,
    );
    expect(AppHttpHeaders.wantsDesktopUa(null), isFalse);

    final pageHeaders =
        AppHttpHeaders.forSite('https://www.85ro.com/top-rated/1/');
    expect(pageHeaders['User-Agent'], AppHttpHeaders.desktopUserAgent);
    expect(pageHeaders['User-Agent'], isNot(AppHttpHeaders.userAgent));

    final normalHeaders = AppHttpHeaders.forSite('https://www.qinav.com/');
    expect(normalHeaders['User-Agent'], AppHttpHeaders.userAgent);

    final mirrorHeaders = AppHttpHeaders.browserFor('https://91md.me/');
    expect(mirrorHeaders['User-Agent'], AppHttpHeaders.desktopUserAgent);
  });

  test('all platforms use two preload decoder slots', () {
    expect(PlaybackHelpers.preloadSlotCount, 2);
  });
}
