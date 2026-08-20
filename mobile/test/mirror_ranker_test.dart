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
}