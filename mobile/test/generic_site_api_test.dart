import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/generic_site_api.dart';
import 'package:epickle/services/source_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

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

  test('RedTube resolves mediaDefinition token indexes to CDN streams',
      () async {
    const pageUrl = 'https://www.redtube.com/267756101';
    const hlsIndex = 'https://www.redtube.com/media/hls?s=token-hls';
    const mp4Index = 'https://www.redtube.com/media/mp4?s=token-mp4';
    const cdn720 = 'https://em-ph.rdtcdn.com/videos/x/720P.mp4?hash=a';
    const cdn1080 = 'https://em-ph.rdtcdn.com/videos/x/1080P.mp4?hash=b';
    const cdnHls720 =
        'https://im-h-ph.rdtcdn.com/hls/x/720P/master.m3u8?token=h';
    final adapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html(r'''
          <script>
            mediaDefinition: [{"format":"hls","videoUrl":"\/media\/hls?s=token-hls","remote":true},{"format":"mp4","videoUrl":"\/media\/mp4?s=token-mp4","remote":true}],
          </script>
        '''),
      ),
      mp4Index: _FixtureResponse(
        jsonEncode([
          {'quality': '1080', 'videoUrl': cdn1080},
          {'quality': '720', 'videoUrl': cdn720},
        ]),
      ),
      hlsIndex: _FixtureResponse(
        jsonEncode([
          {
            'quality': '720',
            'width': 720,
            'height': 404,
            'videoUrl': cdnHls720,
          },
        ]),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;

    final detail = await GenericSiteApi(
      dio: dio,
    ).getVideoDetail(SourceCatalog.redtube, pageUrl);
    final urls = detail.streams.map((stream) => stream.url).toList();

    expect(urls, containsAll([cdn1080, cdn720, cdnHls720]));
    expect(
      urls,
      everyElement(isNot(contains('/media/'))),
      reason: 'the token index must never be handed to the player',
    );
    expect(detail.streams.first.height, 1080);
    expect(
      adapter.requests.where((r) => r.uri.toString() == hlsIndex),
      hasLength(1),
      reason: 'both indexes are fetched in parallel to offer an HLS fallback',
    );
    final mediaRequest = adapter.requests.singleWhere(
      (r) => r.uri.toString() == mp4Index,
    );
    expect(mediaRequest.headers['Referer'], pageUrl);
  });

  test('Eporner prefers /dload MP4 links and skips AV1', () async {
    const pageUrl = 'https://www.eporner.com/video-ZfZ5g0AdJiX/example/';
    const d240 = '/dload/ZfZ5g0AdJiX/240/18908446-240p.mp4';
    const d720 = '/dload/ZfZ5g0AdJiX/720/18908446-720p.mp4';
    const d1080 = '/dload/ZfZ5g0AdJiX/1080/18908446-1080p.mp4';
    const av1 = '/dload/ZfZ5g0AdJiX/240/18908446-240p-av1.mp4';
    const gvideo = 'https://gvideo.eporner.com/ZfZ5g0AdJiX/ZfZ5g0AdJiX.mp4';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>{"contentUrl": "$gvideo"}</script>
          <a href="$d240">240p</a>
          <a href="$d720">720p</a>
          <a href="$d1080">1080p</a>
          <a href="$av1">240p AV1</a>
        '''),
      ),
    });

    final detail = await GenericSiteApi(
      dio: dio,
    ).getVideoDetail(SourceCatalog.eporner, pageUrl);
    final urls = detail.streams.map((stream) => stream.url).toList();

    expect(urls.first, 'https://www.eporner.com$d720');
    expect(urls, contains('https://www.eporner.com$d240'));
    expect(urls, everyElement(isNot(contains('-av1'))));
    expect(urls, isNot(contains(gvideo)));
    expect(
      urls,
      isNot(contains('https://www.eporner.com$d1080')),
      reason: '1080p /dload redirects anonymous sessions to /login',
    );
    expect(detail.streams.first.height, 720);
  });

  test('Eporner category tags use /cat/{slug}/ pages, not the public API',
      () async {
    const base = 'https://eporner.test';
    const site = SiteDef(
      id: 'eporner',
      name: 'Eporner',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'E',
      mirrors: [base],
      parserId: 'eporner',
    );
    final adapter = _FixtureAdapter({
      '$base/cat/milf/2/': _FixtureResponse(
        _html('''
          <div class="mb" data-id="1">
            <div class="mbimg"><div class="mbcontent">
              <a href="/video-qQrwSe15G43/curly-bbw-milf-s-huge-tits-destroy-young-stud/"><img src="https://static-ca-cdn.eporner.com/thumbs/1.jpg" alt="Curly BBW Milf" /></a>
            </div></div>
            <div class="mbunder"><p class="mbtit"><a href="/video-qQrwSe15G43/curly-bbw-milf-s-huge-tits-destroy-young-stud/">Curly BBW Milf&#039;s Huge Tits</a></p>
            <p class="mbstats"><span class="mbtim" title="Duration">8:00</span></p></div>
          </div>
          <div class="mb" data-id="2">
            <div class="mbimg"><div class="mbcontent">
              <a href="/video-S49V58k2LKU/richelle-ryan/"><img src="https://static-ca-cdn.eporner.com/thumbs/2.jpg" alt="Richelle Ryan" /></a>
            </div></div>
            <div class="mbunder"><p class="mbtit"><a href="/video-S49V58k2LKU/richelle-ryan/">Richelle Ryan</a></p>
            <p class="mbstats"><span class="mbtim" title="Duration">12:34</span></p></div>
          </div>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;

    final feed = await GenericSiteApi(
      dio: dio,
    ).fetchFeed(site, tagId: 'milf', page: 2, limit: 40);

    expect(feed.length, 2);
    expect(feed.first.url, contains('/video-qQrwSe15G43/'));
    expect(feed.first.title, "Curly BBW Milf's Huge Tits");
    expect(feed.first.duration, '8:00');
    expect(feed.first.thumb, contains('/thumbs/1.jpg'));
    expect(feed.last.duration, '12:34');
    expect(
      adapter.requests.where((r) => r.uri.path.contains('/api/v2/')),
      isEmpty,
    );
    expect(
      adapter.requests.map((r) => r.uri.toString()),
      contains('$base/cat/milf/2/'),
    );
  });

  test('RedTube category tags use /redtube/{slug} pages', () async {
    const base = 'https://redtube.test';
    const site = SiteDef(
      id: 'redtube',
      name: 'RedTube',
      kind: SiteKind.video,
      tags: [],
      color: 0,
      letter: 'R',
      mirrors: [base],
      parserId: 'redtube',
    );
    final adapter = _FixtureAdapter({
      '$base/redtube/bigtits?page=2': _FixtureResponse(
        _html('''
          <div class="video_block_wrapper">
            <a class="video_link" href="/267756101" data-video-id="267756101" title="Fixture RedTube video">
              <img src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP" data-o_thumb="https://pix-cdn77.rdtcdn.com/c6371/preview?hash=x&amp;validto=2" />
            </a>
            <span class="video-properties tm_video_duration">13:48</span>
          </div>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;

    final feed = await GenericSiteApi(
      dio: dio,
    ).fetchFeed(site, tagId: 'bigtits', page: 2, limit: 40);

    expect(feed, hasLength(1));
    expect(feed.first.url, '$base/267756101');
    expect(feed.first.title, 'Fixture RedTube video');
    expect(feed.first.duration, '13:48');
    expect(feed.first.thumb, contains('pix-cdn77.rdtcdn.com'));
    expect(
      adapter.requests.map((r) => r.uri.toString()),
      contains('$base/redtube/bigtits?page=2'),
    );
    expect(
      adapter.requests.map((r) => r.uri.toString()),
      isNot(contains(contains('most-favorited'))),
    );
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

  test('Chaturbate filters theme tags locally across API pages', () async {
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
    final fixtures = <String, _FixtureResponse>{
      // 性别组仍走服务器参数，一页即可。
      '$base/api/ts/roomlist/room-list/?limit=20&offset=0&genders=f':
          const _FixtureResponse(
        '{"rooms":[{"username":"female_room","current_show":"public",'
        '"is_online":true,"gender":"f"}]}',
      ),
      '$base/api/ts/roomlist/room-list/?limit=20&offset=0&genders=c':
          const _FixtureResponse(
        '{"rooms":[{"username":"couples_room","current_show":"public",'
        '"is_online":true,"gender":"c"}]}',
      ),
      // 主题标签：API 忽略 tags/sort_order，必须扫多页后客户端过滤。
      '$base/api/ts/roomlist/room-list/?limit=90&offset=0&genders=f':
          const _FixtureResponse(
        '{"rooms":[{"username":"ignored_female","current_show":"public",'
        '"is_online":true,"gender":"f"},'
        '{"username":"new_room","current_show":"public","is_online":true,'
        '"gender":"f","is_new":true},'
        '{"username":"asian_room","current_show":"public","is_online":true,'
        '"gender":"f","tags":["asian"]}]}',
      ),
      for (final offset in const [90, 180, 270, 360])
        '$base/api/ts/roomlist/room-list/?limit=90&offset=$offset&genders=f':
            const _FixtureResponse('{"rooms":[]}'),
    };
    final dio = Dio();
    final adapter = _FixtureAdapter(fixtures);
    dio.httpClientAdapter = adapter;
    final api = GenericSiteApi(dio: dio);

    expect(
      (await api.fetchFeed(liveSite, tagId: 'female', limit: 10)).single.url,
      '$base/female_room',
    );
    expect(
      (await api.fetchFeed(liveSite, tagId: 'couples', limit: 10)).single.url,
      '$base/couples_room',
    );
    expect(
      (await api.fetchFeed(liveSite, tagId: 'new', limit: 10)).single.url,
      '$base/new_room',
    );
    expect(
      (await api.fetchFeed(liveSite, tagId: 'asian', limit: 10)).single.url,
      '$base/asian_room',
    );

    final themeRequests = adapter.requests.where(
      (r) => r.uri.queryParameters['limit'] == '90',
    );
    expect(
      themeRequests.map((r) => r.uri.queryParameters['offset']).toSet(),
      {'0', '90', '180', '270', '360'},
    );
    expect(
      adapter.requests.map((r) => r.uri.queryParameters).expand((q) => q.keys),
      isNot(contains('tags')),
    );
    expect(
      adapter.requests.map((r) => r.uri.queryParameters).expand((q) => q.keys),
      isNot(contains('sort_order')),
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
        '"previewUrlThumbSmall":'
        '"https://static-proxy.strpst.com/previews/a/b/c/thumb-small",'
        '"hlsPlaylist":"$playlist"}]}',
      ),
      playlist: const _FixtureResponse('#EXTM3U\n#EXTINF:2,\nsegment.ts'),
    });
    final api = GenericSiteApi(dio: dio);

    final feed = await api.fetchFeed(liveSite, tagId: 'girls', limit: 1);
    expect(feed.single.url, '$base/model-name');
    // Stripchat 的缩略图字段是 previewUrlThumbSmall（没有 previewUrl）；
    // 漏掉它卡片就是空白占位。
    expect(
      feed.single.thumb,
      'https://static-proxy.strpst.com/previews/a/b/c/thumb-small',
    );
    await expectLater(
      api.getVideoDetail(liveSite, feed.single.url),
      throwsA(predicate((error) => error.toString().contains('WebRTC'))),
    );
  });

  test('Stripchat feed filters paid shows and offline rooms by status',
      () async {
    const base = 'https://strip-filter.fixture.test';
    const liveSite = SiteDef(
      id: 'stripchat',
      name: 'Strip filter fixture',
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
        '{"models":['
        '{"username":"public_room","status":"public","isLive":true,'
        '"isOnline":true,"streamName":"111"},'
        '{"username":"private_room","status":"privateShow","isLive":true,'
        '"isOnline":true,"streamName":"222"},'
        '{"username":"ticket_room","status":"groupShow","isLive":true,'
        '"isOnline":true,"streamName":"333"},'
        '{"username":"offline_room","status":"public","isLive":false,'
        '"isOnline":true,"streamName":"444"},'
        // Stripchat 下播房间的真实形态：status 仍是 public、isLive 仍是
        // true，只有 isOnline:false —— 必须靠这个字段挡住。
        '{"username":"offline_flag","status":"public","isLive":true,'
        '"isOnline":false,"streamName":"555"}'
        ']}',
      ),
    });
    final api = GenericSiteApi(dio: dio);

    final feed = await api.fetchFeed(liveSite, tagId: 'girls', limit: 10);
    expect(feed.map((item) => item.url), ['$base/public_room']);
  });

  test('Stripchat newest tab reads /girls/new/ instead of an invalid sortBy',
      () async {
    expect(SourceCatalog.stripchatTags.map((tag) => tag.id), [
      'girls',
      'new',
      'couples',
      'asian',
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
      '$base/girls/new/': const _FixtureResponse(
        '<html><script>window.__STATE__ = '
        '{"models":[{"username":"new-girl-room","status":"public",'
        '"isOnline":true,"streamName":"888","id":888}],'
        '"other":[]};</script></html>',
      ),
    });
    dio.httpClientAdapter = adapter;

    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      liveSite,
      tagId: 'new',
      limit: 1,
    );

    expect(feed.single.url, '$base/new-girl-room');
    expect(adapter.requests.single.uri.path, '/girls/new/');
    // 2026-11-28 实证：sortBy 只接受 stripRanking，newModels 会 400；
    // "最新"必须走 SSR 主题页。
    expect(
      adapter.requests.where((r) => r.uri.path.contains('/api/')),
      isEmpty,
    );
  });

  test('Stripchat asian tab reads the themed SSR page, never duplicates girls',
      () async {
    const base = 'https://strip-asian.fixture.test';
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
      '$base/girls/asian/': const _FixtureResponse(
        '<html><script>window.__STATE__ = '
        '{"models":[{"username":"asian-room","status":"public",'
        '"isOnline":true,"streamName":"777","id":777}],'
        '"other":[]};</script></html>',
      ),
    });
    dio.httpClientAdapter = adapter;

    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      liveSite,
      tagId: 'asian',
      limit: 1,
    );

    expect(feed.single.url, '$base/asian-room');
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.path, '/girls/asian/');
    expect(
      adapter.requests.where((r) => r.uri.path.contains('/api/')),
      isEmpty,
    );
  });

  test('Stripchat themed SSR failure never falls back to the girls API',
      () async {
    const base = 'https://strip-asian-fail.fixture.test';
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
    final adapter = _FixtureAdapter(const {});
    dio.httpClientAdapter = adapter;

    // SSR 全部失败时应当报错/空结果，而不是偷偷换成 girls API 的重复内容。
    await expectLater(
      GenericSiteApi(dio: dio).fetchFeed(
        liveSite,
        tagId: 'asian',
        limit: 1,
      ),
      throwsA(anything),
    );
    // 绝不回退 girls API：那会把"亚"页变成"女"页的重复内容。
    expect(
      adapter.requests.where((r) => r.uri.path.contains('/api/')),
      isEmpty,
    );
  });

  test('RedTube cards use data-o_thumb thumbnails and bare numeric URLs',
      () async {
    final site = SourceCatalog.redtube;
    final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
    final adapter = _FixtureAdapter({
      '$base/?page=1': _FixtureResponse(
        _html('''
          <li id="video_list267756101" class="js-pop thumbnail-card">
            <div class="video_block_wrapper">
              <span class="video_thumb_wrap">
                <a href="/267756101" data-video-id="267756101">
                  <picture class="js_thumbPicTag">
                    <source data-srcset="https://pix-cdn77.rdtcdn.com/x/original.mp4/plain/rs:fit:192:108?hash=a&amp;validto=1 1x">
                    <img alt="Hot Couple Alpha" src="data:image/png;base64,AAAA"
                      data-o_thumb="https://pix-cdn77.rdtcdn.com/x/original.mp4/plain/rs:fit:384:216?hash=b&amp;validto=1">
                  </picture>
                </a>
              </span>
            </div>
          </li>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      site,
      tagId: 'hot',
      limit: 1,
    );

    expect(feed, hasLength(1));
    expect(feed.single.url, '$base/267756101');
    expect(feed.single.title, 'Hot Couple Alpha');
    expect(
      feed.single.thumb,
      'https://pix-cdn77.rdtcdn.com/x/original.mp4/plain/rs:fit:384:216?hash=b&validto=1',
    );
  });

  test('RedTube detail resolves mediaDefinitions index before playback',
      () async {
    final site = SourceCatalog.redtube;
    const pageUrl = 'https://www.redtube.com/267756101';
    const hlsIndex = 'https://www.redtube.com/media/hls?s=abc';
    const hlsCdn =
        'https://im-h-ph.rdtcdn.com/hls/c6251/720P/master.m3u8?token=1';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <meta property="og:image"
            content="https://pix-cdn77.rdtcdn.com/x.jpg?hash=c&amp;validto=1">
          <script>
            var player = {"mediaDefinitions":[
              {"format":"hls","videoUrl":"\\/media\\/hls?s=abc","remote":true},
              {"format":"mp4","videoUrl":"https:\\/\\/cdn.test\\/v.mp4","remote":true}
            ]};
          </script>
        '''),
      ),
      hlsIndex: _FixtureResponse(
        jsonEncode([
          {
            'format': 'hls',
            'quality': '720',
            'width': 720,
            'height': 404,
            'videoUrl': hlsCdn,
          },
        ]),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);
    final urls = detail.streams.map((stream) => stream.url).toList();

    expect(urls, contains(hlsCdn));
    expect(
      urls,
      isNot(contains(hlsIndex)),
      reason: 'the JSON index itself is not a playable media URL',
    );
    expect(detail.thumb, 'https://pix-cdn77.rdtcdn.com/x.jpg?hash=c&validto=1');
  });

  test('catalog keeps stable sources only after removing broken VODs', () {
    final enabled = SourceCatalog.defaultEnabledVideoIds;
    for (final id in [
      'pornhub',
      'xvideos',
      'huangguo',
      'xnxx',
      'xhamster',
      'redtube',
      'eporner',
      'tnaflix',
    ]) {
      expect(enabled, contains(id), reason: '$id should be ready/enabled');
    }
    for (final id in [
      // 2026-11 下架：浪妹上游视频 CDN 域名 NXDOMAIN，播放/新图不可用。
      'langmei',
      'yaofafa',
      'jable',
      'supjav',
      '123av',
      '7mmtv',
      'bestjavporn',
      'pornbest',
      'ixxx',
      'fuq',
      'qorno',
      'pornkai',
      'tubesafari',
      'hotsextube',
      // 更早下架的站点。
      'freeporn',
      'spankbang',
      'youporn',
      'javmix',
      'javgg',
      'av01',
      'missav',
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
    ];
    for (final site in cases) {
      final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
      final path = switch (site.id) {
        'xnxx' => '$base/search/new/1',
        'xhamster' => '$base/newest/1',
        'tnaflix' => '$base/new/?page=1',
        _ => throw StateError('unexpected site ${site.id}'),
      };
      final href = switch (site.id) {
        'xnxx' => '/video-xnxxalpha/',
        'xhamster' => '/videos/xhamster-alpha',
        'tnaflix' => '/amateur-porn/tnaflix-alpha/video123456',
        _ => throw StateError('unexpected site ${site.id}'),
      };
      final adapter = _FixtureAdapter({
        path: _FixtureResponse(
          _html('''
            <a href="/featured/2?page=1">More featured</a>
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

  test('iXXX cards resolve /out/?l= to partner playback pages', () async {
    final site = SourceCatalog.ixxx;
    final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
    // 列表页路径：hot 标签 → /zh/popular?page=1（2026-10 重新捕获的规则）。
    // 混淆帧：垃圾前缀 + 公共 id + 合作站播放页 URL（utf8 里的 ASCII 段）。
    final l = base64Encode(
      utf8.encode(
        'JUNKBIN EEAcMVrn4fm '
        'https://fhgte.com/videos/tyAyMU?utm_campaign=pbw_free&v=3',
      ),
    );
    final href = '/out/?l=$l&c=adc05086474ad796&v=3';
    final adapter = _FixtureAdapter({
      '$base/zh/popular?page=1': _FixtureResponse(
        _html('''
          <div class="card sub group relative block space-y-1" data-public-id="EEAcMVrn4fm">
            <a class="item-link relative rounded" href="$href" title="Urban Beauties Alpha">
              <img class="item-image" src="https://c3.ttcache.com/thumbnail/EEAcMVrn4fm/288x162/20.jpg" />
            </a>
            <span class="badge">22:06</span>
          </div>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      site,
      tagId: 'hot',
      limit: 1,
    );
    expect(feed, hasLength(1));
    // /out 链接必须被解成合作站真实播放页
    expect(
      feed.single.url,
      'https://fhgte.com/videos/tyAyMU?utm_campaign=pbw_free&v=3',
    );
    expect(feed.single.title, 'Urban Beauties Alpha');
    expect(feed.single.thumb,
        'https://c3.ttcache.com/thumbnail/EEAcMVrn4fm/288x162/20.jpg');
    expect(feed.single.duration, '22:06');
  });

  test('iXXX searches via /zh/search/{q}?page=N', () async {
    final site = SourceCatalog.ixxx;
    final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
    final adapter = _FixtureAdapter({
      '$base/zh/search/asian?page=1': _FixtureResponse(
        _html('''
          <div class="card sub group relative block space-y-1" data-public-id="XeRAMH4Lned">
            <a class="item-link" href="/out/?l=${base64Encode(utf8.encode('JUNK XeRAMH4Lned https://www.xozilla.xxx/videos/380190/alpha-video/'))}&c=xx&v=3"
               title="Alpha Search Hit">
              <img src="https://c3.ttcache.com/thumbnail/XeRAMH4Lned/288x162/3.jpg" />
            </a>
            <span class="badge">10:21</span>
          </div>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final hits = await GenericSiteApi(dio: dio).search(site, 'asian');
    expect(hits, isNotEmpty);
    expect(
      hits.first.url,
      'https://www.xozilla.xxx/videos/380190/alpha-video/',
    );
  });

  test('hot-sex-tube cards decode /o.php?u= base64url partner links', () async {
    final site = SourceCatalog.hotsextube;
    final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
    // u=<base64url(token)>：url-safe 字母表（- → +，_ → /），~ 代 '=' 填充。
    final token = base64Url
        .encode(utf8.encode('https://icpvid.com/v/DO8i'))
        .replaceAll('=', '~')
        .replaceAll('+', '-')
        .replaceAll('/', '_');
    final adapter = _FixtureAdapter({
      '$base/categories/asian/1.html': _FixtureResponse(
        _html('''
          <a href="/o.php?cat=asian&amp;id=39e443e5&amp;u=$token" target="_blank">
            <img src="https://tn.hot-sex-tube.com/39/e4/39e443e5.jpg" class="t" alt="Kai Asian Alpha">
            <span>Kai Asian Alpha</span>
          </a>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      site,
      tagId: 'asian',
      limit: 1,
    );
    expect(feed, hasLength(1));
    // /o.php 外链必须被离线解成合作站真实播放页
    expect(feed.single.url, 'https://icpvid.com/v/DO8i');
  });

  test('tubeSafari keeps /video?id= cards and searches via /search/{q}',
      () async {
    final site = SourceCatalog.tubesafari;
    final base = site.primaryHost.replaceAll(RegExp(r'/$'), '');
    final adapter = _FixtureAdapter({
      '$base/search/new': _FixtureResponse(
        _html('''
          <a target="_blank" rel="nofollow" class="xktc opop trigger_pop"
             href="/video?id=xv89494822" title="Safari New Alpha">
            <img class="trigger_pop vid_thumbnail roll vtx"
                 src="https://thumb-cdn77.others-cdn.com/1e70d6ac/xv_29_t.jpg" />
            <div class="video_title">Safari New Alpha</div>
            <span class="duration">12:02</span>
          </a>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      site,
      tagId: 'new',
      limit: 1,
    );
    expect(feed, hasLength(1));
    // tubeSafari 条目保留站内中转页（详情页内嵌 xvideos 播放器）。
    expect(feed.single.url, '$base/video?id=xv89494822');
    expect(feed.single.title, 'Safari New Alpha');
  });

  test('pornKai keeps /view?key= cards and searches via /videos?q={q}',
      () async {
    final site = SourceCatalog.pornkai;
    final base = site.primaryHost;
    final adapter = _FixtureAdapter({
      '$base/videos?q=new': _FixtureResponse(
        _html('''
          <a target="_blank" rel="nofollow" class="thumbnail_link th_derp trigger_pop"
             href="/view?key=67b2e05707d2b">
            <span class="trigger_pop th_wrap">Kai New Alpha</span>
            <div class="trigger_pop thumbnail_image_holder">
              <img class="trigger_pop slideshow roll"
                   src="https://ei.phncdn.com/videos/202502/17/kai-new-alpha.jpg" />
            </div>
            <div class="thumbnail_video_length"><i class="far fa-clock"></i> 8:09</div>
          </a>
        '''),
      ),
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final feed = await GenericSiteApi(dio: dio).fetchFeed(
      site,
      tagId: 'new',
      limit: 1,
    );
    expect(feed, hasLength(1));
    // pornKai 条目保留站内详情页（详情页内嵌 videopornl.com/embed）。
    expect(feed.single.url, '$base/view?key=67b2e05707d2b');
    expect(feed.single.thumb,
        'https://ei.phncdn.com/videos/202502/17/kai-new-alpha.jpg');
  });

  test('faphouse long_trailers main video survives both filters', () async {
    // fhgte 卡 301 落点 faphouse：主片质量映射在 &quot; 转义的 JSON 里，
    // 路径含 long_trailers —— 曾在两处过滤（add() 防预告片 + 预览过滤）
    // 被连续误杀，iXXX 货架最大一块可播卡从未能播。
    const pageUrl = 'https://faphouse.com/videos/0XmK1O/slutty-tits';
    String mk(int q) =>
        'https://video-pr.xhcdn.com/key=x3MMpUjNj8STIO6Fv-+NrQ,end=1793152800'
        '/data=38.47.115.236/speed=0k/0X/0XmK1O/long_trailers/$q.mp4';
    final escaped = {
      '"240"': '"${mk(240)}"',
      '"480"': '"${mk(480)}"',
      '"1080"': '"${mk(1080)}"',
    }.entries
        .map((e) => '{&quot;width&quot;:0,&quot;label&quot;:&quot;${e.key}'
            '&quot;,&quot;file&quot;:${e.value}}')
        .join(',');
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <script>window.__data = "[$escaped]";</script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);

    expect(
      detail.streams.map((s) => s.url),
      containsAll([mk(240), mk(480), mk(1080)]),
    );
  });

  test('vidzx real source.mp4 passes preview filter while _preview drops',
      () async {
    const pageUrl = 'https://vidzx.org/video/161532/taylor-blake';
    const main = 'https://a.trueamateurporn.org/sources/58ed479c/source.mp4';
    const preview = 'https://a.trueamateurporn.org/sources/58ed479c/_preview.mp4';
    final dio = Dio();
    dio.httpClientAdapter = _FixtureAdapter({
      pageUrl: _FixtureResponse(
        _html('''
          <video src="$preview" muted autoplay></video>
          <script type="application/ld+json">{"contentUrl":"$main"}</script>
        '''),
      ),
    });

    final detail = await GenericSiteApi(dio: dio).getVideoDetail(site, pageUrl);
    final urls = detail.streams.map((s) => s.url).toList();

    expect(urls, contains(main));
    expect(urls, isNot(contains(preview)));
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
