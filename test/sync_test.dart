import 'dart:convert';
import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:dartsv/dartsv.dart' show NetworkType;
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/fake_pool.dart';
import 'support/fakes.dart';
import 'support/harness.dart';

/// `cloak sync`: the pool view brought to the tip and checked against a round
/// the wallet proved off the chain, with the pool a server and never an
/// authority.
void main() {
  late FakePool fp;
  setUpAll(() async => fp = await FakePool.build());

  late Harness h;
  late FakeHeaderSource headers;
  setUp(() async {
    headers = fp.headers();
    h = Harness.make(ports: CountingPorts(headerSource: headers), poolKeys: fp.keys);
    expect((await h.initWithPool()).code, Exit.done);
  });
  tearDown(() => h.dispose());

  Future<Ran> sync(FakeTransport t, [List<String> extra = const []]) {
    h.ports.transportPort = t;
    return h.run(['sync', '--json', ...extra]);
  }

  Map<String, Object?> facts(Ran r) => jsonDecode(r.out) as Map<String, Object?>;

  List<PoolCatchUpRequest> asked(FakeTransport t) => [
        for (final f in t.sent)
          if (PoolMessage.decode(f) is PoolCatchUpRequest) PoolMessage.decode(f) as PoolCatchUpRequest
      ];

  /// A wallet whose stored view stands at round 0, checked: it has read the
  /// descriptor and nothing else.
  Future<void> atGenesis() async {
    final ran = await sync(fp.transport(rounds: 0, catchUp: false), ['--from-genesis']);
    expect(ran.code, Exit.done, reason: '$ran');
    expect(facts(ran)['round'], 0);
  }

  group('a first sync', () {
    test('stands the wallet up on a head proof and a frontier, and checks one against the other', () async {
      final ran = await sync(fp.transport());
      expect(ran.code, Exit.done, reason: '$ran');
      expect(facts(ran)['round'], 2);
      expect(facts(ran)['checkedTo'], 2);
      expect(File(h.dir.poolView).existsSync(), isTrue);
      expect(headers.calls, isNotEmpty, reason: 'the head proof was checked against this wallet\'s own headers');
    });

    test('A pool that offers someone else\'s tree', () async {
      final ran = await sync(fp.transport(answer: (q) {
        if (q.what != CatchUpKind.frontier) return null;
        final f = fp.frontierReply(2);
        return PoolCatchUpReply.frontier(round: f.round, blockRoot: FakePool.bent(f.blockRoot!), left: f.left);
      }));
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "checkpoint"'));
      expect(File(h.dir.poolView).existsSync(), isFalse, reason: 'no pool view file is written');
    });

    test('The round number comes from the chain, not the claim', () async {
      // the head proof is round 2's, and the coordinator says it is round 5
      final ran = await sync(fp.transport(answer: (q) {
        if (q.what != CatchUpKind.head) return null;
        final r = fp.headReply(2);
        return PoolCatchUpReply.head(
            round: 5,
            roundTx: r.roundTx!,
            witnessTx: r.witnessTx!,
            blockHash: r.blockHash!,
            txIndex: r.txIndex,
            branch: r.branch);
      }));
      // libcloak refuses a head whose claim disagrees with its own leaf
      // count, which is stricter than using the leaf count's round: the
      // claim is never used, and neither is anything that came with it
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('round 5'));
      expect(ran.err, contains('round 2 by its own leaf count'));
      expect(File(h.dir.poolView).existsSync(), isFalse);
    });

    test('A pool that does not serve catch-up', () async {
      final t = fp.transport(catchUp: false);
      final ran = await sync(t);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "catch-up"'));
      expect(ran.err, contains('does not serve catch-up'));
      expect(ran.err, contains('round 0'));
      expect(t.reads, ['readFeed 0 1'], reason: 'the descriptor, and no silent read of the whole feed');
      expect(File(h.dir.poolView).existsSync(), isFalse);
    });

    test('A pool that could not be asked is not said to refuse catch-up', () async {
      const why = 'the frame was not stored: Exception: Failed to dial: Exception: No addresses found for peer';
      final t = fp.transport(undelivered: why);
      final ran = await sync(t);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "transport"'));
      expect(ran.err, contains('the pool could not be asked: $why'));
      expect(ran.err, contains('round 0'));
      expect(ran.err, isNot(contains('does not serve catch-up')));
      expect(ran.err, isNot(contains('--from-genesis')));
      expect(File(h.dir.poolView).existsSync(), isFalse);
    });

    test('A reply an earlier run gave up on is not taken as this run\'s answer', () async {
      // a first sync that stopped after asking for the frontier leaves its
      // answer in the replies folder, and the next first sync's head request
      // was answered with it
      final t = fp.transport()..lateReplies.add(fp.frontierReply(2).encode());
      final ran = await sync(t);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(facts(ran)['round'], 2);
      expect(t.lateReplies, isEmpty);
    });

    test('--from-genesis folds the whole feed when a person asks for it', () async {
      final t = fp.transport(catchUp: false);
      final ran = await sync(t, ['--from-genesis']);
      // folded, and the pool will not prove its head, so it is saved unchecked
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "head proof"'));
      expect(ran.err, contains('folded to round 2 and saved, checked to round 0'));
      final view = PoolView.decode(File(h.dir.poolView).readAsBytesSync(), shape: fp.shape);
      expect(view.round, 2);
      expect(view.checkedTo, 0);
    });
  });

  group('a later sync', () {
    test('folds the feed forward and checks once', () async {
      await atGenesis();
      final t = fp.transport();
      final ran = await sync(t);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(facts(ran)['folded'], 2);
      expect(facts(ran)['checkedTo'], 2);
      expect(asked(t).map((q) => q.what), [CatchUpKind.head], reason: 'one check at the end of the run');
    });

    test('A wrong block root is caught at the end of the run', () async {
      await atGenesis();
      final before = File(h.dir.poolView).readAsBytesSync();
      // the feed no longer reaches round 1, so the wallet catches up by the
      // published run, and round 1's root in that run is not this pool's
      final ran = await sync(fp.transport(feed: [fp.pool.encode(), fp.ann2.encode()], roots: {
        1: FakePool.bent(fp.br1),
        2: fp.br2,
      }));
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "cmRoot"'));
      expect(File(h.dir.poolView).readAsBytesSync(), before, reason: 'left at the round it was checked to');
    });

    test('A self-contradicting announcement', () async {
      await atGenesis();
      final before = File(h.dir.poolView).readAsBytesSync();
      final lying = PoolAnnouncement.of(1, fp.round1.header, fp.c.r1, fp.c.w1, fp.c.y1.tx, blockRoot: fp.br2);
      final ran = await sync(fp.transport(feed: [fp.pool.encode(), lying.encode()]));
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('round 1'));
      expect(ran.err, contains('contradicted itself'));
      expect(File(h.dir.poolView).readAsBytesSync(), before, reason: 'nothing was folded');
    });

    test('A round announced twice with different roots', () async {
      await atGenesis();
      final again = PoolAnnouncement(
          round: 1,
          header: fp.round1.header,
          roundTxId: fp.ann1.roundTxId,
          witnessTxId: fp.ann1.witnessTxId,
          slotTxId: fp.ann1.slotTxId,
          blockRoot: FakePool.bent(fp.br1));
      final ran = await sync(fp.transport(feed: [fp.pool.encode(), fp.ann1.encode(), again.encode()]));
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('round 1'));
      expect(ran.err, contains(shortHex(fp.br1)));
      expect(ran.err, contains(shortHex(FakePool.bent(fp.br1))));
    });

    test('A descriptor with a different block size', () async {
      await atGenesis();
      final before = File(h.dir.state).readAsBytesSync();
      final wider = PoolDescriptor(
          network: NetworkType.TEST,
          issuance: fp.pool.issuance,
          witness0: fp.pool.witness0,
          slot0: fp.pool.slot0,
          arities: const [2, 2, 2, 2, 2],
          nullifierLevel: 1,
          receiptSlots: 2,
          spendP: fp.pool.spendP,
          leavesPerRound: 64,
          tokenId: fp.pool.tokenId,
          genesisHeader: fp.pool.genesisHeader);
      final ran = await sync(fp.transport(feed: [wider.encode()]));
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('${fp.pool.leavesPerRound}'));
      expect(ran.err, contains('64'));
      expect(File(h.dir.state).readAsBytesSync(), before, reason: 'no state is written');
    });

    test('Already current', () async {
      expect((await sync(fp.transport())).code, Exit.done);
      final view = File(h.dir.poolView), state = File(h.dir.state);
      final (viewBytes, viewTime) = (view.readAsBytesSync(), view.lastModifiedSync());
      final (stateBytes, stateTime) = (state.readAsBytesSync(), state.lastModifiedSync());
      final again = await sync(fp.transport());
      expect(again.code, Exit.done, reason: '$again');
      expect(facts(again)['folded'], 0);
      expect(again.out, isNot(contains('"folded":2')));
      expect(view.readAsBytesSync(), viewBytes);
      expect(view.lastModifiedSync(), viewTime, reason: 'the pool view file was not rewritten');
      expect(state.readAsBytesSync(), stateBytes);
      expect(state.lastModifiedSync(), stateTime);
    });

    test('Interrupted and resumed', () async {
      // the run that is not interrupted, in a wallet of its own
      final whole = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys);
      addTearDown(whole.dispose);
      await whole.initWithPool();
      whole.ports.transportPort = fp.transport(rounds: 0, catchUp: false);
      await whole.run(['sync', '--from-genesis']);
      whole.ports.transportPort = fp.transport();
      expect((await whole.run(['sync'])).code, Exit.done);

      await atGenesis();
      final before = File(h.dir.poolView).readAsBytesSync();
      final dying = fp.transport()..feed.add(const [9, 9]);
      // the feed breaks off after round 1: an entry that is not a message
      final broken = await sync(dying);
      expect(broken.code, Exit.refused, reason: '$broken');
      expect(File(h.dir.poolView).readAsBytesSync(), before, reason: 'left where it was');
      final resumed = await sync(fp.transport());
      expect(resumed.code, Exit.done, reason: '$resumed');
      expect(File(h.dir.poolView).readAsBytesSync(), File(whole.dir.poolView).readAsBytesSync(),
          reason: 'the same final view, byte for byte');
    });
  });

  group('what a sync says about the wallet', () {
    test('Two wallets at different rounds ask the same question', () async {
      // wallet A has read nothing past the descriptor
      await atGenesis();
      final a = fp.transport(feed: [fp.pool.encode()]);
      expect((await sync(a)).code, Exit.done);

      // wallet B has folded and checked round 1
      final b = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys);
      addTearDown(b.dispose);
      await b.initWithPool();
      b.ports.transportPort = fp.transport(rounds: 1, head: 1);
      expect((await b.run(['sync', '--from-genesis'])).code, Exit.done);
      final bt = fp.transport(feed: [fp.pool.encode()]);
      b.ports.transportPort = bt;
      final ranB = await b.run(['sync', '--json']);
      expect(ranB.code, Exit.done, reason: '$ranB');

      final runsA = [for (final q in asked(a)) if (q.what == CatchUpKind.blockRoots) _question(q)];
      final runsB = [for (final q in asked(bt)) if (q.what == CatchUpKind.blockRoots) _question(q)];
      expect(runsA, isNotEmpty);
      expect(runsA, runsB, reason: 'a wallet 1 round behind and one 2 behind ask the same question');
      final q = asked(a).firstWhere((q) => q.what == CatchUpKind.blockRoots);
      expect(q.count, fp.pool.catchUpRange, reason: 'a run of the size the descriptor publishes');
      expect(fp.pool.publishesRange(q.from, q.count), isTrue);
    });

    test('Two wallets holding different notes sync identically', () async {
      // one wallet takes the fixture's round 1 note; the other holds nothing
      final holding = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys);
      addTearDown(holding.dispose);
      await holding.initWithPool();
      for (final w in [h, holding]) {
        w.ports.transportPort = fp.transport(rounds: 1, head: 1);
        expect((await w.run(['sync', '--from-genesis'])).code, Exit.done);
      }
      final proof = '${holding.root.path}/round1.proof';
      File(proof).writeAsBytesSync(fp.standingProof(1).encode());
      await holding.run(['invoice', 'new', '--amount', '500', '--out', '${holding.root.path}/i']);
      final took = await holding.run(['check', proof]);
      if (took.code != Exit.done) markTestSkipped('cloak check is not built yet: $took');

      final th = fp.transport(), tn = fp.transport();
      h.ports.transportPort = th;
      holding.ports.transportPort = tn;
      expect((await h.run(['sync'])).code, Exit.done);
      expect((await holding.run(['sync'])).code, Exit.done);
      // a request's id is fresh for every request and names nothing, so the
      // frames are compared by what they ask
      expect([for (final f in tn.sent) _asks(f)], [for (final f in th.sent) _asks(f)],
          reason: 'the frames sent do not say which wallet holds a note');
      expect(tn.reads, th.reads);
    });
  });
}

/// What a catch-up request asks, without the id it is sent under.
String _question(PoolCatchUpRequest q) => '${q.what.name} ${q.from} ${q.count}';

String _asks(List<int> frame) {
  final m = PoolMessage.decode(frame);
  return m is PoolCatchUpRequest ? _question(m) : m.kind.name;
}
