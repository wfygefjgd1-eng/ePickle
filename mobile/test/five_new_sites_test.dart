// 2026-11 新增五站（85ro / 91MD / qiAV / 啪啪啦 / fangsung）的解析回归
// fixture：片段取自 2026-11-27/28 真实抓取页（D:\ePickle\_scratch*\ 工件），
// 覆盖每站的列表卡解析 + 播放直链抽取两条链路。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/generic_site_api.dart';
import 'package:epickle/services/source_catalog.dart';

void main() {
  final ro85 = SourceCatalog.byId('ro85')!;
  final md91 = SourceCatalog.byId('md91')!;
  final qinav = SourceCatalog.byId('qinav')!;
  final papalah = SourceCatalog.byId('papalah')!;
  final fangsung = SourceCatalog.byId('fangsung')!;

  GenericSiteApi apiWith(Map<String, String> fixtures) {
    final dio = Dio()..httpClientAdapter = _MapAdapter(fixtures);
    return GenericSiteApi(dio: dio);
  }

  group('85ro（KVS）', () {
    test('列表：div.item 卡片（href/title/data-original/duration）', () async {
      const html = '''
        <div class="list-videos"><div class="margin-fix" id="list_videos_common_videos_list_items">
        <div class="item "> <a href="https://www.85ro.com/v/10383.html" title="大奶脫衣誘惑" > <div class="img"> <img class="thumb lazy-load" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-original="https://www.85ro.com/contents/videos_screenshots/10000/10383/320x180/1.jpg" data-webp="https://www.85ro.com/contents/videos_screenshots/10000/10383/336x189/1.jpg" alt="大奶脫衣誘惑" data-cnt="10" width="320" height="180"/> <span class="ico-fav-0 " title="添加到收藏" data-fav-video-id="10383" data-fav-type="0"></span> <div class="duration">4:53</div> </div> <strong class="title"> 大奶脫衣誘惑 </strong> <div class="wrap"> <div class="views">50K</div> <div class="rating positive"> 100% </div> </div> </a> </div>
        <div class="item "> <a href="https://www.85ro.com/v/4966.html" title="TWZP207 妹妹口爆" > <div class="img"> <img class="thumb lazy-load" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" data-original="https://www.85ro.com/contents/videos_screenshots/4000/4966/320x180/1.jpg" data-webp="https://www.85ro.com/contents/videos_screenshots/4000/4966/336x189/1.jpg" alt="TWZP207 妹妹口爆" data-cnt="1" width="320" height="180"/> <span class="is-hd is-2k">2K</span> <div class="duration">0:50</div> </div> <strong class="title"> TWZP207 妹妹口爆 </strong> <div class="wrap"> <div class="views">31K</div> </div> </a> </div>
        </div></div>
      ''';
      final items = await apiWith({
        'https://www.85ro.com/top-rated/1/': html,
      }).fetchFeed(ro85, tagId: 'hot', page: 1);

      expect(items.length, 2);
      expect(items.first.url, 'https://www.85ro.com/v/10383.html');
      expect(items.first.title, '大奶脫衣誘惑');
      expect(
        items.first.thumb,
        'https://www.85ro.com/contents/videos_screenshots/10000/10383/320x180/1.jpg',
      );
      expect(items.first.duration, '4:53');
      expect(items[1].title, 'TWZP207 妹妹口爆');
      expect(items[1].duration, '0:50');
    });

    test('详情：flashvars 明文 video_url（get_file 签名直链）', () async {
      const pageUrl = 'https://www.85ro.com/v/10383.html';
      const html = '''
        <title>大奶脫衣誘惑</title>
        <script>var tba1798d171 = { video_id: '10383', video_title: '大奶脫衣誘惑',
          video_url: 'https://www.85ro.com/get_file/3/5ba663094938998cceee1e63b5c555eb/10000/10383/10383.mp4/?v-acctoken=NTUyfDE0NTd8MHwwOTYxYTM4ZGQ1OTY4ZTBjYzMxMzkwNDQ5NGFkZWQwZg',
          event_reporting2: 'https://www.85ro.com/get_file/3/033adf57cb9b10dddea19373ddd6f9a0/10000/10383/10383.mp4/?v-acctoken=MTAzODN8MHwwfDg2MDBlOWYyZGE1YTc4YTIxMzBiOWFmZDdiZTZiN2My' }; </script>
      ''';
      final detail = await apiWith({pageUrl: html}).getVideoDetail(ro85, pageUrl);
      expect(detail.title, '大奶脫衣誘惑');
      expect(
        detail.streams.map((s) => s.url),
        contains(
          'https://www.85ro.com/get_file/3/5ba663094938998cceee1e63b5c555eb/10000/10383/10383.mp4/?v-acctoken=NTUyfDE0NTd8MHwwOTYxYTM4ZGQ1OTY4ZTBjYzMxMzkwNDQ5NGFkZWQwZg',
        ),
      );
    });
  });

  group('91MD（MacCMS）', () {
    test('列表：<li> 卡片（img src 直链 + alt 标题）', () async {
      const html = '''
        <ul class="list">
        <li><p class="img"><img class="lazy" src="https://23.225.11.173:8443/images/2026/11/27/e4594b796b59c8e5e79019d06b4e0cfd.jpg" alt="3P三洞填满顶级骚货舞蹈老师天生母狗体质" title="3P三洞填满顶级骚货舞蹈老师天生母狗体质"><a href="/index.php/vod/play/id/43018/sid/1/nid/1.html"></a></p><p>3P三洞填满顶级骚货舞蹈老师天生母狗体质</p><p><i>11-27</i><strong>929观看</strong></p></li>
        <li><p class="img"><img class="lazy" src="https://23.225.11.173:8443/images/2026/11/27/b22de967000000000000000000000000.jpg" alt="护士小妹妹下班后的心动的信号" title="护士小妹妹下班后的心动的信号"><a href="/index.php/vod/play/id/43008/sid/1/nid/1.html"></a></p><p>护士小妹妹下班后的心动的信号</p><p><i>11-27</i><strong>512观看</strong></p></li>
        </ul>
      ''';
      final items = await apiWith({
        'https://91md.me/index.php/vod/type/id/25/page/1.html': html,
      }).fetchFeed(md91, tagId: '25', page: 1);

      expect(items.length, 2);
      expect(
        items.first.url,
        'https://91md.me/index.php/vod/play/id/43018/sid/1/nid/1.html',
      );
      expect(items.first.title, '3P三洞填满顶级骚货舞蹈老师天生母狗体质');
      expect(
        items.first.thumb,
        'https://23.225.11.173:8443/images/2026/11/27/e4594b796b59c8e5e79019d06b4e0cfd.jpg',
      );
    });

    test('详情：player_aaaa encrypt=0 明文 m3u8', () async {
      const pageUrl =
          'https://91md.me/index.php/vod/play/id/43018/sid/1/nid/1.html';
      const html = '''
        <title>3P三洞填满顶级骚货舞蹈老师天生母狗体质</title>
        <script>var player_aaaa={"flag":"play","encrypt":0,"trysee":0,"points":0,
          "link":"\\/index.php\\/vod\\/play\\/id\\/43018\\/sid\\/1\\/nid\\/1.html",
          "vod_data":{"vod_name":"3P三洞填满","vod_class":""},
          "url":"https:\\/\\/t27.cdn2020.com\\/video\\/m3u8\\/2026\\/11\\/27\\/00ce0c49\\/index.m3u8",
          "from":"mahua","id":"43018","sid":1,"nid":1}</script>
      ''';
      final detail = await apiWith({pageUrl: html}).getVideoDetail(md91, pageUrl);
      expect(detail.title, '3P三洞填满顶级骚货舞蹈老师天生母狗体质');
      expect(
        detail.streams.map((s) => s.url),
        contains('https://t27.cdn2020.com/video/m3u8/2026/11/27/00ce0c49/index.m3u8'),
      );
    });
  });

  group('qiAV（自研 CMS）', () {
    test('列表：<a> 包 <li> 卡，真缩略图在 img= 属性', () async {
      const html = '''
        <ul>
        <a title="" href="/video/949931.html"><li class="image"><img class="lazy" src="/static/loading.gif" img="https://qin.toolmm.com/upload/94/99/31.jpg"><span class="time"></span><span class="note">60:52</span></li><li class="title">VAIAV-009 Alinya 巨乳AI女神异世沦陷 爆操内射无码</li></a>
        <li class="view"><u>1.2万</u></li>
        <a title="" href="/video/949932.html"><li class="image"><img class="lazy" src="/static/loading.gif" img="https://qin.toolmm.com/upload/94/99/32.jpg"><span class="time"></span><span class="note">23:51</span></li><li class="title">[无码流出] 情侣开房自拍泄露 高清对白</li></a>
        <li class="view"><u>9885</u></li>
        </ul>
      ''';
      final items = await apiWith({
        'https://www.qinav.com/new.html': html,
      }).fetchFeed(qinav, tagId: 'new', page: 1);

      expect(items.length, 2);
      expect(items.first.url, 'https://www.qinav.com/video/949931.html');
      expect(
        items.first.title,
        'VAIAV-009 Alinya 巨乳AI女神异世沦陷 爆操内射无码',
      );
      expect(items.first.thumb, 'https://qin.toolmm.com/upload/94/99/31.jpg');
      expect(items.first.duration, '60:52');
    });

    test('详情：/embed/{id} iframe 内明文 const url m3u8', () async {
      const pageUrl = 'https://www.qinav.com/video/949931.html';
      const embedUrl = 'https://www.qinav.com/embed/949931.html';
      final detail = await apiWith({
        pageUrl: '''
          <title>VAIAV-009 Alinya 巨乳AI女神异世沦陷</title>
          <iframe id="video" src="/embed/949931.html" allowfullscreen></iframe>
        ''',
        embedUrl: '''
          <div id="dplayer"></div>
          <script>const url = 'https://2609.dadi2026.com/20261121/RzacvWcE/index.m3u8';
          const dp = new DPlayer({ container: document.getElementById('dplayer'),
            video: { url: url, type: 'auto' } });</script>
        ''',
      }).getVideoDetail(qinav, pageUrl);
      expect(detail.title, 'VAIAV-009 Alinya 巨乳AI女神异世沦陷');
      expect(
        detail.streams.map((s) => s.url),
        contains('https://2609.dadi2026.com/20261121/RzacvWcE/index.m3u8'),
      );
    });
  });

  group('啪啪啦 papalah（自研 CMS）', () {
    test('列表：v/{id}/{slug} 卡（标题取自 slug 解码）', () async {
      const html = '''
        <div class="row">
        <div class="col-md-3 col-xs-6 item"><a href="v/109240/%E6%B7%AB%E6%B0%B4%E9%83%BD%E5%99%B4%E5%88%B0%E5%98%B4%E8%A3%8F%E4%BA%86" data-id="1261806" title=""><div class="v-thumb-outer"><span class="btn-watch-later" data-id="109240" data-thumb="https://cdn.papalah.com/uploads/85/85b6bdf849502e98805ff84475571735.jpg" data-duration="03:58" title="稍後觀看"><i class="fa fa-clock-o"></i></span><picture class="v-thumb"><img class="v-thumb" src="https://cdn.papalah.com/uploads/85/85b6bdf849502e98805ff84475571735.jpg" fetchpriority="high" alt="" title="" /></picture><div class="v-duration">03:58</div></div></a><a href="v/109240/%E6%B7%AB%E6%B0%B4%E9%83%BD%E5%99%B4%E5%88%B0%E5%98%B4%E8%A3%8F%E4%BA%86" data-id="1261806" title=""><div class="v-name"></div></a></div>
        <div class="col-md-3 col-xs-6 item"><a href="v/109242/%E6%83%85%E4%BE%B6%E9%96%8B%E6%88%BF%E8%87%AA%E6%8B%8D" data-id="1261808" title=""><div class="v-thumb-outer"><span class="btn-watch-later" data-id="109242" data-thumb="https://cdn.papalah.com/uploads/39/39454ceaabdc8d970e36a370c60b1764.jpg" data-duration="02:34" title="稍後觀看"><i class="fa fa-clock-o"></i></span><picture class="v-thumb"><img class="v-thumb" src="https://cdn.papalah.com/uploads/39/39454ceaabdc8d970e36a370c60b1764.jpg" fetchpriority="high" alt="" title="" /></picture><div class="v-duration">02:34</div></div></a><a href="v/109242/%E6%83%85%E4%BE%B6%E9%96%8B%E6%88%BF%E8%87%AA%E6%8B%8D" data-id="1261808" title=""><div class="v-name"></div></a></div>
        </div>
      ''';
      final items = await apiWith({
        'https://www.papalah.com/': html,
      }).fetchFeed(papalah, tagId: 'new', page: 1);

      expect(items.length, 2);
      expect(
        items.first.url,
        'https://www.papalah.com/v/109240/%E6%B7%AB%E6%B0%B4%E9%83%BD%E5%99%B4%E5%88%B0%E5%98%B4%E8%A3%8F%E4%BA%86',
      );
      expect(items.first.title, '淫水都噴到嘴裏了');
      expect(
        items.first.thumb,
        'https://cdn.papalah.com/uploads/85/85b6bdf849502e98805ff84475571735.jpg',
      );
      expect(items.first.duration, '3:58');
    });

    test('详情：混淆 JS 块解出 media.sslah.com mp4 直链', () async {
      const pageUrl = 'https://www.papalah.com/v/109243/';
      const html = '''
        <title>啪啪啦</title>
        <meta content="淫水都噴到嘴裏了" property="og:title">
        <video id="my-video" class="video-js" controls poster="https://cdn.papalah.com/uploads/ba/bad33863b73252d577bae54bce2da663.webp"><source src="" type="video/mp4"></video>
        <script>
        window.ppScrubBases = ["https://cdn.papalah.com/scrub/57/57d20a57ac2481f9a0a2bbbaa51261ce"];
        (function(){
        const _09d0bf5f = ["1261ce.m","%2F%2Fme","h.com%2F","a2bbbaa5","2481f9a0","d20a57ac","videos%2","dia.ssla","0","p4_4e1ef","https%3A","F57%2F57"];
        const _f7e6512c = [9,1,3,8,7,6,4,2,11,10,0,5];
        let _ff956dde = '';
        for (let _b2b9ff34 = 0; _b2b9ff34 < _f7e6512c.length; _b2b9ff34++) {
            _ff956dde += _09d0bf5f[_f7e6512c.indexOf(_b2b9ff34)];
        }
        let _5add5872 = decodeURIComponent(_ff956dde);
        _5add5872 = _5add5872.replace('_4e1ef0', '');
        const v = document.getElementById('my-video');
        v.querySelector('source').src = _5add5872;
        })();
        </script>
      ''';
      final detail = await apiWith({pageUrl: html}).getVideoDetail(papalah, pageUrl);
      expect(detail.title, '淫水都噴到嘴裏了');
      expect(
        detail.streams.map((s) => s.url),
        contains('https://media.sslah.com/videos/57/57d20a57ac2481f9a0a2bbbaa51261ce.mp4'),
      );
    });
  });

  group('fangsung（自研 PHP + Plyr/HLS）', () {
    test('列表：col-md-3 包裹卡（<a> 在前、alt 标题、data-src 缩略图）', () async {
      const html = '''
        <div class="row">
        <div class="col-md-3 mb-4"><a target="_blank" href="https://www.fangsung.com/a片/日本精品/古い-ニューちゃん完堕ち編01/226796"><div class="card bg-dark text-light h-100"><img data-src="https://cdn52.apianmeng.com/kk55/animate/2026-11-25/2026112535.jpg" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" class="card-img-top lazy" alt="古い-ニューちゃん完堕ち編01-成人動畫" loading="lazy" width="300" height="200"><div class="card-body"><h5 class="card-title">古い-ニューちゃん完堕ち編01-成人動畫</h5></div></div></a></div>
        <div class="col-md-3 mb-4"><a target="_blank" href="https://www.fangsung.com/a片/226795/古い-この枷つけたまま"><div class="card bg-dark text-light h-100"><img data-src="https://cdn52.apianmeng.com/kk55/animate/2026-11-25/2026112534.jpg" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7" class="card-img-top lazy" alt="古い-この枷つけたままお尻突き出した" loading="lazy" width="300" height="200"><div class="card-body"><h5 class="card-title">古い-この枷つけたままお尻突き出した</h5></div></div></a></div>
        </div>
      ''';
      final items = await apiWith({
        'https://www.fangsung.com/a%E7%89%87/11/search/all?page=1': html,
      }).fetchFeed(fangsung, tagId: 'new', page: 1);

      expect(items.length, 2);
      expect(
        items.first.url,
        'https://www.fangsung.com/a片/日本精品/古い-ニューちゃん完堕ち編01/226796',
      );
      expect(items.first.title, '古い-ニューちゃん完堕ち編01-成人動畫');
      expect(
        items.first.thumb,
        'https://cdn52.apianmeng.com/kk55/animate/2026-11-25/2026112535.jpg',
      );
    });

    test('详情：var source 明文 m3u8', () async {
      // 页面路径含中文（a片/标题），dio/Uri 会按段编码——fixture 键与
      // pageUrl 统一用预编码形态（运行时传入原始中文等价）。
      const pageUrl =
          'https://www.fangsung.com/a%E7%89%87/226796/%E5%8F%A4%E3%81%84';
      const html = '''
        <title>古い-ニューちゃん完堕ち編01</title>
        <script>var source = "https://bbcdn.xianshipian.com/animate/2026-11-26/2026112516/video.m3u8";
        var hls = null; var player = null;</script>
      ''';
      final detail = await apiWith({pageUrl: html}).getVideoDetail(fangsung, pageUrl);
      expect(detail.title, '古い-ニューちゃん完堕ち編01');
      expect(
        detail.streams.map((s) => s.url),
        contains('https://bbcdn.xianshipian.com/animate/2026-11-26/2026112516/video.m3u8'),
      );
    });
  });
}

class _MapAdapter implements HttpClientAdapter {
  _MapAdapter(this.fixtures);

  final Map<String, String> fixtures;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = fixtures[options.uri.toString()];
    if (body == null) {
      return ResponseBody.fromString('not found', 404);
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: const {
        'content-type': ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
