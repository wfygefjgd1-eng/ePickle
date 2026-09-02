import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/http_client.dart';
import 'source_catalog.dart' show SiteDef;

/// Per-site mirror ranking: remembers which mirror domain is fastest for the
/// current device/proxy setup and prefers it on every subsequent request.
///
/// Design (agreed with the user):
/// - Lightweight HEAD probes measure time-to-headers per mirror using the same
///   proxy wiring as real requests, so scores reflect the actual network path.
/// - Latency is smoothed with an EWMA: one slow blip cannot dethrone a
///   reliably fast mirror. Two consecutive failures demote a mirror below
///   unknown (unprobed) ones until it recovers.
/// - Rankings persist per platform (iOS/Android proxy setups differ a lot)
///   and are refreshed at most once per [ttl] unless a site has a failure.
/// - Real fetch outcomes (feed/search/keywords) feed the same stats for free,
///   so the ranking keeps learning from live traffic, not just probes.
class MirrorRanker {
  MirrorRanker._();

  static final MirrorRanker instance = MirrorRanker._();

  static const ttl = Duration(minutes: 30);
  static const maxFailureStreak = 2;

  /// Health cap so a recovering-but-flaky mirror still sorts behind stable ones.
  static const _unknownTier = 1e8;
  static const _failingTier = 1e9;

  Dio? _probeDio;
  bool _loaded = false;
  Future<void>? _loading;
  final Map<String, Map<String, _MirrorStats>> _bySite = {};
  Timer? _persistTimer;
  Future<void> _persistTail = Future.value();

  /// Manual base override per site (long-press on a card). Persisted per
  /// platform under [manualStorageKeyFor] so a pinned domain survives app
  /// restarts; the session map is the source of truth while running.
  final Map<String, String> _manualBase = {};

  /// Pin [base] for [siteId] for the rest of this app session. Ignored later
  /// if the base is no longer part of the site's mirror list.
  void setManualBase(String siteId, String base) {
    _manualBase[siteId] = base.replaceAll(RegExp(r'/$'), '');
  }

  /// Back to auto-ranking (fastest known mirror) for [siteId].
  void clearManualBase(String siteId) => _manualBase.remove(siteId);

  /// The session override for [siteId], if any (no trailing slash).
  String? manualBase(String siteId) => _manualBase[siteId];

  /// True when every mirror of [site] (含手动新增域名) has stats and ALL are
  /// in a failure streak — i.e. nothing answered. 没有任何数据的站点不算
  /// down（unknown ≠ dead），避免误伤。
  bool isSiteDown(SiteDef site) {
    final stats = _bySite[site.id];
    if (stats == null || stats.isEmpty) return false;
    final mirrors = <String>[
      ...site.mirrors,
      // 手动覆盖域名健康时不算 down，即使目录镜像全挂。
      if (manualBase(site.id) != null &&
          !site.mirrors.any((m) =>
              m.replaceAll(RegExp(r'/$'), '') == manualBase(site.id)))
        manualBase(site.id)!,
    ];
    if (mirrors.isEmpty) return false;
    for (final raw in mirrors) {
      final st = stats[raw.replaceAll(RegExp(r'/$'), '')];
      if (st == null) return false;
      if (st.failStreak == 0) return false;
    }
    return true;
  }

  /// Pin [base] for [siteId] AND persist it so it survives an app restart.
  /// Best-effort: storage failures are swallowed, the session pin still holds.
  Future<void> setManualBasePersisted(String siteId, String base) async {
    setManualBase(siteId, base);
    await _persistManualBases();
  }

  /// Drop the override for [siteId] AND persist the removal.
  Future<void> clearManualBasePersisted(String siteId) async {
    clearManualBase(siteId);
    await _persistManualBases();
  }

  /// Write the whole current override map as JSON under
  /// [manualStorageKeyFor] (empty map → key removed). Best-effort, same
  /// swallow-failures style as [_flushPersist].
  Future<void> _persistManualBases() async {
    try {
      final p = await SharedPreferences.getInstance();
      final key = manualStorageKeyFor(_platform);
      if (_manualBase.isEmpty) {
        await p.remove(key);
      } else {
        await p.setString(key, jsonEncode(_manualBase));
      }
    } catch (_) {
      // Unreadable/full prefs — keep the session override, skip persistence.
    }
  }

