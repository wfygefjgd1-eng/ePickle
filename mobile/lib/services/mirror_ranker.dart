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

  /// UI indicator: true while a warmup probe run is actually probing domains,
  /// false once it finishes (or nothing needed probing). The home screen shows
  /// a small top-left badge on this so the user can see the check conclude.
  final ValueNotifier<bool> probing = ValueNotifier<bool>(false);

  @visibleForTesting
  static String storageKeyFor(String platform) => 'mirror_rank_v1_$platform';

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
  List<String> rankedMirrors(SiteDef site) {
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
  /// per site) so launch never opens 4×N sockets next to the first feed load.
  static const int probeConcurrency = 4;
  Future<void> warmup({List<SiteDef>? sites}) async {
    await load();
    final targets = (sites ?? const <SiteDef>[])
        .where((site) => needsProbe(site.id))
        .toList();
    if (targets.isEmpty || probing.value) return;
    probing.value = true;
    try {
      final gate = <Future<void>>[];
      for (final site in targets) {
        for (final raw in site.mirrors) {
          if (raw.trim().isEmpty) continue;
          if (gate.length >= probeConcurrency) {
            await Future.wait(gate);
            gate.clear();
          }
          gate.add(_probeOne(site.id, raw));
        }
      }
      await Future.wait(gate);
    } finally {
      probing.value = false;
      await _flushPersist();
    }
  }

  /// HEAD-probe every mirror of [site] through the shared proxy wiring.
  /// Any HTTP 2xx/3xx proves the host answers; 4xx proves it answers but is
  /// blocked for us (counted as a failure so it sinks in ranking).
  Future<void> probeSite(SiteDef site) async {
    if (site.mirrors.isEmpty) return;
    final gate = <Future<void>>[];
    for (final raw in site.mirrors) {
      if (raw.trim().isEmpty) continue;
      if (gate.length >= probeConcurrency) {
        await Future.wait(gate);
        gate.clear();
      }
      gate.add(_probeOne(site.id, raw));
    }
    await Future.wait(gate);
    _schedulePersist();
  }

  Future<void> _probeOne(String siteId, String raw) async {
    final base = raw.replaceAll(RegExp(r'/$'), '');
    final sw = Stopwatch()..start();
    try {
      final dio = _probeDio ??= AppHttpClient.create(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
      );
      final res = await dio.head(
        base,
        options: Options(
          // Any HTTP status means the host is reachable fast.
          validateStatus: (_) => true,
          sendTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final code = res.statusCode ?? 0;
      onFetchOutcome(
        siteId,
        base,
        ok: code >= 200 && code < 500,
        ms: sw.elapsedMilliseconds,
      );
    } catch (_) {
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
    ewaMs = successes <= 1 ? ms : ewaMs * (1 - _ewmaAlpha) + ms * _ewmaAlpha;
  }

  Map<String, Object> toJson() => {
        'e': ewaMs.round(),
        'f': failStreak,
        'ok': successes,
        't': lastProbe.millisecondsSinceEpoch,
      };
}