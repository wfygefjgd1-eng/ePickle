import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/generic_site_api.dart';
import 'package:epickle/services/source_catalog.dart';

void main() {
  const site = SiteDef(
    id: 'fixture',
    name: 'Fixture',
    kind: SiteKind.video,
    tags: [],
    color: 0,
    letter: 'F',
    mirrors: ['https://fixture.test'],
  );

  test('resolves relative streams and reversed meta attributes', () async {
    const pageUrl = 'https://fixture.test/videos/42/index.html';
    final dio = Dio();
    final adapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <meta content="Fixture &amp; title" property="og:title">
          <meta content="../../images/cover.jpg" property="og:image">
          <script>window.player = {"file":"../../media/master.m3u8?token=1"};</script>
        '''),
      ),
    });
    dio.httpClientAdapter = adapter;

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(detail.title, 'Fixture & title');
    expect(detail.thumb, 'https://fixture.test/images/cover.jpg');
    expect(
      detail.streams.map((stream) => stream.url),
      contains('https://fixture.test/media/master.m3u8?token=1'),
    );
  });

  test('follows iframe paths relative to each document and carries cookies',
      () async {
    const pageUrl = 'https://fixture.test/watch/42/index.html';
    const embedUrl = 'https://fixture.test/players/42/index.html';
    final adapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('<iframe src="../../../players/42/index.html"></iframe>'),
        headers: const {
          'set-cookie': ['session=abc123; Path=/; HttpOnly'],
        },
      ),
      embedUrl: _FixtureResponse(
        _html('<video><source src="../media/full.mp4"></video>'),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(
      detail.streams.map((stream) => stream.url),
      contains('https://fixture.test/players/media/full.mp4'),
    );
    final embedRequest = adapter.requests.singleWhere(
      (request) => request.uri.toString() == embedUrl,
    );
    expect(embedRequest.headers['Cookie'], contains('session=abc123'));
    expect(embedRequest.headers['Referer'], pageUrl);
  });

  test('decodes MacCMS base64 player URLs', () async {
    const pageUrl = 'https://fixture.test/vod/play/99/index.html';
    const mediaUrl = 'https://cdn.fixture.test/full/master.m3u8';
    final encoded = base64Encode(utf8.encode(mediaUrl));
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>
            var player_aaaa = {"url":"$encoded","encrypt":2};
          </script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(detail.streams.map((stream) => stream.url), contains(mediaUrl));
  });

  test('decodes escaped HLS URLs and ignores image src fields', () async {
    const pageUrl = 'https://fixture.test/watch/escaped';
    const mediaUrl =
        'https://cdn.fixture.test/live/master.m3u8?token=a&expires=2';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html(r'''
          <script>
            window.config = {
              "src":"https://fixture.test/poster.jpg?cache=1",
              "hlsUrl":"https:\/\/cdn.fixture.test\/live\/master.m3u8?token=a\u0026expires=2"
            };
          </script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(detail.streams.map((stream) => stream.url), contains(mediaUrl));
    expect(
      detail.streams.map((stream) => stream.url),
      everyElement(isNot(contains('poster.jpg'))),
    );
  });

  test('reads reversed og:video attributes and lazy source attributes',
      () async {
    const pageUrl = 'https://fixture.test/watch/meta/index.html';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <meta content="../../media/master.m3u8?x=1&amp;y=2"
                property="og:video">
          <video><source data-src="../../media/fallback.mp4"></video>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(
      detail.streams.map((stream) => stream.url),
      contains('https://fixture.test/media/master.m3u8?x=1&y=2'),
    );
    expect(
      detail.streams.map((stream) => stream.url),
      contains('https://fixture.test/media/fallback.mp4'),
    );
  });

  test('normalizes KVS function URLs and rejects MP4 thumbnail URLs', () async {
    const pageUrl = 'https://fixture.test/embed/32176';
    const mediaUrl =
        'https://fixture.test/get_file/7/abc/32176.mp4/?embed=true';
    // KVS extraction is dispatched per-site (javmix/javgg family) and only
    // preferred on the main page when a fresh contentUrl marker exists.
    const kvsSite = SiteDef(
      id: 'javmix',
      name: 'JAVMix fixture',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'J',
      mirrors: ['https://fixture.test'],
    );
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>
            const player = {"contentUrl": "https://fixture.test/get_file/marker/32176.mp4/?embed=true"};
            video_alt_url1: 'function/0/https://img.test/32176.mp4.jpg',
            video_url: 'function/0/$mediaUrl'
          </script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(
      kvsSite,
      pageUrl,
    );
    final urls = detail.streams.map((stream) => stream.url);

    expect(urls, contains(mediaUrl));
    expect(urls, everyElement(isNot(endsWith('.mp4.jpg'))));
  });

  test('prefers playable KVS JSON-LD contentUrl over a stale player URL',
      () async {
    const pageUrl = 'https://fixture.test/video/42/example/';
    const contentUrl = 'https://fixture.test/get_file/good/42/42_720p.mp4/';
    const staleUrl = 'https://fixture.test/get_file/stale/42/42.mp4/';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script type="application/ld+json">
            {"contentUrl":"$contentUrl"}
          </script>
          <script>
            const player = {video_url: '$staleUrl'};
          </script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(
      const SiteDef(
        id: 'javmix',
        name: 'JAVMix fixture',
        kind: SiteKind.video,
        tags: [],
        color: 0,
        letter: 'J',
        mirrors: ['https://fixture.test'],
      ),
      pageUrl,
    );

    expect(detail.streams.first.url, contentUrl);
    expect(detail.streams.first.height, 720);
  });

  test('prefers KVS embed media and carries its referrer and session cookie',
      () async {
    const pageUrl = 'https://fixture.test/video/32176/example/';
    const embedUrl = 'https://fixture.test/embed/32176';
    const mediaUrl =
        'https://fixture.test/get_file/3/hash/32176.mp4/?embed=true';
    const javSite = SiteDef(
      id: 'javmix',
      name: 'JAVMix fixture',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'J',
      mirrors: ['https://fixture.test'],
    );
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>video_url: "https://fixture.test/get_file/3/hash/32176.mp4/"</script>
          <iframe src="$embedUrl"></iframe>
        '''),
        headers: const {
          'set-cookie': ['PHPSESSID=session123; Path=/'],
        },
      ),
      embedUrl: _FixtureResponse(
        _html('''
          <script>video_url: "function/0/$mediaUrl"</script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(
      javSite,
      pageUrl,
    );
    final stream = detail.streams.first;

    expect(stream.url, mediaUrl);
    expect(stream.referer, embedUrl);
    expect(stream.headers['Cookie'], contains('PHPSESSID=session123'));
  });

  test('decrypts DES player data into the full HLS URL', () async {
    const pageUrl = 'https://fixture.test/vod/play/42.html';
    const mediaUrl = 'https://cdn2.shayubf.com/20200222/Tlr76hci/index.m3u8';
    const encrypted =
        'xkoiCz64PL0ivzt27wOsj5aJ5r8Xvt9P5cmuIFXPJizNxnJ2pA3oiyZrIiY2yTE5gtx7f539bcJrKNJfiHy2hslOy1hD2E+k';
    // DES extraction is dispatched per-site (our55/xqq88 family).
    const desSite = SiteDef(
      id: 'our55',
      name: 'Our55 fixture',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'O',
      mirrors: ['https://fixture.test'],
    );
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>
            window.config = {
              video: {
                id: '56b0f1d57700712f2e77ea43f4624ad6',
                data: ['$encrypted']
              }
            };
          </script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(
      desSite,
      pageUrl,
    );

    expect(detail.streams.map((stream) => stream.url), contains(mediaUrl));
  });

  test('decrypts DES payloads containing JSON-escaped base64 slashes',
      () async {
    const pageUrl = 'https://fixture.test/video/current.html';
    const encrypted =
        r'2JRsK7P1DMg82YkW7R2L3VoMnVluQ\/MlmuoQ9vWrAqaR6WPNHxIA5de9GRjKvoERxZMhZ9hXSW8VOqWtUV\/55qkagjY8Klnt';
    const desSite = SiteDef(
      id: 'our55',
      name: 'Our55 fixture',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'O',
      mirrors: ['https://fixture.test'],
    );
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>
            const config = {
              video: {
                id: '0dc2f831bc834dd6a67240a64cffbf6c',
                data: ["$encrypted"]
              }
            };
          </script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(
      desSite,
      pageUrl,
    );

    expect(detail.streams, isNotEmpty);
    expect(detail.streams.first.url, contains('.m3u8'));
  });

  test('filters Eporner unavailable clip and parses minute duration', () async {
    const pageUrl = 'https://fixture.test/watch/eporner';
    const mediaUrl = 'https://cdn.fixture.test/full.mp4';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <span class="vid-length">17min</span>
          <video>
            <source src="https://static.eporner.com/na.mp4">
            <source src="$mediaUrl">
          </video>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);
    final urls = detail.streams.map((stream) => stream.url);

    expect(detail.durationSec, 1020);
    expect(urls, contains(mediaUrl));
    expect(urls, everyElement(isNot(contains('static.eporner.com/na.mp4'))));
  });

  test('parses ISO 8601 video duration metadata', () async {
    const pageUrl = 'https://fixture.test/watch/long';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <meta itemprop="duration" content="P0DT2H15M0S">
          <video src="https://cdn.fixture.test/full.mp4"></video>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(detail.durationSec, 8100);
  });

  test('never promotes Stripchat preview HLS to AVPlayer', () async {
    const pageUrl = 'https://fixture.test/model_name';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>window.initialState = {"streamName":"live_model_42"};</script>
        '''),
      ),
    });

    await expectLater(
      GenericSiteApi(
        dio: dio,
      ).getVideoDetail(SourceCatalog.stripchat, pageUrl),
      throwsA(predicate((error) => error.toString().contains('WebRTC'))),
    );
  });

  test('races mirrors and records distinct mirror health', () async {
    const failedBase = 'https://failed.fixture.test';
    const workingBase = 'https://working.fixture.test';
    const mirrorSite = SiteDef(
      id: 'mirror_fixture',
      name: 'Mirror Fixture',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'M',
      mirrors: [failedBase, workingBase],
    );
    final dio = Dio();
    final adapter = _FixtureAdapter({
      '$failedBase/videos?page=1&sort=hot':
          const _FixtureResponse('forbidden', statusCode: 403),
      '$workingBase/videos?page=1&sort=hot': _FixtureResponse(
        _html('''
          <a href="/video/fixture-42" title="Working mirror video">
            <img src="/cover.jpg">
          </a>
        '''),
      ),
    });
    dio.httpClientAdapter = adapter;
    final api = GenericSiteApi(dio: dio);

    final feed = await api.fetchFeed(mirrorSite, limit: 1);
    final health = api.mirrorHealthFor(mirrorSite.id);

    expect(feed, hasLength(1));
    expect(feed.single.url, '$workingBase/video/fixture-42');
    expect(
      health.singleWhere((entry) => entry.url == failedBase).failure,
      MirrorFailureKind.forbidden,
    );
    expect(
      health.singleWhere((entry) => entry.url == workingBase).isAvailable,
      isTrue,
    );

    // The working mirror is now the ranked favorite (measured healthy).
    // Make it fail: the favorite is tried FIRST, serially, as the deliberate
    // fast path; only when it fails do the remaining mirrors engage in
    // parallel — here the recovered failedBase wins that race.
    adapter.fixtures['$workingBase/videos?page=1&sort=hot'] =
        const _FixtureResponse(
      'stale preferred mirror',
      statusCode: 403,
      delay: Duration(milliseconds: 350),
    );
    adapter.fixtures['$failedBase/videos?page=1&sort=hot'] = _FixtureResponse(
      _html('''
        <a href="/video/recovered-43" title="Recovered mirror video">
          <img src="/cover-43.jpg">
        </a>
      '''),
    );
    final watch = Stopwatch()..start();

    final recovered = await api.fetchFeed(mirrorSite, limit: 1);

    expect(recovered.single.url, '$failedBase/video/recovered-43');
    // The best-known mirror got its full (350ms) try before the fallback
    // engaged — the serial fast path never skips the fastest domain, and the
    // failover still completes with the alternative mirror.
    expect(
      watch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 300)),
    );
  });

  test('JAVMix tabs use four distinct real category paths', () async {
    const base = 'https://javmix.fixture.test';
    const site = SiteDef(
      id: 'javmix',
      name: 'JAVMix fixture',
      kind: SiteKind.video,
      tags: SourceCatalog.vodTags,
      color: 0,
      letter: 'J',
      mirrors: [base],
    );
    const paths = <String, String>{
      'hot': '/most-popular/',
      'new': '/latest-updates/',
      'asian': '/categories/asian/',
      'best': '/top-rated/',
    };
    final fixtures = <String, _FixtureResponse>{};
    for (final entry in paths.entries) {
      fixtures['$base${entry.value}'] = _FixtureResponse(
        _html(
          '<div class="video-card"><a href="$base/video/${entry.key}-101/" '
          'title="${entry.key} category video">${entry.key} category video</a>'
          '<img src="$base/thumb/${entry.key}.jpg"></div>',
        ),
      );
    }
    final dio = Dio();
    final adapter = _FixtureAdapter(fixtures);
    dio.httpClientAdapter = adapter;
    final api = GenericSiteApi(dio: dio);

    for (final tag in paths.keys) {
      final feed = await api.fetchFeed(site, tagId: tag, limit: 1);
      expect(feed.single.url, '$base/video/$tag-101/');
    }
    expect(
      adapter.requests.map((request) => request.uri.path).toSet(),
      unorderedEquals(paths.values),
    );
  });

  test('Chaturbate keeps couples and replaces male/trans categories', () async {
    const base = 'https://live.fixture.test';
    const liveSite = SiteDef(
      id: 'chaturbate',
      name: 'Live fixture',
      kind: SiteKind.live,
      tags: SourceCatalog.chaturbateTags,
      color: 0,
      letter: 'C',
      mirrors: [base],
    );
    final fixtures = <String, _FixtureResponse>{};
    for (final entry in const {
      'female': (query: '&genders=f', fields: '"gender":"f"'),
      'couples': (query: '&genders=c', fields: '"gender":"c"'),
      'new': (
        query: '&genders=f&sort_order=new',
        fields: '"gender":"f","is_new":true'
      ),
      'asian': (
        query: '&genders=f&tags=asian',
        fields: '"gender":"f","tags":["asian"]'
      ),
    }.entries) {
      fixtures[
              '$base/api/ts/roomlist/room-list/?limit=20&offset=0${entry.value.query}'] =
          _FixtureResponse(
        '{"rooms":['
        '${entry.key != 'female' ? '{"username":"ignored_female","current_show":"public","is_online":true,"gender":"f"},' : ''}'
        '{"username":"${entry.key}_room","current_show":"public",'
        '"is_online":true,${entry.value.fields}},'
        '{"username":"${entry.key}_private","current_show":"private","is_online":true},'
        '{"username":"${entry.key}_offline","current_show":"public","is_online":false}'
        '],"metadata":{"room":"fake_nested_room"}}',
      );
    }
    final dio = Dio();
    final adapter = _FixtureAdapter(fixtures);
    dio.httpClientAdapter = adapter;
    final api = GenericSiteApi(dio: dio);

    for (final tag in liveSite.tags) {
      final feed = await api.fetchFeed(liveSite, tagId: tag.id, limit: 10);
      expect(feed.single.url, '$base/${tag.id}_room');
    }

    expect(adapter.requests, hasLength(4));
    expect(
      adapter.requests.map((request) => request.uri.queryParameters['genders']),
      containsAll(<String>['f', 'c']),
    );
    expect(
      adapter.requests.map((request) => request.uri.queryParameters['tags']),
      contains('asian'),
    );
  });

  test('Stripchat feed keeps online room without promoting preview HLS',
      () async {
    const base = 'https://strip.fixture.test';
    const playlist =
        'https://edge-hls.doppiocdn.com/hls/83306615/master/83306615_240p.m3u8';
    const liveSite = SiteDef(
      id: 'stripchat',
      name: 'Strip fixture',
      kind: SiteKind.live,
      tags: SourceCatalog.stripchatTags,
      color: 0,
      letter: 'S',
      mirrors: [base],
    );
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      '$base/api/front/models?limit=20&offset=0&primaryTag=girls&sortBy=stripRanking':
          const _FixtureResponse(
        '{"models":[{"username":"model-name","streamName":"83306615",'
        '"isOnline":true,"previewUrl":"https://preview.test/20s.mp4",'
        '"hlsPlaylist":"$playlist"}]}',
      ),
      playlist: const _FixtureResponse('#EXTM3U\n#EXTINF:2,\nsegment.ts'),
    });
    final api = GenericSiteApi(dio: dio);

    final feed = await api.fetchFeed(liveSite, tagId: 'girls', limit: 1);
    expect(feed.single.url, '$base/model-name');
    await expectLater(
      api.getVideoDetail(liveSite, feed.single.url),
      throwsA(predicate((error) => error.toString().contains('WebRTC'))),
    );
  });

  test('Stripchat replaces the male tab with a newest-girls feed', () async {
    expect(SourceCatalog.stripchatTags.map((tag) => tag.id), [
      'girls',
      'new',
      'couples',
      'more',
    ]);
    expect(SourceCatalog.stripchatTags.map((tag) => tag.id),
        isNot(contains('men')));
    expect(SourceCatalog.stripchatTags.map((tag) => tag.id),
        isNot(contains('trans')));

    const base = 'https://strip-new.fixture.test';
    const liveSite = SiteDef(
      id: 'stripchat',
      name: 'Strip fixture',
      kind: SiteKind.live,
      tags: SourceCatalog.stripchatTags,
      color: 0,
      letter: 'S',
      mirrors: [base],
    );
    final dio = Dio();
    final adapter = _FixtureAdapter({
      '$base/api/front/models?limit=20&offset=0&primaryTag=girls&sortBy=newModels':
          const _FixtureResponse(
        '{"models":[{"username":"new-girl-room","isOnline":true}]}',
      ),
    });
    dio.httpClientAdapter = adapter;

    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      liveSite,
      tagId: 'new',
      limit: 1,
    );

    expect(feed.single.url, '$base/new-girl-room');
    expect(adapter.requests.single.uri.queryParameters['primaryTag'], 'girls');
    expect(adapter.requests.single.uri.queryParameters['sortBy'], 'newModels');
  });

  test('Stripchat more tab uses a valid later girls page', () async {
    const base = 'https://strip-more.fixture.test';
    const liveSite = SiteDef(
      id: 'stripchat',
      name: 'Strip fixture',
      kind: SiteKind.live,
      tags: SourceCatalog.stripchatTags,
      color: 0,
      letter: 'S',
      mirrors: [base],
    );
    final dio = Dio();
    final adapter = _FixtureAdapter({
      '$base/api/front/models?limit=20&offset=60&primaryTag=girls&sortBy=stripRanking':
          const _FixtureResponse(
        '{"models":[{"username":"more-girl-room","isOnline":true}]}',
      ),
    });
    dio.httpClientAdapter = adapter;

    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      liveSite,
      tagId: 'more',
      limit: 1,
    );

    expect(feed.single.url, '$base/more-girl-room');
    expect(adapter.requests.single.uri.queryParameters['primaryTag'], 'girls');
    expect(adapter.requests.single.uri.queryParameters['offset'], '60');
    expect(
        adapter.requests.single.uri.queryParameters, isNot(contains('tags')));
  });

  test('catalog keeps stable sources only after removing broken VODs', () {
    final enabled = SourceCatalog.defaultEnabledVideoIds;
    for (final id in [
      'pornhub',
      'xvideos',
      // mitao 已按用户要求从卡片目录移除（2026-09），SiteDef 仍保留供
      // 自定义解析器复用，但不得再出现在默认启用列表里。
      'xnxx',
      'xhamster',
      'tnaflix',
      'jable',
    ]) {
      expect(enabled, contains(id), reason: '$id should be ready/enabled');
    }
    for (final id in [
      'eporner',
      'freeporn',
      'spankbang',
      'youporn',
      'redtube',
      'javmix',
      'javgg',
      'av01',
      'missav',
      '7mmtv',
      'bestjavporn',
      'our55',
      'xqq88',
    ]) {
      expect(SourceCatalog.byId(id), isNull, reason: '$id should be removed');
      expect(enabled, isNot(contains(id)));
    }
    // mitao 的 SiteDef 仍在（自定义解析器复用），但绝不能出现在目录/默认列表。
    expect(enabled, isNot(contains('mitao')));
    expect(
      SourceCatalog.all.where((s) => s.id == 'mitao'),
      isEmpty,
      reason: 'mitao should not be listed as a card',
    );
    expect(SourceCatalog.defaultLiveId, 'chaturbate');
    expect(SourceCatalog.chaturbate.ready, isTrue);
    expect(SourceCatalog.stripchat.ready, isTrue);
    expect(SourceCatalog.usesRandomizedGenericFeed(SourceCatalog.xnxx), isTrue);
    expect(
      SourceCatalog.usesRandomizedGenericFeed(SourceCatalog.stripchat),
      isFalse,
    );
    expect(
      SourceCatalog.usesRandomizedGenericFeed(SourceCatalog.chaturbate),
      isFalse,
    );
  });

  test('parses thumb and duration for XNXX-family listing cards', () async {
    final cases = <SiteDef>[
      SourceCatalog.xnxx,
      SourceCatalog.xhamster,
      SourceCatalog.tnaflix,
      SourceCatalog.jable,
    ];
    for (final site in cases) {
      final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
      final path = switch (site.id) {
        'xnxx' => '$base/search/new/1',
        'xhamster' => '$base/newest/1',
        'tnaflix' => '$base/new/?page=1',
        'jable' => '$base/latest-updates/1/',
        _ => throw StateError('unexpected site ${site.id}'),
      };
      final href = switch (site.id) {
        'xnxx' => '/video-xnxxalpha/',
        'xhamster' => '/videos/xhamster-alpha',
        'tnaflix' => '/video/tnaflix-alpha/123456',
        'jable' => '/videos/jable-alpha/',
        _ => throw StateError('unexpected site ${site.id}'),
      };
      final adapter = _FixtureAdapter({
        path: _FixtureResponse(
          _html('''
            <div class="video-card">
              <a href="$href" title="${site.name} Alpha">
                <div class="thumb"
                  style="background-image:url('/thumbs/${site.id}-alpha.jpg')"></div>
                <span class="duration" data-duration="12:34">12:34</span>
              </a>
            </div>
          '''),
        ),
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final feed = await GenericSiteApi(dio: dio).fetchFeed(
        site,
        tagId: 'new',
        limit: 1,
      );

      expect(feed, hasLength(1), reason: site.id);
      expect(feed.single.thumb, endsWith('/thumbs/${site.id}-alpha.jpg'),
          reason: site.id);
      expect(feed.single.duration, '12:34', reason: site.id);
    }
  });
}

String _html(String body) => '<!doctype html><html><head>$body</head><body>'
    '${List.filled(400, 'fixture').join()}</body></html>';

class _FixtureResponse {
  const _FixtureResponse(
    this.body, {
    this.headers = const {},
    this.statusCode = 200,
    this.delay = Duration.zero,
  });

  final String body;
  final Map<String, List<String>> headers;
  final int statusCode;
  final Duration delay;
}

class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter(this.fixtures);

  final Map<String, _FixtureResponse> fixtures;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final fixture = fixtures[options.uri.toString()];
    if (fixture == null) {
      return ResponseBody.fromString('not found', 404);
    }
    if (fixture.delay > Duration.zero) {
      await Future<void>.delayed(fixture.delay);
    }
    return ResponseBody.fromString(
      fixture.body,
      fixture.statusCode,
      headers: fixture.headers,
    );
  }

  @override
  void close({bool force = false}) {}
}
