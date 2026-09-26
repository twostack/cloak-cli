import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:isar/isar.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:spiffynode/spiffy_node.dart' show BlockHeader;
import 'package:tstokenlib/tstokenlib.dart' show NoteAddress, BlockFold;
import 'package:test/test.dart';

import 'support/isar_core.dart';
import 'support/scripts.dart';
import 'support/fake_pool.dart';
import 'support/harness.dart';
import 'support/regtest_headers.dart';

/// libcloak's header source over libspiffy's validated chain: three questions
/// and no more, answered from headers the chain accepted itself.
void main() {
  late BlockHeaderChain chain;
  late SpiffyHeaderSource source;
  final mined = RegtestHeaders.mine(12);

  setUp(() async {
    chain = BlockHeaderChain(InMemoryWalletStorage(), params: RegtestHeaders.params);
    await chain.initialize();
    for (final h in mined) {
      final r = await chain.acceptHeader(h);
      expect(r.accepted, isTrue, reason: '$r');
    }
    source = SpiffyHeaderSource(chain);
  });

  test('The adapter\'s surface is the port\'s surface', () {
    final methods = <String>{};
    for (final d in reflectClass(SpiffyHeaderSource).declarations.values) {
      if (d is MethodMirror && !d.isConstructor && !d.isPrivate && !d.isStatic) {
        methods.add(MirrorSystem.getName(d.simpleName));
      }
    }
    expect(methods, {'tip', 'heightOfBlock', 'headerAtHeight'});
  });

  test('the three answers come from the chain libspiffy accepted', () async {
    final tip = await source.tip();
    expect(tip.height, 12);
    expect(hex.encode(tip.hash), mined.last.blockHash().toString());
    final five = mined[4];
    expect(await source.heightOfBlock(hex.decode(five.blockHash().toString())), 5);
    final header = await source.headerAtHeight(5);
    expect(header, hasLength(80));
    expect(MerkleMembership.hashOf(header!), hex.decode(five.blockHash().toString()),
        reason: 'the 80 bytes are the header whose hash was asked about');
    expect(await source.headerAtHeight(13), isNull);
  });

  test('A hash off the accepted chain', () async {
    // a branch from height 10 that carries less work than the active chain
    final side = RegtestHeaders.mine(1, from: mined[9], salt: 7).single;
    final r = await chain.acceptHeader(side);
    expect(r.accepted, isTrue);
    expect(chain.sideHeaderCount, 1, reason: 'held off the active chain');
    expect(await source.heightOfBlock(hex.decode(side.blockHash().toString())), isNull,
        reason: 'not on the chain it accepts, so nothing: not provisional');
    expect(await source.heightOfBlock(List.filled(32, 9)), isNull);
  });

  test('A flood of unconnected headers', () async {
    final strays = RegtestHeaders.mine(10000, from: RegtestHeaders.mine(1, salt: 99).single, salt: 1);
    var refused = 0;
    for (final h in strays) {
      final r = await chain.acceptHeader(h);
      if (!r.accepted) refused++;
    }
    expect(refused, 10000, reason: 'a run that connects to nothing is dropped');
    expect(chain.sideHeaderCount, 0, reason: 'nothing is retained off the accepted chain');
    expect(chain.bestHeight, 12);
    print('  10,000 unconnected headers: $refused refused, ${chain.sideHeaderCount} retained; rss '
        '${ProcessInfo.currentRss ~/ (1 << 20)} MB');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('Two processes agree', () async {
    final dir = Directory.systemTemp.createTempSync('cloak-headers');
    addTearDown(() => dir.deleteSync(recursive: true));
    await startIsar();
    final name = _storeName();
    final isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: dir.path, name: name);
    final stored = BlockHeaderChain(IsarWalletStorage(isar), params: RegtestHeaders.params);
    await stored.initialize();
    for (final h in mined) {
      expect((await stored.acceptHeader(h)).accepted, isTrue);
    }
    await isar.close();
    final answers = <String>[];
    for (int i = 0; i < 2; i++) {
      final r = await runScript('test/support/answer_headers.dart', [dir.path, name, mined[6].blockHash().toString(), '9']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      answers.add(const LineSplitter().convert('${r.stdout}').last);
    }
    expect(answers[1], answers[0]);
    final a = jsonDecode(answers[0]) as Map<String, Object?>;
    expect(a['tip'], 12);
    expect(a['height'], 7);
  }, timeout: const Timeout(Duration(minutes: 3)));

  group('through the commands', () {
    late FakePool fp;
    setUpAll(() async => fp = await FakePool.build());

    test('Switching networks in the config', () async {
      final h = Harness.make(poolKeys: fp.keys);
      addTearDown(h.dispose);
      expect((await h.initWithPool()).code, Exit.done);
      Directory(h.dir.chain).createSync();
      final marker = File('${h.dir.chain}/${SpiffyChain.networkFile}')..writeAsStringSync('testnet');
      final store = File('${h.dir.chain}/headers.isar')..writeAsBytesSync([1, 2, 3]);
      // the real ports, which start libspiffy for a command that needs it
      final out = StringBuffer(), err = StringBuffer();
      final world = World(
          out: out,
          err: err,
          env: h.env,
          ports: ProcessPorts(),
          kdf: WalletKdf.fast,
          now: () => h.now,
          poolKeysForSuite: (_) => fp.keys);
      final state = await CloakState.open(h.dir)
        ..descriptor = fp.pool.encode();
      await state.save(h.dir);
      expect((await h.run(['invoice', 'new', '--amount', '500', '--out', '${h.root.path}/i'])).code, Exit.done);
      File('${h.root.path}/p').writeAsBytesSync(fp.standingProof(1).encode());
      final code = await runCloak(['--wallet', h.wallet, 'check', '${h.root.path}/p'], world);
      expect(code, Exit.refused, reason: '$err');
      expect('$err', contains('the config names regtest'));
      expect('$err', contains('built for testnet'));
      expect(marker.readAsStringSync(), 'testnet');
      expect(store.readAsBytesSync(), [1, 2, 3], reason: 'the stored headers are unchanged');
    });

    test('The header store names no wallet', () async {
      final h = Harness.make(poolKeys: fp.keys, now: DateTime.utc(2023, 11, 1));
      addTearDown(h.dispose);
      expect((await h.initWithPool()).code, Exit.done);
      // the wallet's header store is a real Isar store in its own chain
      // directory, holding the fixture's blocks
      Directory(h.dir.chain).createSync();
      await startIsar();
      final isar = await Isar.open(LibSpiffySchemas.allSchemas, directory: h.dir.chain, name: _storeName());
      addTearDown(() async {
        if (isar.isOpen) await isar.close();
      });
      final stored = BlockHeaderChain(IsarWalletStorage(isar), skipProofOfWorkValidation: true);
      await stored.initialize();
      for (final b in fp.headers().blocks) {
        final r = await stored.acceptHeader(BlockHeader.deserialize(Uint8List.fromList(b.header)), expectedHeight: b.height);
        expect(r.accepted, isTrue, reason: '$r');
      }
      h.ports.headerSource = SpiffyHeaderSource(stored);
      h.ports.transportPort = fp.transport(rounds: 1, head: 1);
      expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
      await h.run(['invoice', 'new', '--amount', '500', '--expires', '60d', '--out', '${h.root.path}/own']);
      File('${h.root.path}/p').writeAsBytesSync(fp.standingProof(1).encode());
      expect((await h.run(['check', '${h.root.path}/p'])).code, Exit.done);
      await h.run(['invoice', 'new', '--amount', '200', '--expires', '60d', '--out', '${h.root.path}/other']);
      h.ports.transportPort = fp.transport();
      expect((await h.run(['pay', '${h.root.path}/other'])).code, Exit.done);
      final address = await NoteAddress.at(fp.keys.ivk, 0);
      final needles = <String, List<int>>{
        'the note\'s commitment': BlockFold.lanesToBytes(fp.note1.cm),
        'the address': address.bytes,
        'the address key': BlockFold.lanesToBytes(address.pkd),
        'the witness txid': hex.decode(fp.c.w1.id),
        'the witness txid, reversed': hex.decode(fp.c.w1.id).reversed.toList(),
        'the round txid': hex.decode(fp.c.r1.id),
      };
      // every header record the store holds, as the store gives it back: the
      // database also holds libspiffy's event store, which is not public, and
      // the rule is about the records a person may share as headers
      final records = <List<int>>[];
      for (int height = 0; height <= stored.bestHeight; height++) {
        final header = await stored.getHeaderByHeight(height);
        expect(header, isNotNull);
        records.add([...header!.serialize(), ...header.blockHash().toString().codeUnits]);
      }
      await isar.close();
      expect(records, hasLength(fp.headers().blocks.length));
      for (final r in records) {
        final text = latin1.decode(r);
        for (final n in needles.entries) {
          expect(_holds(r, n.value), isFalse, reason: 'a header record holds ${n.key}');
          expect(text.contains(hex.encode(n.value)), isFalse, reason: 'a header record holds ${n.key} in hex');
        }
      }
    });

    test('The SPV side is down', () async {
      final down = fp.headers()..fail = 'no peers reachable and the store is short';
      final h = Harness.make(ports: CountingPorts(headerSource: down), poolKeys: fp.keys);
      addTearDown(h.dispose);
      expect((await h.initWithPool()).code, Exit.done);
      h.ports.transportPort = fp.transport(rounds: 0, catchUp: false);
      expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
      await h.run(['invoice', 'new', '--amount', '500', '--out', '${h.root.path}/i']);
      File('${h.root.path}/p').writeAsBytesSync(fp.standingProof(1).encode());
      final opens = h.ports.transportOpens;
      final ran = await h.run(['check', '${h.root.path}/p']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "header source"'));
      expect(ran.err, contains('no peers reachable and the store is short'));
      expect(h.ports.transportOpens, opens, reason: 'the pool was not asked for a header');
    });
  });
}

bool _holds(List<int> haystack, List<int> needle) {
  outer:
  for (int i = 0; i + needle.length <= haystack.length; i++) {
    for (int j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// A header store name of this test's own. Isar keys an open instance by its
/// name across every isolate of the process, whatever directory it was opened
/// in, and `dart test` runs the other suite files as isolates of this one: a
/// store named `headers`, as libspiffy names a wallet's, would be another
/// file's store whenever the two overlap (release run 36215304283, where
/// this file's fresh store already had cdn_seed_test's tip).
String _storeName() => 'headers-chain-test-${pid}-${DateTime.now().microsecondsSinceEpoch}';
