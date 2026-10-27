import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/layout_settings.dart';
import 'package:epickle/services/source_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('custom HTTPS URL keeps its explicit port and subpath', () async {
    final settings = LayoutSettings();

    await settings.addCustomUrl('https://fixture.test:8443/catalog/root/');

    expect(
      settings.customUrls,
      ['https://fixture.test:8443/catalog/root'],
    );
    final site = settings.enabledVideoSites.singleWhere((item) => item.custom);
    expect(site.primaryHost, 'https://fixture.test:8443/catalog/root');
    expect(site.id, contains(Uri.encodeComponent(site.primaryHost)));
  });

  test('catalog version bump refreshes stale device lists for new cards',
      () async {
    // 老安装（如 v2.8.39，catalogVer=14）的存储列表缺 iXXX/新聚合站；新代码
    // 版本号更高时 load 必须刷新为默认目录，否则新卡片不可见。
    SharedPreferences.setMockInitialValues({
      'layout_enabled_video_ids_v1': ['pornhub', 'xvideos', 'xnxx'],
      'layout_catalog_ver_v1': 14,
    });
    final settings = LayoutSettings();
    await settings.load();

    expect(
      settings.enabledVideoSites.map((s) => s.id),
      contains('ixxx'),
    );
    expect(
      settings.enabledVideoSites.map((s) => s.id),
      contains('fuq'),
    );
    // 刷新后的列表必须被持久化为高于旧版本的目录号 + 新默认列表。
    final p = await SharedPreferences.getInstance();
    expect(p.getInt('layout_catalog_ver_v1'), greaterThan(14));
    expect(p.getStringList('layout_enabled_video_ids_v1'), contains('ixxx'));
    expect(
      p.getStringList('layout_enabled_video_ids_v1'),
      contains('hotsextube'),
    );
  });

  test('custom URL rejects cleartext HTTP', () async {
    final settings = LayoutSettings();

    await settings.addCustomUrl('http://fixture.test/catalog');

    expect(settings.customUrls, isEmpty);
  });

  test('built-in duplicate detection compares host instead of substrings',
      () async {
    final settings = LayoutSettings();

    await settings.addCustomUrl('https://videos.com');

    expect(settings.customUrls, ['https://videos.com']);
    expect(SourceCatalog.all, isNotEmpty);
  });

  test('hidden sites are removed from home/search sources and persist',
      () async {
    final settings = LayoutSettings();

    await settings.setSiteHidden(SourceCatalog.pornhub, true);

    expect(settings.isSiteHidden(SourceCatalog.pornhub), isTrue);
    expect(
      settings.enabledVideoSites.map((site) => site.id),
      isNot(contains('pornhub')),
    );

    final restored = LayoutSettings();
    await restored.load();
    expect(restored.isSiteHidden(SourceCatalog.pornhub), isTrue);
    expect(
      restored.enabledVideoSites.map((site) => site.id),
      isNot(contains('pornhub')),
    );
  });

  test('hidden live site cannot remain the default live entry', () async {
    final settings = LayoutSettings();

    await settings.setSiteHidden(SourceCatalog.chaturbate, true);

    expect(settings.liveSite?.id, isNot('chaturbate'));
  });

  test('last built-in video site is still refused without a custom fallback',
      () async {
    final settings = LayoutSettings();

    for (final id in settings.enabledVideoIds.where(
      (id) => id != SourceCatalog.pornhub.id,
    ).toList()) {
      expect(await settings.toggleVideoSite(id, false), isTrue);
    }

    expect(
      await settings.toggleVideoSite(SourceCatalog.pornhub.id, false),
      isFalse,
    );
    expect(settings.enabledVideoIds, contains(SourceCatalog.pornhub.id));
  });

  test('last built-in video site can be removed while a custom site remains',
      () async {
    final settings = LayoutSettings();
    // 先跑一次 load() 持久化目录版本号，否则 restored.load() 会把
    // "全新安装"误判成迁移场景并重置启用列表。
    await settings.load();

    await settings.addCustomUrl('https://fixture.test/catalog');
    for (final id in List<String>.from(settings.enabledVideoIds)) {
      expect(await settings.toggleVideoSite(id, false), isTrue);
    }

    expect(settings.enabledVideoIds, isEmpty);
    expect(settings.enabledVideoSites.any((s) => s.custom), isTrue);

    // 空列表必须持久化：重启后内置站不能复活。
    final restored = LayoutSettings();
    await restored.load();
    expect(restored.enabledVideoIds, isEmpty);
    expect(restored.enabledVideoSites.any((s) => s.custom), isTrue);
  });

  test('removal is refused when no visible video site would remain', () async {
    final settings = LayoutSettings();

    for (final id in settings.enabledVideoIds.where(
      (id) => id != SourceCatalog.pornhub.id,
    ).toList()) {
      final site = SourceCatalog.byId(id);
      if (site != null) await settings.setSiteHidden(site, true);
    }

    // 其余站全部隐藏后，可见站只剩 pornhub —— 移除它必须被拒绝。
    expect(
      await settings.toggleVideoSite(SourceCatalog.pornhub.id, false),
      isFalse,
    );
    expect(settings.enabledVideoIds, contains(SourceCatalog.pornhub.id));
  });
}