  /// UI indicator: true while a warmup probe run is actually probing domains,
  /// false once it finishes (or nothing needed probing). The home screen shows
  /// a small top-left badge on this so the user can see the check conclude.
  final ValueNotifier<bool> probing = ValueNotifier<bool>(false);

  @visibleForTesting
  static String storageKeyFor(String platform) => 'mirror_rank_v1_$platform';

  /// Prefs key for persisted manual base overrides (siteId → base). The
  /// `mirror_rank_v1_` prefix MUST be kept: the Android privacy wipe only
  /// preserves keys carrying it.
  @visibleForTesting
  static String manualStorageKeyFor(String platform) =>
      'mirror_rank_v1_manual_$platform';

  String get _platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  /// Load persisted rankings (idempotent, joins concurrent callers).
  Future<void> load() {
    final inFlight = _loading;
    if (_loaded && inFlight == null) return Future.value();
    if (inFlight != null) return inFlight;
    final future = _load();
    _loading = future;
    return future.whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      // Seed persisted manual base overrides BEFORE the rankings early-return
      // so a pin survives even when no ranking data exists yet. Entries
      // already set in-session (a re-pin while this read was in flight) win.
      final manualRaw = p.getString(manualStorageKeyFor(_platform));
      if (manualRaw != null && manualRaw.isNotEmpty) {
        final decodedManual = jsonDecode(manualRaw);
        if (decodedManual is Map) {
          decodedManual.forEach((siteId, base) {
            if (siteId is! String || base is! String) return;
            if (base.trim().isEmpty) return;
            _manualBase.putIfAbsent(
              siteId,
              () => base.replaceAll(RegExp(r'/$'), ''),
            );
          });
        }
      }
      final raw = p.getString(storageKeyFor(_platform));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final sites = decoded['sites'];
      if (sites is! Map) return;
      sites.forEach((siteId, entry) {
        if (siteId is! String || entry is! Map) return;
        final stats = <String, _MirrorStats>{};
        entry.forEach((base, v) {
          if (base is! String || v is! Map) return;
          stats[base] = _MirrorStats.fromJson(v);
        });
        if (stats.isNotEmpty) {
          // Merge, never overwrite: live onFetchOutcome stats written while
          // the prefs read was in flight must survive the load (a just-failed
          // mirror stays demoted instead of being reset by stale persisted
          // data).
          final target = _bySite.putIfAbsent(siteId, () => {});
          stats.forEach((base, st) => target.putIfAbsent(base, () => st));
        }
      });
    } catch (_) {
      // Corrupt or unreadable prefs — start fresh.
    } finally {
      _loaded = true;
    }
  }

  /// Mirrors ordered best-first for [site]: healthy (measured) by EWMA
  /// latency, then unmeasured (catalog order), then failing (cooldown).
  /// Never throws: with no data it is simply the catalog order.
  /// A user-chosen override (long-press on a card) jumps to the front and the
  /// remaining mirrors keep their ranked order behind it.
  List<String> rankedMirrors(SiteDef site) {
    final overrideRaw = manualBase(site.id);
    final ranked = _rankedMirrors(site);
    if (overrideRaw == null) return ranked;
    // Normalize so an override stored with/without a trailing slash still
    // matches a catalog entry that may carry one.
    final normalized = overrideRaw.replaceAll(RegExp(r'/$'), '');
    String? override;
    for (final base in ranked) {
      if (base.replaceAll(RegExp(r'/$'), '') == normalized) {
        override = base;
        break;
      }
    }
    // 用户手动新增的域名可能不在目录镜像里 —— 照样放到最前面参与抓取，
    // 而不是忽略（换域名的意义就是指向目录外的新主机）。
    if (override == null) return [normalized, ...ranked];
    return [
      override,
      ...ranked.where((b) => b != override),
    ];
  }

  List<String> _rankedMirrors(SiteDef site) {
    final mirrors = site.mirrors;
    if (mirrors.isEmpty) return const [];
    final stats = _bySite[site.id];
    if (stats == null || stats.isEmpty) return List<String>.from(mirrors);
    final scored = <(String, double, int)>[];
    for (var i = 0; i < mirrors.length; i++) {
      final base = mirrors[i];
      // Stats are keyed by the stripped base; catalog entries may carry a
      // trailing slash — normalize both sides so ranking can never silently
      // miss a mirror.
      final st = stats[base.replaceAll(RegExp(r'/$'), '')];
      final double score;
      if (st != null && st.isFailing) {
        score = _failingTier + i;
      } else if (st != null && st.successes > 0) {
        score = st.ewaMs.clamp(0.0, 60000.0);
      } else {
        score = _unknownTier + i;
      }
      scored.add((base, score, i));
    }
    scored.sort((a, b) {
      final byScore = a.$2.compareTo(b.$2);
      return byScore != 0 ? byScore : a.$3.compareTo(b.$3);
    });
    return [for (final s in scored) s.$1];
  }

  /// The single best mirror base for [site] (no trailing slash), falling back
  /// to catalog order / the primary host when nothing is ranked yet. Safe for
  /// single-mirror and custom sites.
  String preferredBase(SiteDef site) {
    final ranked = rankedMirrors(site);
    if (ranked.isNotEmpty) return ranked.first.replaceAll(RegExp(r'/$'), '');
    if (site.mirrors.isNotEmpty) {
      return site.mirrors.first.replaceAll(RegExp(r'/$'), '');
    }
    return site.primaryHost.replaceAll(RegExp(r'/$'), '');
  }

  /// True when a site should be re-probed: never measured, has any recent
  /// failure (probes are cheap HEADs, so even a single failure justifies a
  /// fresh look), or the freshest probe is older than [ttl].
  bool needsProbe(String siteId) {
    final stats = _bySite[siteId];
    if (stats == null || stats.isEmpty) return true;
    final now = DateTime.now();
    var newest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final st in stats.values) {
      if (st.lastProbe.isAfter(newest)) newest = st.lastProbe;
      if (st.failStreak > 0) return true;
    }
    return now.difference(newest) > ttl;
  }

  /// Cheap path driven by EVERY real fetch result (not just probes):
  /// keeps EWMA latencies and failure streaks fresh from live traffic.
  void onFetchOutcome(
    String siteId,
    String base, {
    required bool ok,
    required int ms,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    final stats = _bySite.putIfAbsent(siteId, () => {});
    final st = stats.putIfAbsent(base, _MirrorStats.new);
    if (ok) {
      st.successes++;
      st.recordLatency(ms.toDouble());
      st.failStreak = 0;
    } else {
      st.failStreak = st.failStreak + 1;
    }
    st.lastProbe = t;
    _schedulePersist();
  }

  /// Background warm-up: probe every mirror whose site ranking is stale or
  /// has failures. Bounded to [probeConcurrency] concurrent HEADs TOTAL (not
  /// per site) so launch never opens dozens of sockets next to the first feed
  /// load. HEADs are tiny — 8-wide keeps a 35-mirror catalog to ~5 quick
  /// batches instead of 9 slow ones.
  static const int probeConcurrency = 8;

  /// Connect budget for a probe. 5s: proxied TLS handshakes (Clash/V2Ray
  /// chains to far origins) routinely take 2-4s, and a connect timeout here
  /// is a FAILURE that feeds the "域名异常" badge — too tight a budget turns
  /// every slow-but-working proxy path into a false "site down".
  static const _probeConnectTimeout = Duration(milliseconds: 5000);
  static const _probeReceiveTimeout = Duration(milliseconds: 5000);

  Future<void> warmup({List<SiteDef>? sites}) async {
    await load();
    // Re-sync the system proxy before probing: the proxy tool may have
    // restarted or switched ports since the last detection, and probing
    // DIRECT while the user's proxy is up produces false "域名异常" verdicts
    // (the browser through the proxy works, the app's probe does not).
    await AppHttpClient.refreshSystemProxy();
    final targets = (sites ?? const <SiteDef>[])
        .where((site) => needsProbe(site.id))
        .toList();
    if (targets.isEmpty || probing.value) return;
    probing.value = true;
    try {
      // Interleave ROUND-ROBIN ACROSS SITES: wave 0 probes the first mirror
      // of every target, wave 1 the second mirror of every site that has
      // one, and so on. A site-first traversal would burst all ~6 mirrors of
      // one host family at once (rate-limit bait); round-robin spreads each
      // wave across different host families. The total concurrency gate
      // stays exactly [probeConcurrency].
      final queues = <List<String>>[
        for (final site in targets)
          [for (final raw in site.mirrors) if (raw.trim().isNotEmpty) raw],
      ];
      final gate = <Future<void>>[];
      var wave = 0;
      var more = true;
      while (more) {
        more = false;
        for (var i = 0; i < queues.length; i++) {
          if (wave >= queues[i].length) continue;
          more = true;
          if (gate.length >= probeConcurrency) {
            await Future.wait(gate);
            gate.clear();
          }
          gate.add(_probeOne(targets[i].id, queues[i][wave]));
        }
        wave++;
      }
      await Future.wait(gate);
    } finally {
      probing.value = false;
      await _flushPersist();
    }
  }

  /// HEAD-probe one site's mirrors through the shared proxy wiring.
  /// ANY HTTP answer (2xx-5xx, incl. Cloudflare 403 challenges) means the
  /// domain resolves, connects and serves — the domain is alive and gets its
  /// latency recorded. Only transport-level failures (DNS, connect/receive
  /// timeout, TLS) count as failure: Jable and other CF-fronted sites answer
  /// HEAD probes with 403 while the site itself works fine through the
  /// proxy + WebView render path, so a 4xx must NOT brand the domain down.
  /// Whether content is actually usable is judged by real fetch outcomes.
  Future<void> _probeOne(String siteId, String raw) async {
    final base = raw.replaceAll(RegExp(r'/$'), '');
    final sw = Stopwatch()..start();
    try {
      final dio = _probeDio ??= AppHttpClient.create(
        connectTimeout: _probeConnectTimeout,
        receiveTimeout: _probeReceiveTimeout,
      );
      await dio.head(
        base,
        options: Options(
          // Any HTTP status means the host is reachable fast.
          validateStatus: (_) => true,
          sendTimeout: _probeConnectTimeout,
          receiveTimeout: _probeReceiveTimeout,
        ),
      );
      onFetchOutcome(
        siteId,
        base,
        ok: true,
        ms: sw.elapsedMilliseconds,
      );
    } catch (_) {
      // A dead connection often means the cached proxy went stale (proxy app
      // restarted / switched port). Clear the throttle so the next refresh
      // re-detects, then refresh immediately for the remaining probes.
      AppHttpClient.markProxySuspect();
      await AppHttpClient.refreshSystemProxy();
      onFetchOutcome(siteId, base, ok: false, ms: sw.elapsedMilliseconds);
    }
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 1200), () {
      // ignore: discarded_futures
      _flushPersist();
    });
  }

  Future<void> _flushPersist() {
    _persistTimer?.cancel();
    _persistTail = _persistTail.then((_) async {
      try {
        final p = await SharedPreferences.getInstance();
        final sites = <String, Object>{};
        _bySite.forEach((siteId, stats) {
          final entry = <String, Object>{};
          stats.forEach((base, st) => entry[base] = st.toJson());
          sites[siteId] = entry;
        });
        await p.setString(
          storageKeyFor(_platform),
          jsonEncode({'v': 1, 'sites': sites}),
        );
      } catch (_) {}
    });
    return _persistTail;
  }

  @visibleForTesting
  void reset() {
    _loaded = false;
    _bySite.clear();
    _manualBase.clear();
    _persistTimer?.cancel();
    // Drop any queued/in-flight flush so it cannot write stale state after
    // the reset.
    _persistTail = Future.value();
  }

  @visibleForTesting
  Future<void> persistNow() => _flushPersist();
}

class _MirrorStats {
  _MirrorStats();

  factory _MirrorStats.fromJson(Map<dynamic, dynamic> m) {
    try {
      return _MirrorStats()
        ..ewaMs = (m['e'] as num?)?.toDouble() ?? 0
        ..failStreak = (m['f'] as num?)?.toInt() ?? 0
        ..successes = (m['ok'] as num?)?.toInt() ?? 0
        ..lastProbe =
            DateTime.fromMillisecondsSinceEpoch((m['t'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return _MirrorStats();
    }
  }

  static const _ewmaAlpha = 0.3;

  double ewaMs = 0;
  int failStreak = 0;
  int successes = 0;
  DateTime lastProbe = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isFailing => failStreak >= MirrorRanker.maxFailureStreak;

  void recordLatency(double ms) {
    // 首次成功记录作为基线（successes 在调用前已被 ++，故 == 1 即首次）。
    ewaMs = successes == 1 ? ms : ewaMs * (1 - _ewmaAlpha) + ms * _ewmaAlpha;
  }

  Map<String, Object> toJson() => {
        'e': ewaMs.round(),
        'f': failStreak,
        'ok': successes,
        't': lastProbe.millisecondsSinceEpoch,
      };
}