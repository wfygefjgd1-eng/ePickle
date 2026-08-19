import 'package:flutter/material.dart';

import '../models/feed_kind.dart';

/// Built-in site directory. Adapters fill data later; PH / X / zhong already wired.
enum SiteKind { video, live }

class SiteTag {
  const SiteTag({
    required this.id,
    required this.label,
    this.feedKind,
    this.icon = Icons.local_fire_department_outlined,
    this.iconSelected = Icons.local_fire_department,
  });

  final String id;
  final String label;
  final VideoFeedKind? feedKind;
  final IconData icon;
  final IconData iconSelected;
}

class SiteDef {
  const SiteDef({
    required this.id,
    required this.name,
    required this.kind,
    required this.tags,
    required this.color,
    required this.letter,
    this.mirrors = const [],
    this.searchable = true,
    this.ready = true,
    this.custom = false,
    this.directoryTags = const [],
    this.parserId,
  });

  final String id;
  final String name;
  final SiteKind kind;
  final List<SiteTag> tags;
  final int color;
  final String letter;
  final List<String> mirrors;
  final bool searchable;
  final bool ready;
  final bool custom;
  final List<SiteTag> directoryTags;
  /// Adapter used by the generic parser for user-added sites.
  final String? parserId;

  bool get isStripchat => id == 'stripchat' || parserId == 'stripchat';
  bool get isChaturbate => id == 'chaturbate' || parserId == 'chaturbate';

  String get primaryHost =>
      mirrors.isNotEmpty ? mirrors.first : 'https://example.com';

  factory SiteDef.customFromUrl(String url, {String parserId = 'generic_vod'}) {
    final u = url.trim().replaceAll(RegExp(r'/$'), '');
    final uri = Uri.tryParse(u);
    final host = uri?.host ?? u;
    final displayName = uri == null
        ? host
        : '${uri.authority}${uri.path == '/' ? '' : uri.path}';
    final letter = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    return SiteDef(
      id: 'custom_${parserId}_${Uri.encodeComponent(u)}',
      name: displayName,
      kind: parserId == 'stripchat' || parserId == 'chaturbate'
          ? SiteKind.live
          : SiteKind.video,
      color: 0xFF607D8B,
      letter: letter,
      mirrors: [u.startsWith('http') ? u : 'https://$u'],
      tags: switch (parserId) {
        'stripchat' => SourceCatalog.stripchatTags,
        'chaturbate' => SourceCatalog.chaturbateTags,
        'pornhub' => SourceCatalog.pornhub.tags,
        'xvideos' => SourceCatalog.xvideos.tags,
        'mitao' => SourceCatalog.mitao.tags,
        'huangguo' => SourceCatalog.huangguoTags,
        _ => SourceCatalog.vodTags,
      },
      directoryTags: switch (parserId) {
        'stripchat' => SourceCatalog.stripchatDirectoryTags,
        'chaturbate' => SourceCatalog.chaturbateDirectoryTags,
        'huangguo' => SourceCatalog.huangguoDirectoryTags,
        _ => SourceCatalog.vodDirectoryTags,
      },
      ready: true,
      custom: true,
      parserId: parserId,
    );
  }
}

class SourceCatalog {
  SourceCatalog._();

