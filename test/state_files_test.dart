import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/fake_pool.dart';
import 'support/harness.dart';

/// The state files: versions, whole-or-nothing writes, refusals that change
/// nothing, what `cloak status` says about them, and what saving costs.
void main() {
  late FakePool fp;
  setUpAll(() async => fp = await FakePool.build());

  late Harness h;

  /// A wallet holding the fixture's round 1 note, so every state file exists.
  setUp(() async {
    h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: DateTime.utc(2023, 11, 1));
    expect((await h.initWithPool()).code, Exit.done);
    h.ports.transportPort = fp.transport(rounds: 1, head: 1);
    expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
    final inv = await h.run(['invoice', 'new', '--amount', '500', '--expires', '60d', '--out', '${h.root.path}/own']);
    expect(inv.code, Exit.done);
    final proof = '${h.root.path}/p';
    File(proof).writeAsBytesSync(fp.standingProof(1).encode());
    expect((await h.run(['check', proof])).code, Exit.done);
  });
  tearDown(() => h.dispose());

  test('State from a newer wallet', () async {
    final bytes = File(h.dir.noteStore).readAsBytesSync();
    final newer = [...bytes]..[0] = NoteStore.version + 1;
    File(h.dir.noteStore).writeAsBytesSync(newer);
    for (final c in ['status', 'balance']) {
      final ran = await h.run([c]);
      expect(ran.code, Exit.refused, reason: '$c: $ran');
      expect(ran.err, contains(h.dir.noteStore));
      expect(ran.err, contains('writes note store version ${NoteStore.version}'));
      expect(ran.err, contains('does not read ${NoteStore.version + 1}'));
    }
    expect(File(h.dir.noteStore).readAsBytesSync(), newer, reason: 'the file is not modified');

    // and this program's own state file the same way
    File(h.dir.noteStore).writeAsBytesSync(bytes);
    final state = jsonDecode(File(h.dir.state).readAsStringSync()) as Map<String, Object?>;
    state['version'] = CloakState.version + 1;
    File(h.dir.state).writeAsStringSync(jsonEncode(state));
    final ran = await h.run(['status']);
    expect(ran.code, Exit.refused);
    expect(ran.err, contains('wallet state version ${CloakState.version + 1}'));
    expect(ran.err, contains('writes version ${CloakState.version}'));
  });

  test('status reports this build\'s version and every format it reads', () async {
    final j = jsonDecode((await h.run(['status', '--json'])).out) as Map<String, Object?>;
    expect(j['version'], CloakVersion.program);
    expect(j['formats'], {
      'wallet file': WalletFile.version,
      'note store': NoteStore.version,
      'pool view': PoolView.version,
      'journal entry': JournalEntry.version,
      'wallet state': CloakState.version,
    });
  });

  test('status tells the truth about the files', () async {
    final ran = await h.run(['status', '--json']);
    final files = {
      for (final f in (jsonDecode(ran.out) as Map)['files'] as List) (f as Map)['name']: f,
    };
    for (final name in ['wallet file', 'note store', 'pool view', 'journal', 'wallet state', 'transport identity']) {
      expect(files, contains(name));
    }
    expect(files['wallet file']!['encrypted'], isTrue);
    expect(files['note store']!['encrypted'], isFalse);
    expect(files['note store']!['bytes'], File(h.dir.noteStore).lengthSync());
    final text = await h.run(['status']);
    expect(text.out, contains(RegExp(r'note store  \d+ bytes  NOT encrypted')));

    // status says what the chain database holds
    Directory(h.dir.chain).createSync();
    File('${h.dir.chain}/headers.isar').writeAsBytesSync([0]);
    final withChain = await h.run(['status']);
    expect(withChain.out, contains('chain database'));
    expect(withChain.out, contains('public block headers, and the transparent wallet\'s coins and transactions'));
  });

  group('whole or not at all', () {
    // A killed save leaves a whole temporary file beside the live one and
    // never renames it. libcloak's three files are saved by libcloak's own
    // temp-then-rename, with no seam to kill a process between the two, so for
    // those the wreckage is put where a kill leaves it; this program's own
    // state file is killed for real.
    test('Killed mid-write', () async {
      final live = {
        for (final f in [h.dir.poolView, h.dir.noteStore, h.dir.walletFile]) f: File(f).readAsBytesSync(),
      };
      for (final f in live.keys) {
        // the new contents a save was writing, whole, and a torn copy of them
        File('$f.tmp').writeAsBytesSync([...live[f]!.reversed]);
      }
      final before = await h.run(['balance', '--json']);
      expect(before.code, Exit.done, reason: 'the previous contents open without complaint: $before');
      expect(jsonDecode(before.out)['round'], 1);
      expect((await h.run(['unlock'])).code, Exit.done, reason: 'the wallet file opens as it was');
      for (final f in live.keys) {
        expect(File(f).readAsBytesSync(), live[f], reason: '$f was not touched');
      }
      // and the next save replaces the wreckage rather than reading it
      final addr = await h.run(['address']);
      expect(addr.code, Exit.done, reason: '$addr');
      expect(File('${h.dir.walletFile}.tmp').existsSync(), isFalse);
    });

    test('Interrupted in the middle of a write', () async {
      final before = File(h.dir.state).readAsStringSync();
      final child = await Process.run(Platform.resolvedExecutable, ['run', 'test/support/die_mid_write.dart', h.wallet]);
      expect(child.exitCode, isNot(0), reason: 'the writer was killed: ${child.stderr}');
      expect(File(CloakState.temporaryFor(h.dir.state)).existsSync(), isTrue, reason: 'the wreckage is there');
      expect(File(h.dir.state).readAsStringSync(), before, reason: 'the live file is the previous one');
      final ran = await h.run(['status']);
      expect(ran.code, Exit.done, reason: 'the previous state opens: $ran');
      expect(ran.err, isNot(contains('corrupt')));
      expect((await h.run(['notes', '--json'])).code, Exit.done);
    });
  });

  test('A truncated note store', () async {
    final whole = File(h.dir.noteStore).readAsBytesSync();
    final rng = Random(3);
    final steps = <String>{};
    for (int i = 0; i < 100; i++) {
      final cut = whole.sublist(0, rng.nextInt(whole.length));
      File(h.dir.noteStore).writeAsBytesSync(cut);
      final ran = await h.run(['notes']);
      expect(ran.code, Exit.refused, reason: 'offset ${cut.length}: $ran');
      final step = RegExp(r'refused at "([^"]+)"').firstMatch(ran.err)?.group(1);
      expect(step, isNotNull, reason: ran.err);
      expect(step, isNot('unexpected'), reason: ran.err);
      steps.add(step!);
      expect(File(h.dir.noteStore).readAsBytesSync(), cut, reason: 'not rewritten, truncated or repaired');
    }
    print('  100 truncated note stores refused at: ${steps.join(', ')}');
  });

  test('A thousand notes save inside the bound', () async {
    // a pool view following 1,000 notes and a note store holding them. The
    // commitments are random leaves of a tree built here, so every path is a
    // real path to a real root and the view accepts every one.
    final shape = fp.shape;
    final rng = Random(5);
    final tree = NoteCommitmentTree();
    final view = PoolView.atGenesis(shape);
    final store = NoteStore(shape);
    List<int> lanes(int n) => List.generate(n, (_) => rng.nextInt(M31.p));
    var round = 0;
    while (store.length < 1000) {
      round++;
      final first = tree.size;
      for (int i = 0; i < shape.leavesPerRound; i++) {
        tree.append(lanes(PoolHash.digestLanes));
      }
      final blockRoot = BlockFold.lanesToBytes(tree.nodeAt(shape.blockLevel, round - 1));
      expect(view.fold(round, blockRoot), isNull);
      for (int p = first; p < tree.size && store.length < 1000; p++) {
        final leaf = BlockFold.lanesToBytes(tree.nodeAt(0, p));
        final (_, why) = view.track(
            round: round, position: p, leaf: leaf, path: [for (final s in tree.path(p).siblings) List<int>.of(s)]);
        expect(why, isNull, reason: '$why');
        store.takeChange(
            opening: NoteOpening(
                asset: PoolHash.bsvAsset,
                d: lanes(PoolHash.dLanes),
                value: 1 + rng.nextInt(1000),
                rho: lanes(PoolHash.rhoLanes),
                rcm: lanes(PoolHash.rcmLanes)),
            position: p,
            round: round);
      }
    }
    expect(view.check(round, BlockFold.lanesToBytes(tree.root)), isNull);

    final (journal, _) = await Journal.open(h.dir.journal);
    final invoice = Invoice.decode(File('${h.root.path}/own').readAsBytesSync());
    final state = await CloakState.open(h.dir);
    final times = <int>[];
    for (int i = 0; i < 7; i++) {
      final sw = Stopwatch()..start();
      // the save path a payment takes: the view, the store, this program's
      // state, and one journal entry
      await PoolViewFile.save(h.dir.poolView, view);
      await NoteStoreFile.save(h.dir.noteStore, store);
      await state.save(h.dir);
      await journal!.add(JournalEntry.invoiceReceived(invoice));
      times.add(sw.elapsedMilliseconds);
    }
    times.sort();
    final viewBytes = File(h.dir.poolView).lengthSync(), storeBytes = File(h.dir.noteStore).lengthSync();
    print('  saving 1,000 notes: best ${times.first} ms, worst ${times.last} ms; '
        'pool view $viewBytes B (${viewBytes ~/ 1000} a note), note store $storeBytes B (${storeBytes ~/ 1000} a note)');
    expect(times.first, lessThan(500));
  }, tags: ['perf']);
}
