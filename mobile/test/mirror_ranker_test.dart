import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/services/mirror_ranker.dart';
import 'package:epickle/services/source_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MirrorRanker.instance.reset();
  });

  final www = 'https://www.pornhub.com';
  final org = 'https://www.pornhub.org';
  final cn = 'https://cn.pornhub.com';
  final rt = 'https://rt.pornhub.com';
  final de = 'https://de.pornhub.com';
  final fr = 'https://fr.pornhub.com';

  test('rankedMirrors returns catalog order when there is no data', () async {
    await MirrorRanker.instance.load();

    expect(
      MirrorRanker.instance.rankedMirrors(SourceCatalog.pornhub),
      SourceCatalog.pornhub.mirrors,
    );
  });

  test('measured mirrors sort by blended latency, unknowns keep catalog '
      'order, a 2-failure mirror ranks last', () async {
    final ranker = MirrorRanker.instance;
    // www: 50ms then 300ms -> EWMA = 0.7*50 + 0.3*300 = 125ms, so a single
    // slow blip does not dethrone it (raw 300ms would have).
    ranker.onFetchOutcome('pornhub', www, ok: true, ms: 50);
    ranker.onFetchOutcome('pornhub', www, ok: true, ms: 300);
    ranker.onFetchOutcome('pornhub', cn, ok: true, ms: 130);
    ranker.onFetchOutcome('pornhub', org, ok: true, ms: 200);
    // Two consecutive failures demote rt below the never-measured mirrors.
    ranker.onFetchOutcome('pornhub', rt, ok: false, ms: 0);
    ranker.onFetchOutcome('pornhub', rt, ok: false, ms: 0);

    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      [www, cn, org, de, fr, rt],
    );
    await ranker.persistNow();
  });

  test('a single failure does not demote, two failures do and trigger '
      'needsProbe', () async {
    final ranker = MirrorRanker.instance;
    ranker.onFetchOutcome('pornhub', rt, ok: false, ms: 0);

    // Streak < 2: rt keeps its catalog slot and the site asks for a re-probe.
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      SourceCatalog.pornhub.mirrors,
    );
    expect(ranker.needsProbe('pornhub'), isTrue);

    ranker.onFetchOutcome('pornhub', rt, ok: false, ms: 0);

    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      [www, org, cn, de, fr, rt],
    );
    expect(ranker.needsProbe('pornhub'), isTrue);
    await ranker.persistNow();
  });

  test('needsProbe: no data, fresh healthy outcome, any failure, stale '
      'probe', () async {
    final ranker = MirrorRanker.instance;

    expect(ranker.needsProbe('pornhub'), isTrue);

    ranker.onFetchOutcome('pornhub', www, ok: true, ms: 50);
    expect(ranker.needsProbe('pornhub'), isFalse);

    ranker.onFetchOutcome('pornhub', www, ok: false, ms: 0);
    expect(ranker.needsProbe('pornhub'), isTrue);

    // A healthy outcome whose "now" is older than the 30-minute TTL.
    ranker.onFetchOutcome(
      'pornhub',
      www,
      ok: true,
      ms: 60,
      now: DateTime.now().subtract(const Duration(minutes: 31)),
    );
    expect(ranker.needsProbe('pornhub'), isTrue);

    // A fresh outcome brings the freshest probe back inside the TTL.
    ranker.onFetchOutcome('pornhub', www, ok: true, ms: 55);
    expect(ranker.needsProbe('pornhub'), isFalse);
    await ranker.persistNow();
  });

  test('rankings persist across a reset; corrupt JSON loads fresh instead '
      'of throwing', () async {
    final ranker = MirrorRanker.instance;
    ranker.onFetchOutcome('pornhub', cn, ok: true, ms: 100);
    ranker.onFetchOutcome('pornhub', www, ok: true, ms: 50);
    ranker.onFetchOutcome('pornhub', rt, ok: false, ms: 0);
    ranker.onFetchOutcome('pornhub', rt, ok: false, ms: 0);
    await ranker.persistNow();

    ranker.reset();
    await ranker.load();

    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      [www, cn, org, de, fr, rt],
    );
    // rt's 2-failure streak survived the round-trip too, so the site still
    // wants a re-probe (any failStreak > 0 keeps needsProbe true).
    expect(ranker.needsProbe('pornhub'), isTrue);

    // Corrupt persisted JSON must not throw and should start fresh.
    SharedPreferences.setMockInitialValues(
        {'mirror_rank_v1_android': '{not json'});
    ranker.reset();
    await ranker.load();

    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      SourceCatalog.pornhub.mirrors,
    );
    expect(ranker.needsProbe('pornhub'), isTrue);
  });

  test('custom single-mirror site ranks its only mirror and probes on '
      'demand', () async {
    final custom = SiteDef.customFromUrl('https://fixture.test/catalog');
    final ranker = MirrorRanker.instance;

    expect(custom.mirrors, ['https://fixture.test/catalog']);
    expect(ranker.rankedMirrors(custom), custom.mirrors);
    expect(ranker.needsProbe(custom.id), isTrue);

    ranker.onFetchOutcome(custom.id, custom.mirrors.single, ok: true, ms: 40);

    expect(ranker.rankedMirrors(custom), custom.mirrors);
    expect(ranker.needsProbe(custom.id), isFalse);
    await ranker.persistNow();
  });

  test('a mirror stuck on 4xx (parked domain) ranks behind a healthy slower '
      'one, and a real success clears the verdict', () async {
    final ranker = MirrorRanker.instance;
    // cn: fast HEAD but 4xx to both HEAD and GET (challenge/parked).
    ranker.onFetchOutcome('pornhub', cn, ok: true, ms: 40);
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).first,
      cn,
    ); // no verdict yet — probe status unknown, raw latency rules

    // Simulate the probe recording a 4xx verdict (as _probeOne does after
    // its confirming GET also answered 4xx).
    ranker.debugSetLastStatus('pornhub', cn, 403);
    // www: slower but genuinely serving.
    ranker.onFetchOutcome('pornhub', www, ok: true, ms: 300);

    expect(ranker.rankedMirrors(SourceCatalog.pornhub).first, www);

    // A real fetch success proves cn serves content — verdict drops.
    ranker.onFetchOutcome('pornhub', cn, ok: true, ms: 60);
    expect(ranker.rankedMirrors(SourceCatalog.pornhub).first, cn);
    await ranker.persistNow();
  });

  test('4xx status survives the persist/load round-trip', () async {
    final ranker = MirrorRanker.instance;
    ranker.onFetchOutcome('pornhub', cn, ok: true, ms: 40);
    ranker.debugSetLastStatus('pornhub', cn, 403);
    await ranker.persistNow();

    ranker.reset();
    await ranker.load();

    // cn (403-penalized 40ms) must rank behind org (unknown → catalog tier).
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).indexOf(cn),
      greaterThan(ranker.rankedMirrors(SourceCatalog.pornhub).indexOf(org)),
    );
  });

  test('session manual base override jumps to the front — even a brand-new '
      'domain outside the catalog — until cleared', () async {
    final ranker = MirrorRanker.instance;
    await ranker.load();

    // Pin a non-top mirror for the session. Catalog order (no data):
    // www, org, cn, rt, de, fr — so the override pushes cn to the front and
    // everything else keeps catalog order.
    ranker.setManualBase('pornhub', cn);
    expect(ranker.manualBase('pornhub'), cn);
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      [cn, www, org, rt, de, fr],
    );
    expect(ranker.preferredBase(SourceCatalog.pornhub), cn);

    // Trailing-slash normalization: user picks 'https://rt.pornhub.com/' —
    // stored stripped and still matched.
    ranker.setManualBase('pornhub', 'https://rt.pornhub.com/');
    expect(ranker.manualBase('pornhub'), rt);
    expect(ranker.rankedMirrors(SourceCatalog.pornhub).first, rt);

    // Unknown base (user pinned a brand-new domain outside the catalog) is
    // KEPT now: it is prepended ahead of the catalog mirrors — the whole
    // point of pinning is to point at a new host the catalog doesn't know.
    ranker.setManualBase('pornhub', 'https://gone.example.com');
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).first,
      'https://gone.example.com',
    );
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).skip(1),
      SourceCatalog.pornhub.mirrors,
    );

    // Clearing returns to auto immediately.
    ranker.setManualBase('pornhub', de);
    ranker.clearManualBase('pornhub');
    expect(ranker.manualBase('pornhub'), isNull);
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      SourceCatalog.pornhub.mirrors,
    );
    await ranker.persistNow();
  });

  test('manual override is session-only: a fresh reset() drops it', () async {
    final ranker = MirrorRanker.instance;
    ranker.setManualBase('pornhub', fr);
    ranker.reset();
    await ranker.load();

    expect(ranker.manualBase('pornhub'), isNull);
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      SourceCatalog.pornhub.mirrors,
    );
  });

  test('setManualBasePersisted pins the new domain (also across a restart) '
      'and clearManualBasePersisted restores catalog order', () async {
    final ranker = MirrorRanker.instance;
    await ranker.load();

    await ranker.setManualBasePersisted('pornhub', 'https://new.example.com');
    expect(ranker.manualBase('pornhub'), 'https://new.example.com');
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).first,
      'https://new.example.com',
    );
    // Catalog mirrors keep their (unranked) order behind the pinned domain.
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).skip(1),
      SourceCatalog.pornhub.mirrors,
    );

    // Persisted: a fresh reset + load (app restart) re-seeds the pin.
    ranker.reset();
    await ranker.load();
    expect(ranker.manualBase('pornhub'), 'https://new.example.com');
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub).first,
      'https://new.example.com',
    );

    await ranker.clearManualBasePersisted('pornhub');
    expect(ranker.manualBase('pornhub'), isNull);
    expect(
      ranker.rankedMirrors(SourceCatalog.pornhub),
      SourceCatalog.pornhub.mirrors,
    );
  });
}