  // Chinese short labels via \u escapes (avoid file encoding breakage).
  static const vodTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  static const liveTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asia',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'tag',
      label: '\u6807',
      icon: Icons.sell_outlined,
      iconSelected: Icons.sell,
    ),
  ];

  static const chaturbateTags = <SiteTag>[
    SiteTag(
        id: 'female',
        label: '\u5973',
        icon: Icons.woman_outlined,
        iconSelected: Icons.woman),
    SiteTag(
        id: 'couples',
        label: '\u4f34',
        icon: Icons.people_outline,
        iconSelected: Icons.people),
    SiteTag(
        id: 'new',
        label: '\u65b0',
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new),
    SiteTag(
        id: 'asian',
        label: '\u4e9a',
        icon: Icons.public_outlined,
        iconSelected: Icons.public),
  ];

  /// Stripchat 目录标签：models API 的 primaryTag 仅接受性别组（girls/couples/men/trans）。
  static const stripchatDirectoryTags = <SiteTag>[
    SiteTag(id: 'girls', label: '\u5973\u4e3b\u64ad', icon: Icons.woman_outlined, iconSelected: Icons.woman),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'men', label: '\u7537\u4e3b\u64ad', icon: Icons.man_outlined, iconSelected: Icons.man),
    SiteTag(id: 'trans', label: '\u8de8\u6027\u522b', icon: Icons.diversity_3_outlined, iconSelected: Icons.diversity_3),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'popular', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'more', label: '\u66f4\u591a', icon: Icons.more_horiz_outlined, iconSelected: Icons.more_horiz),
  ];

  /// Chaturbate 目录标签：room-list API 支持 genders 与任意话题 tags。
  static const chaturbateDirectoryTags = <SiteTag>[
    SiteTag(id: 'female', label: '\u5973\u4e3b\u64ad', icon: Icons.woman_outlined, iconSelected: Icons.woman),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'male', label: '\u7537\u4e3b\u64ad', icon: Icons.man_outlined, iconSelected: Icons.man),
    SiteTag(id: 'trans', label: '\u8de8\u6027\u522b', icon: Icons.diversity_3_outlined, iconSelected: Icons.diversity_3),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'petite', label: '\u5c0f\u5de7', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'bbw', label: '\u80a5\u5a46', icon: Icons.sensor_occupied_outlined, iconSelected: Icons.sensor_occupied),
    SiteTag(id: 'chubby', label: '\u5fae\u80d6', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'outdoor', label: '\u6237\u5916', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  static const vodDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'couples', label: '\u60c5\u4fa3', icon: Icons.people_outline, iconSelected: Icons.people),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'popular', label: '\u4eba\u6c14', icon: Icons.trending_up_outlined, iconSelected: Icons.trending_up),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'office', label: '\u804c\u573a', icon: Icons.business_center_outlined, iconSelected: Icons.business_center),
    SiteTag(id: 'uniform', label: '\u5236\u670d', icon: Icons.checkroom_outlined, iconSelected: Icons.checkroom),
    SiteTag(id: 'story', label: '\u5267\u60c5', icon: Icons.movie_outlined, iconSelected: Icons.movie),
    SiteTag(id: 'short', label: '\u77ed\u7247', icon: Icons.timelapse_outlined, iconSelected: Icons.timelapse),
    SiteTag(id: 'long', label: '\u957f\u7247', icon: Icons.schedule_outlined, iconSelected: Icons.schedule),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
    SiteTag(id: 'trending', label: '\u8d8b\u52bf', icon: Icons.whatshot_outlined, iconSelected: Icons.whatshot),
  ];

  /// Pornhub 目录标签：来自 Pornhub 官方分类列表（webmasters API）。
  /// 热门/精选/亚洲直连 API，其余按分类词搜索。
  static const pornhubDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'big-dick', label: '\u5de8\u8e22', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'small-tits', label: '\u5e73\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'red-head', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'handjob', label: '\u6253\u98de\u673a', icon: Icons.back_hand_outlined, iconSelected: Icons.back_hand),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.ac_unit_outlined, iconSelected: Icons.ac_unit),
    SiteTag(id: 'french', label: '\u6cd5\u56fd', icon: Icons.local_cafe_outlined, iconSelected: Icons.local_cafe),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'pov', label: '\u4e3b\u89c2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u59a8', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'fetish', label: '\u60c5\u8da3', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'cosplay', label: '\u89d2\u8272', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'celebrity', label: '\u660e\u661f', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'casting', label: '\u9009\u89d2', icon: Icons.movie_filter_outlined, iconSelected: Icons.movie_filter),
    SiteTag(id: 'college', label: '\u5b66\u751f', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'webcam', label: '\u6444\u50cf\u5934', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'vr', label: 'VR', icon: Icons.view_in_ar_outlined, iconSelected: Icons.view_in_ar),
    SiteTag(id: 'vintage', label: '\u53e4\u5178', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'transgender', label: '\u8de8\u6027', icon: Icons.diversity_3_outlined, iconSelected: Icons.diversity_3),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  /// XVideos 目录标签：来自 XVideos 官方标签页（/tags，2025 个标签中挑选主分类）。
  /// 热门/精选直连 API，其余按标签搜索（/?k=）。
  static const xvideosDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'facial', label: '\u8138\u90e8\u5c04', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'pov', label: '\u4e3b\u89c2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u59a8', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'feet', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'fetish', label: '\u60c5\u8da3', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5e73\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.ac_unit_outlined, iconSelected: Icons.ac_unit),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'solo-female', label: '\u72ec\u6f14', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'solo-male', label: '\u7537\u6f14', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'vintage', label: '\u53e4\u5178', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'webcam', label: '\u6444\u50cf\u5934', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  /// Mitao（龙猫视频）目录标签：来自站内真实分类（type id 1-5）+ 热门搜索词。
  static const mitaoDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: '\u56fd\u4ea7\u7cbe\u54c1', label: '\u56fd\u4ea7\u7cbe\u54c1', icon: Icons.home_outlined, iconSelected: Icons.home),
    SiteTag(id: '\u4e2d\u6587\u5b57\u5e55', label: '\u4e2d\u6587\u5b57\u5e55', icon: Icons.subtitles_outlined, iconSelected: Icons.subtitles),
    SiteTag(id: '\u5f3a\u5978\u4e71\u4f26', label: '\u5f3a\u5978\u4e71\u4f26', icon: Icons.warning_outlined, iconSelected: Icons.warning),
    SiteTag(id: '\u53cd\u5dee\u5973\u53cb', label: '\u53cd\u5dee\u5973\u53cb', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: '\u6559\u5e08\u5b66\u751f', label: '\u6559\u5e08\u5b66\u751f', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: '\u4e9a\u6d32', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: '\u65e5\u672c', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: '\u7d20\u4eba', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
  ];

  /// XNXX 目录标签：来自 XNXX 官方标签页（/tags 与 /search，1998 个标签中挑选主分类）。
  /// 走 /tags/{name}/ 或 /search/{name}/。
  static const xnxxDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'korean', label: '\u97e9\u56fd', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'pov', label: '\u4e3b\u89c2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u59a8', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'facial', label: '\u8138\u5c04', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'feet', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'fetish', label: '\u60c5\u8da3', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5e73\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.ac_unit_outlined, iconSelected: Icons.ac_unit),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'pornstar', label: '\u4f18\u7ea7', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'casting', label: '\u9009\u89d2', icon: Icons.movie_filter_outlined, iconSelected: Icons.movie_filter),
    SiteTag(id: 'college', label: '\u5b66\u751f', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'compilation', label: '\u5408\u96c6', icon: Icons.video_library_outlined, iconSelected: Icons.video_library),
    SiteTag(id: 'reality', label: '\u771f\u4eba', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'vintage', label: '\u53e4\u5178', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  /// xHamster 目录标签：来自 xHamster 官方分类页（/categories，654 个分类中挑选主分类）。
  /// 走 /categories/{name}/。
  static const xhamsterDirectoryTags = <SiteTag>[
    SiteTag(id: 'hot', label: '\u70ed\u95e8', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'jav', label: 'JAV', icon: Icons.movie_outlined, iconSelected: Icons.movie),
    SiteTag(id: 'chinese', label: '\u4e2d\u6587', icon: Icons.translate_outlined, iconSelected: Icons.translate),
    SiteTag(id: 'thai', label: '\u6cf0\u56fd', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'vietnamese', label: '\u8d8a\u5357', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'filipina', label: '\u83f2\u5f8b\u5bbe', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'homemade', label: '\u5bb6\u5ead', icon: Icons.home_outlined, iconSelected: Icons.home),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'black', label: '\u9ed1\u4eba', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'pov', label: '\u4e3b\u89c2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u59a8', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'group-sex', label: '\u7fa4\u4f53', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'squirting', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'fetish', label: '\u60c5\u8da3', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'bdsm', label: 'BDSM', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5e73\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'wife', label: '\u4eba\u59bb', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'female-masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'sex-toy', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'stockings', label: '\u4e1d\u889c', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'lingerie', label: '\u60c5\u8da3', icon: Icons.checkroom_outlined, iconSelected: Icons.checkroom),
    SiteTag(id: 'pregnant', label: '\u5b55\u5987', icon: Icons.pregnant_woman_outlined, iconSelected: Icons.pregnant_woman),
    SiteTag(id: 'deep-throat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'foot-fetish', label: '\u8db3\u63a7', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'footjob', label: '\u811a\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'interracial', label: '\u8de8\u79cd', icon: Icons.interpreter_mode_outlined, iconSelected: Icons.interpreter_mode),
    SiteTag(id: 'casting', label: '\u9009\u89d2', icon: Icons.movie_filter_outlined, iconSelected: Icons.movie_filter),
    SiteTag(id: 'pornstar', label: '\u4f18\u7ea7', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'teen', label: '\u5c11\u5973', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'college', label: '\u5b66\u751f', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'vintage', label: '\u53e4\u5178', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
  ];

  /// TNAFlix 目录标签：来自 TNAFlix 搜索/分类（/search.php?what= 与 /categories/）。
  static const tnaflixDirectoryTags = <SiteTag>[
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'hot', label: '\u63a8\u8350', icon: Icons.recommend_outlined, iconSelected: Icons.recommend),
    SiteTag(id: 'asian', label: '\u4e9a\u6d32', icon: Icons.public_outlined, iconSelected: Icons.public),
    SiteTag(id: 'japanese', label: '\u65e5\u672c', icon: Icons.flag_outlined, iconSelected: Icons.flag),
    SiteTag(id: 'amateur', label: '\u7d20\u4eba', icon: Icons.camera_alt_outlined, iconSelected: Icons.camera_alt),
    SiteTag(id: 'milf', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'mature', label: '\u6210\u719f', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'anal', label: '\u540e\u5ead', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'creampie', label: '\u5185\u5c04', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'cumshot', label: '\u989c\u5c04', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'lesbian', label: '\u540c\u6027', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'ebony', label: '\u9ed1\u73e0', icon: Icons.nightlife_outlined, iconSelected: Icons.nightlife),
    SiteTag(id: 'latina', label: '\u62c9\u7f8e', icon: Icons.language_outlined, iconSelected: Icons.language),
    SiteTag(id: 'hentai', label: '\u52a8\u6f2b', icon: Icons.animation_outlined, iconSelected: Icons.animation),
    SiteTag(id: 'cartoon', label: '\u5361\u901a', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'pov', label: '\u4e3b\u89c2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'threesome', label: '3P', icon: Icons.groups_outlined, iconSelected: Icons.groups),
    SiteTag(id: 'orgy', label: '\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'gangbang', label: '\u8f6e\u59a8', icon: Icons.groups_3_outlined, iconSelected: Icons.groups_3),
    SiteTag(id: 'squirt', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'fetish', label: '\u60c5\u8da3', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'big-ass', label: '\u5de8\u81c0', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u5e73\u80f8', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'blonde', label: '\u91d1\u53d1', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'brunette', label: '\u68d5\u53d1', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'redhead', label: '\u7ea2\u53d1', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'russian', label: '\u4fc4\u7f57\u65af', icon: Icons.ac_unit_outlined, iconSelected: Icons.ac_unit),
    SiteTag(id: 'indian', label: '\u5370\u5ea6', icon: Icons.history_edu_outlined, iconSelected: Icons.history_edu),
    SiteTag(id: 'fisting', label: '\u62f3\u4ea4', icon: Icons.front_hand_outlined, iconSelected: Icons.front_hand),
    SiteTag(id: 'handjob', label: '\u6253\u98de\u673a', icon: Icons.back_hand_outlined, iconSelected: Icons.back_hand),
    SiteTag(id: 'masturbation', label: '\u81ea\u6170', icon: Icons.self_improvement_outlined, iconSelected: Icons.self_improvement),
    SiteTag(id: 'toys', label: '\u73a9\u5177', icon: Icons.toys_outlined, iconSelected: Icons.toys),
    SiteTag(id: 'vintage', label: '\u53e4\u5178', icon: Icons.hourglass_bottom_outlined, iconSelected: Icons.hourglass_bottom),
    SiteTag(id: 'hd', label: '\u9ad8\u6e05', icon: Icons.hd_outlined, iconSelected: Icons.hd),
  ];

  /// Jable 目录标签：来自 Jable.TV 官方分类与主题页（/categories 与 /tags）。
  static const jableDirectoryTags = <SiteTag>[
    SiteTag(id: 'new', label: '\u6700\u65b0', icon: Icons.fiber_new_outlined, iconSelected: Icons.fiber_new),
    SiteTag(id: 'hot', label: '\u70ed\u5ea6', icon: Icons.local_fire_department_outlined, iconSelected: Icons.local_fire_department),
    SiteTag(id: 'best', label: '\u7cbe\u9009', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
    SiteTag(id: 'chinese-subtitle', label: '\u4e2d\u6587\u5b57\u5e55', icon: Icons.subtitles_outlined, iconSelected: Icons.subtitles),
    SiteTag(id: 'uncensored', label: '\u65e0\u7801', icon: Icons.no_photography_outlined, iconSelected: Icons.no_photography),
    SiteTag(id: 'sex-only', label: '\u76f4\u63a5\u5f00\u62cd', icon: Icons.flash_on_outlined, iconSelected: Icons.flash_on),
    SiteTag(id: 'roleplay', label: '\u89d2\u8272\u5267\u60c5', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'uniform', label: '\u5236\u670d\u8bf1\u60d1', icon: Icons.checkroom_outlined, iconSelected: Icons.checkroom),
    SiteTag(id: 'bdsm', label: '\u4e3b\u5974\u8c03\u6559', icon: Icons.health_and_safety_outlined, iconSelected: Icons.health_and_safety),
    SiteTag(id: 'insult', label: '\u51cc\u8fb1\u5feb\u611f', icon: Icons.warning_outlined, iconSelected: Icons.warning),
    SiteTag(id: 'pov', label: '\u7537\u53cb\u89c6\u89d2', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'groupsex', label: '\u591aP\u7fa4\u4ea4', icon: Icons.groups_2_outlined, iconSelected: Icons.groups_2),
    SiteTag(id: 'pantyhose', label: '\u4e1d\u889c\u7f8e\u817f', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'lesbian', label: '\u5973\u540c\u6b22\u6109', icon: Icons.favorite_outline, iconSelected: Icons.favorite),
    SiteTag(id: 'private-cam', label: '\u76d7\u6444\u5077\u62cd', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'wife', label: '\u4eba\u59bb', icon: Icons.pregnant_woman_outlined, iconSelected: Icons.pregnant_woman),
    SiteTag(id: 'mature-woman', label: '\u719f\u5973', icon: Icons.person_outline, iconSelected: Icons.person),
    SiteTag(id: 'girl', label: '\u5c11\u5973', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'big-tits', label: '\u5de8\u4e73', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'small-tits', label: '\u8d2b\u4e73', icon: Icons.child_care_outlined, iconSelected: Icons.child_care),
    SiteTag(id: 'beautiful-butt', label: '\u7f8e\u5c3b', icon: Icons.airline_seat_legroom_reduced_outlined, iconSelected: Icons.airline_seat_legroom_reduced),
    SiteTag(id: 'beautiful-leg', label: '\u7f8e\u817f', icon: Icons.accessibility_new_outlined, iconSelected: Icons.accessibility_new),
    SiteTag(id: 'creampie', label: '\u4e2d\u51fa', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'anal-sex', label: '\u809b\u4ea4', icon: Icons.airline_seat_recline_normal_outlined, iconSelected: Icons.airline_seat_recline_normal),
    SiteTag(id: 'blowjob', label: '\u53e3\u4ea4', icon: Icons.mic_external_on_outlined, iconSelected: Icons.mic_external_on),
    SiteTag(id: 'deep-throat', label: '\u6df1\u54bd', icon: Icons.vpn_key_outlined, iconSelected: Icons.vpn_key),
    SiteTag(id: 'cum-in-mouth', label: '\u53e3\u7206', icon: Icons.blur_on_outlined, iconSelected: Icons.blur_on),
    SiteTag(id: 'facial', label: '\u989c\u5c04', icon: Icons.face_outlined, iconSelected: Icons.face),
    SiteTag(id: 'footjob', label: '\u811a\u4ea4', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'squirting', label: '\u6f6e\u5439', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'school-uniform', label: '\u6821\u670d', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'maid', label: '\u5973\u4ec6', icon: Icons.cleaning_services_outlined, iconSelected: Icons.cleaning_services),
    SiteTag(id: 'kimono', label: '\u548c\u670d', icon: Icons.dry_cleaning_outlined, iconSelected: Icons.dry_cleaning),
    SiteTag(id: 'stockings', label: '\u540a\u5e26\u889c', icon: Icons.ice_skating_outlined, iconSelected: Icons.ice_skating),
    SiteTag(id: 'glasses', label: '\u773c\u955c\u5a18', icon: Icons.visibility_outlined, iconSelected: Icons.visibility),
    SiteTag(id: 'cosplay', label: 'Cosplay', icon: Icons.theater_comedy_outlined, iconSelected: Icons.theater_comedy),
    SiteTag(id: 'bondage', label: '\u7f1a\u7ed1', icon: Icons.link_outlined, iconSelected: Icons.link),
    SiteTag(id: 'tune', label: '\u8c03\u6559', icon: Icons.tune_outlined, iconSelected: Icons.tune),
    SiteTag(id: 'chizyo', label: '\u75f4\u5973', icon: Icons.face_3_outlined, iconSelected: Icons.face_3),
    SiteTag(id: 'chikan', label: '\u75f4\u6c49', icon: Icons.train_outlined, iconSelected: Icons.train),
    SiteTag(id: 'outdoor', label: '\u9732\u51fa', icon: Icons.landscape_outlined, iconSelected: Icons.landscape),
    SiteTag(id: 'soapland', label: '\u6ce1\u59ec', icon: Icons.bubble_chart_outlined, iconSelected: Icons.bubble_chart),
    SiteTag(id: 'massage', label: '\u6309\u6469', icon: Icons.spa_outlined, iconSelected: Icons.spa),
    SiteTag(id: 'temptation', label: '\u8bf1\u60d1', icon: Icons.auto_awesome_outlined, iconSelected: Icons.auto_awesome),
    SiteTag(id: 'ntr', label: 'NTR', icon: Icons.person_off_outlined, iconSelected: Icons.person_off),
    SiteTag(id: 'hypnosis', label: '\u50ac\u7720', icon: Icons.psychology_outlined, iconSelected: Icons.psychology),
    SiteTag(id: 'affair', label: '\u51fa\u8f68', icon: Icons.heart_broken_outlined, iconSelected: Icons.heart_broken),
    SiteTag(id: 'time-stop', label: '\u65f6\u95f4\u505c\u6b62', icon: Icons.timer_off_outlined, iconSelected: Icons.timer_off),
    SiteTag(id: 'doctor', label: '\u533b\u751f', icon: Icons.medical_services_outlined, iconSelected: Icons.medical_services),
    SiteTag(id: 'nurse', label: '\u62a4\u58eb', icon: Icons.medical_services_outlined, iconSelected: Icons.medical_services),
    SiteTag(id: 'teacher', label: '\u8001\u5e08', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'ol', label: 'OL', icon: Icons.business_center_outlined, iconSelected: Icons.business_center),
    SiteTag(id: 'idol', label: '\u5076\u50cf', icon: Icons.star_outline, iconSelected: Icons.star),
    SiteTag(id: 'hot-spring', label: '\u6e29\u6cc9', icon: Icons.hot_tub_outlined, iconSelected: Icons.hot_tub),
    SiteTag(id: 'swimming-pool', label: '\u6cf3\u6c60', icon: Icons.pool_outlined, iconSelected: Icons.pool),
    SiteTag(id: 'car', label: '\u6c7d\u8f66', icon: Icons.directions_car_outlined, iconSelected: Icons.directions_car),
    SiteTag(id: 'tram', label: '\u7535\u8f66', icon: Icons.train_outlined, iconSelected: Icons.train),
    SiteTag(id: 'school', label: '\u5b66\u6821', icon: Icons.school_outlined, iconSelected: Icons.school),
    SiteTag(id: 'gym-room', label: '\u5065\u8eab\u623f', icon: Icons.fitness_center_outlined, iconSelected: Icons.fitness_center),
    SiteTag(id: 'hotel', label: '\u9152\u5e97', icon: Icons.hotel_outlined, iconSelected: Icons.hotel),
    SiteTag(id: 'hairy', label: '\u591a\u6bdb', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'suntan', label: '\u9ed1\u8089', icon: Icons.wb_sunny_outlined, iconSelected: Icons.wb_sunny),
    SiteTag(id: 'tattoo', label: '\u7eb9\u8eab', icon: Icons.brush_outlined, iconSelected: Icons.brush),
    SiteTag(id: 'breast-milk', label: '\u6bcd\u4e73', icon: Icons.water_drop_outlined, iconSelected: Icons.water_drop),
    SiteTag(id: 'piss', label: '\u653e\u5c3f', icon: Icons.water_outlined, iconSelected: Icons.water),
    SiteTag(id: 'video-recording', label: '\u5f55\u50cf', icon: Icons.videocam_outlined, iconSelected: Icons.videocam),
    SiteTag(id: 'more-than-4-hours', label: '4\u5c0f\u65f6\u4ee5\u4e0a', icon: Icons.schedule_outlined, iconSelected: Icons.schedule),
  ];

  static const stripchatTags = <SiteTag>[
    SiteTag(
        id: 'girls',
        label: '\u5973',
        icon: Icons.woman_outlined,
        iconSelected: Icons.woman),
    SiteTag(
        id: 'new',
        label: '\u65b0',
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new),
    SiteTag(
        id: 'couples',
        label: '\u4f34',
        icon: Icons.people_outline,
        iconSelected: Icons.people),
    SiteTag(
        id: 'more',
        label: '\u4e9a',
        icon: Icons.public_outlined,
        iconSelected: Icons.public),
  ];

  static const xvideosTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      feedKind: VideoFeedKind.x,
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      feedKind: VideoFeedKind.x,
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      feedKind: VideoFeedKind.x,
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      feedKind: VideoFeedKind.x,
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  /// XNXX 独有标签：热(hits)/新(search-new)/亚(?k=asian)/榜(best)。
  static const xnxxTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  /// xHamster 独有标签：热(hottest)/新(newest)/日(japanese)/亚(categories/asian)。
  static const xhamsterTags = <SiteTag>[
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'japanese',
      label: '\u65e5',
      icon: Icons.flag_outlined,
      iconSelected: Icons.flag,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
  ];

  /// TNAFlix 独有标签：新(new)/榜(toprated)/推(popular home)/亚(search asian)。
  static const tnaflixTags = <SiteTag>[
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
    SiteTag(
      id: 'hot',
      label: '\u63a8',
      icon: Icons.recommend_outlined,
      iconSelected: Icons.recommend,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e9a',
      icon: Icons.public_outlined,
      iconSelected: Icons.public,
    ),
  ];

  /// Jable 独有标签：新(latest-updates)/热(hot)/中(categories/chinese-subtitle)/榜(best→hot 精选)。
  static const jableTags = <SiteTag>[
    SiteTag(
      id: 'new',
      label: '\u65b0',
      icon: Icons.fiber_new_outlined,
      iconSelected: Icons.fiber_new,
    ),
    SiteTag(
      id: 'hot',
      label: '\u70ed',
      icon: Icons.local_fire_department_outlined,
      iconSelected: Icons.local_fire_department,
    ),
    SiteTag(
      id: 'asian',
      label: '\u4e2d',
      icon: Icons.subtitles_outlined,
      iconSelected: Icons.subtitles,
    ),
    SiteTag(
      id: 'best',
      label: '\u699c',
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
  ];

  static const pornhub = SiteDef(
    id: 'pornhub',
    name: 'Pornhub',
    kind: SiteKind.video,
    color: 0xFFFF9000,
    letter: 'P',
    mirrors: [
      'https://www.pornhub.com',
      'https://www.pornhub.org',
      'https://cn.pornhub.com',
      'https://rt.pornhub.com',
      'https://de.pornhub.com',
      'https://fr.pornhub.com',
    ],
    tags: [
      SiteTag(
        id: 'hot',
        label: '\u70ed',
        feedKind: VideoFeedKind.hot,
        icon: Icons.local_fire_department_outlined,
        iconSelected: Icons.local_fire_department,
      ),
      SiteTag(
        id: 'asian',
        label: '\u4e9a',
        feedKind: VideoFeedKind.asian,
        icon: Icons.public_outlined,
        iconSelected: Icons.public,
      ),
      SiteTag(
        id: 'new',
        label: '\u65b0',
        feedKind: VideoFeedKind.hot,
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new,
      ),
      SiteTag(
        id: 'rec',
        label: '\u63a8',
        feedKind: VideoFeedKind.hot,
        icon: Icons.recommend_outlined,
        iconSelected: Icons.recommend,
      ),
    ],
    directoryTags: pornhubDirectoryTags,
  );

  static const xvideos = SiteDef(
    id: 'xvideos',
    name: 'XVideos',
    kind: SiteKind.video,
    color: 0xFFC41E3A,
    letter: 'X',
    mirrors: [
      'https://www.xvideos.com',
      'https://www.xvideos.es',
      'https://www.xvideos.net',
    ],
    tags: xvideosTags,
    directoryTags: xvideosDirectoryTags,
  );

  /// 黄果短剧 (huangguoai.com) — 内置规则站，主域名可在设置(黄果规则)修改。
  static const huangguoTags = <SiteTag>[
    SiteTag(
      id: 'duanju',
      label: '\u77ed',
      feedKind: VideoFeedKind.hot,
      icon: Icons.movie_outlined,
      iconSelected: Icons.movie,
    ),
    SiteTag(
      id: 'rank',
      label: '\u699c',
      feedKind: VideoFeedKind.hot,
      icon: Icons.emoji_events_outlined,
      iconSelected: Icons.emoji_events,
    ),
    SiteTag(
      id: 'recommend',
      label: '\u63a8',
      feedKind: VideoFeedKind.hot,
      icon: Icons.recommend_outlined,
      iconSelected: Icons.recommend,
    ),
    SiteTag(
      id: 'topics',
      label: '\u4e13',
      feedKind: VideoFeedKind.hot,
      icon: Icons.collections_bookmark_outlined,
      iconSelected: Icons.collections_bookmark,
    ),
  ];

  static const huangguoDirectoryTags = <SiteTag>[
    SiteTag(id: 'recommend', label: '\u9996\u9875', icon: Icons.home_outlined, iconSelected: Icons.home),
    SiteTag(id: 'duanju', label: 'AI\u77ed\u5267', icon: Icons.movie_outlined, iconSelected: Icons.movie),
    SiteTag(id: 'manju', label: 'AI\u6f2b\u5267', icon: Icons.auto_awesome_outlined, iconSelected: Icons.auto_awesome),
    SiteTag(id: 'huanlian', label: 'AI\u6362\u8138', icon: Icons.face_retouching_natural_outlined, iconSelected: Icons.face_retouching_natural),
    SiteTag(id: 'mogai', label: 'AI\u9b54\u6539', icon: Icons.auto_fix_high_outlined, iconSelected: Icons.auto_fix_high),
    SiteTag(id: 'topics', label: '\u4e13\u9898', icon: Icons.collections_bookmark_outlined, iconSelected: Icons.collections_bookmark),
    SiteTag(id: 'rank', label: '\u6392\u884c\u699c', icon: Icons.emoji_events_outlined, iconSelected: Icons.emoji_events),
  ];

  static const huangguo = SiteDef(
    id: 'huangguo',
    name: '\u9ec4\u679c\u77ed\u5267',
    kind: SiteKind.video,
    color: 0xFFFFD21C,
    letter: 'H',
    mirrors: [
      'https://huangguoai.com',
    ],
    tags: huangguoTags,
    directoryTags: huangguoDirectoryTags,
  );

  static const mitao = SiteDef(
    id: 'mitao',
    name: 'mitaohk.com',
    kind: SiteKind.video,
    color: 0xFFE91E63,
    letter: 'M',
    mirrors: [
      'https://mitaohk.com',
      'https://www.mitaohk.com',
    ],
    tags: [
      SiteTag(
        id: 'hot',
        label: '\u70ed',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.local_fire_department_outlined,
        iconSelected: Icons.local_fire_department,
      ),
      SiteTag(
        id: 'sub',
        label: '\u4e2d',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.subtitles_outlined,
        iconSelected: Icons.subtitles,
      ),
      SiteTag(
        id: 'new',
        label: '\u65b0',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.fiber_new_outlined,
        iconSelected: Icons.fiber_new,
      ),
      SiteTag(
        id: 'rec',
        label: '\u63a8',
        feedKind: VideoFeedKind.zhong,
        icon: Icons.recommend_outlined,
        iconSelected: Icons.recommend,
      ),
    ],
    directoryTags: mitaoDirectoryTags,
  );

  static const xnxx = SiteDef(
    id: 'xnxx',
    name: 'XNXX',
    kind: SiteKind.video,
    color: 0xFF1565C0,
    letter: 'N',
    ready: true,
    mirrors: [
      'https://www.xnxx.com',
      'https://www.xnxx.tv',
      'https://www.xnxx.es',
    ],
    tags: xnxxTags,
    directoryTags: xnxxDirectoryTags,
  );

  static const xhamster = SiteDef(
    id: 'xhamster',
    name: 'xHamster',
    kind: SiteKind.video,
    color: 0xFF6A1B9A,
    letter: 'H',
    ready: true,
    mirrors: [
      'https://xhamster.com',
      'https://xhamster.desi',
      'https://xhamster2.com',
      'https://zh.xhamster.com',
    ],
    tags: xhamsterTags,
    directoryTags: xhamsterDirectoryTags,
  );

  // Removed from catalog (unstable / blocked for most users):
  // eporner, freeporn, spankbang, youporn, redtube, javmix, javgg,
  // av01, missav, 7mmtv, bestjavporn.

  static const tnaflix = SiteDef(
    id: 'tnaflix',
    name: 'TNAFlix',
    kind: SiteKind.video,
    color: 0xFF4A148C,
    letter: 'T',
    ready: true,
    mirrors: [
      'https://www.tnaflix.com',
      'https://tnaflix.com',
    ],
    tags: tnaflixTags,
    directoryTags: tnaflixDirectoryTags,
  );

  static const jable = SiteDef(
    id: 'jable',
    name: 'Jable',
    kind: SiteKind.video,
    color: 0xFF1A237E,
    letter: 'J',
    ready: true,
    mirrors: [
      'https://jable.tv',
      'https://www.jable.tv',
      'https://jable.one',
    ],
    tags: jableTags,
    directoryTags: jableDirectoryTags,
  );

  // Removed: our55, xqq88 (unstable for users).

  static const stripchat = SiteDef(
    id: 'stripchat',
    name: 'Stripchat',
    kind: SiteKind.live,
    color: 0xFFD32F2F,
    letter: 'S',
    searchable: false,
    ready: true,
    mirrors: [
      'https://zh.stripchat.com',
      'https://stripchat.com',
      'https://www.stripchat.com',
      'https://stripchat.global',
      'https://xhamsterlive.com',
    ],
    tags: stripchatTags,
    directoryTags: stripchatDirectoryTags,
  );

  static const chaturbate = SiteDef(
    id: 'chaturbate',
    name: 'Chaturbate',
    kind: SiteKind.live,
    color: 0xFFF57C00,
    letter: 'C',
    searchable: false,
    ready: true,
    mirrors: [
      'https://chaturbate.com',
      'https://www.chaturbate.com',
      'https://zh.chaturbate.com',
      'https://chaturbate.eu',
      'https://chaturbate.global',
    ],
    tags: chaturbateTags,
    directoryTags: chaturbateDirectoryTags,
  );

  static const all = <SiteDef>[
    pornhub,
    xvideos,
    mitao,
    huangguo,
    xnxx,
    xhamster,
    tnaflix,
    jable,
    stripchat,
    chaturbate,
  ];

  static SiteDef? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  static List<SiteDef> get videoSites =>
      all.where((s) => s.kind == SiteKind.video).toList();

  static List<SiteDef> get liveSites =>
      all.where((s) => s.kind == SiteKind.live).toList();

  static List<String> get defaultEnabledVideoIds =>
      videoSites.where((s) => s.ready).map((s) => s.id).toList();

  /// The first three VOD adapters randomize internally. Remaining VOD sites
  /// use generic random pages; live channels must stay ordered and stable.
  static bool usesRandomizedGenericFeed(SiteDef site) =>
      site.kind == SiteKind.video &&
      site.id != 'pornhub' &&
      site.id != 'xvideos' &&
      site.id != 'mitao';

  static const defaultLiveId = 'chaturbate';
}
