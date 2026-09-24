@Tags(['localnet', 'perf'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/coordinator_end.dart';
import 'support/fake_pool.dart';
import 'support/harness.dart';
import 'support/ricochet_server.dart';

/// `cloak sync` over a thousand announced rounds, read over a real ricochet
/// server, by a wallet following eight notes.
///
///   POOL_LOCALNET=1 dart test test/localnet_sync_test.dart
void main() async {
  final skip = Platform.environment['POOL_LOCALNET'] == null
      ? 'needs ../localnet up; set POOL_LOCALNET=1'
      : await RicochetTestServer.available();

  test('A thousand rounds inside the bound', () async {
    final fp = await FakePool.build();
    final server = (await RicochetTestServer.start())!;
    addTearDown(server.dispose);
    final rng = Random(41);
    Uint8List bytes(int n) => Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
    final coordinator = await CoordinatorEnd.connect(seed: bytes(32), server: server.address);
    addTearDown(coordinator.close);
    await coordinator.ensureFeed();

    // a pool whose rounds are built from a real commitment tree, so every
    // announcement's block root folds to its own header's root
    final shape = fp.shape;
    final tree = NoteCommitmentTree();
    List<int> lanes(int n) => List.generate(n, (_) => rng.nextInt(M31.p));
    final zero = List.filled(32, 0);
    PoolAnnouncement announce(int round) {
      for (int i = 0; i < shape.leavesPerRound; i++) {
        tree.append(lanes(PoolHash.digestLanes));
      }
      final header = PoolHeader(
          cmRoot: BlockFold.lanesToBytes(tree.root),
          nfRoot: zero,
          ring: List.filled(PoolHeader.ringEntries, zero),
          size: tree.size,
          balance: BigInt.zero,
          outHash: zero);
      return PoolAnnouncement(
          round: round,
          header: header,
          roundTxId: bytes(32),
          witnessTxId: bytes(32),
          slotTxId: bytes(32),
          blockRoot: BlockFold.lanesToBytes(tree.nodeAt(shape.blockLevel, round - 1)));
    }

    // round 1, and the wallet's eight notes in it, followed from there
    final first = announce(1);
    final view = PoolView.atGenesis(shape);
    expect(view.fold(1, first.blockRoot, cmRoot: first.header.cmRoot), isNull);
    for (int p = 0; p < 8; p++) {
      final (_, why) = view.track(
          round: 1,
          position: p,
          leaf: BlockFold.lanesToBytes(tree.nodeAt(0, p)),
          path: [for (final s in tree.path(p).siblings) List<int>.of(s)]);
      expect(why, isNull);
    }
    final feed = [fp.pool.encode(), first.encode(), for (int r = 2; r <= 1000; r++) announce(r).encode()];
    final publish = Stopwatch()..start();
    for (final e in feed) {
      await coordinator.announce(Uint8List.fromList(e));
    }
    print('  published ${feed.length} feed entries in ${publish.elapsedMilliseconds} ms');

    final h = Harness.make();
    addTearDown(h.dispose);
    await h.initWithPool();
    final state = await CloakState.open(h.dir)
      ..descriptor = fp.pool.encode();
    await state.save(h.dir);
    await PoolViewFile.save(h.dir.poolView, view);
    final config = File(h.dir.config);
    config.writeAsStringSync(config.readAsStringSync().replaceFirst('timeout_seconds: 30', 'timeout_seconds: 2'));

    final transport = await RicochetWalletTransport.connect(
        seed: bytes(32), server: server.address, coordinator: coordinator.peerId, timeout: const Duration(seconds: 2));
    addTearDown(transport.close);
    h.ports
      ..transportPort = transport
      ..headerSource = fp.headers();
    final sw = Stopwatch()..start();
    final ran = await h.run(['sync', '--json']);
    sw.stop();
    // no coordinator runs here to prove the head, so the fold is saved and
    // said to be unchecked; the clock facts come with it
    expect(ran.err, contains('refused at "head proof"'), reason: '$ran');
    final facts = jsonDecode(const LineSplitter().convert(ran.out).first) as Map<String, Object?>;
    expect(facts['round'], 1000);
    expect(facts['folded'], 999);
    final clock = facts['clockMs'] as Map<String, Object?>;
    final headWait = 2 * 2 * 1000;
    print('  1,000 rounds over ricochet holding 8 notes: whole ${sw.elapsedMilliseconds} ms (of which ~$headWait ms '
        'waiting on a head proof nobody in this run answers), transport ${clock['transport']} ms, folding '
        'and checking ${clock['folding']} ms');
    expect(sw.elapsedMilliseconds, lessThan(30000));
    expect(clock['folding'] as int, lessThan(2000));
    final saved = await PoolViewFile.open(h.dir.poolView, shape: shape);
    expect(saved.round, 1000);
    expect(saved.notes, hasLength(8), reason: 'all eight notes brought forward');
    expect(saved.cmRoot, BlockFold.lanesToBytes(tree.root), reason: 'the fold reached the pool\'s root');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));
}
