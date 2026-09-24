import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';
import 'package:yaml/yaml.dart';

import 'support/fake_pool.dart';
import 'support/fakes.dart';
import 'support/harness.dart';

/// The transport: what it depends on, whose identity it is, how it bounds
/// what it reads, and what the client above it makes of hostile replies once
/// this program's own wrappers sit between them.
void main() {
  late FakePool fp;
  setUpAll(() async => fp = await FakePool.build());

  test('The runtime dependency graph', () {
    final manifest = loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    final runtime = (manifest['dependencies'] as YamlMap).keys.toSet();
    final dev = (manifest['dev_dependencies'] as YamlMap).keys.toSet();
    expect(runtime, isNot(contains('pool_coordinator')), reason: 'a wallet does not depend on the server it talks to');
    expect(dev, contains('pool_coordinator'), reason: 'its suite does');
    expect(runtime, contains('ricochet'));
  });

  test('The identity is unrelated to the wallet', () async {
    final a = Harness.make(), b = Harness.make();
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final seedA = (await a.init()).out.trim();
    await b.init();
    final idA = File(a.dir.identity).readAsBytesSync(), idB = File(b.dir.identity).readAsBytesSync();
    expect(idA, hasLength(32));
    expect(idA, isNot(idB));

    // nothing the seed derives is the identity
    final seed = WalletSeed.fromHex(seedA);
    final keys = WalletKeys(seed: seed, birthday: 0);
    for (final candidate in [
      seed.bytes,
      for (final info in ['tsl1-libcloak/derivation/1/sk', 'ricochet', 'identity', 'transport']) seed.expand(info, 32),
    ]) {
      expect(candidate, isNot(idA));
    }

    // and swapping identities between wallets changes neither wallet
    final before = await keys.addressAt(0);
    File(a.dir.identity).writeAsBytesSync(idB);
    final stored = await WalletFile.open(path: a.dir.walletFile, passphrase: Harness.passphrase);
    expect((await stored.keys.addressAt(0)).bytes, before.bytes);
  });

  group('a coordinator that declares an enormous reply', () {
    Future<Uint8List> Function(int) feeding(List<int> bytes) {
      var at = 0;
      return (n) async {
        final end = min(at + n, bytes.length);
        final out = Uint8List.fromList(bytes.sublist(at, end));
        at = end;
        return out;
      };
    }

    test('is discarded naming both sizes, with nothing of that size allocated', () async {
      // four gigabytes declared, and no body at all: a reader that trusted the
      // prefix would allocate for it before noticing
      final reads = <int>[];
      final source = feeding([0xff, 0xff, 0xff, 0xff]);
      await expectLater(
          BoundedFrames.read((n) {
            reads.add(n);
            return source(n);
          }, RicochetWalletTransport.maxReplyFrame, what: 'a reply from the pool'),
          throwsA(isA<FrameTooLong>()
              .having((e) => e.declared, 'declared', 0xffffffff)
              .having((e) => e.max, 'max', RicochetWalletTransport.maxReplyFrame)
              .having((e) => '$e', 'sentence', contains('discarded unread'))));
      expect(reads, [4], reason: 'only the length was read');
    });

    test('a frame inside the bound is read whole', () async {
      final body = List.generate(1000, (i) => i & 0xff);
      final got = await BoundedFrames.read(
          feeding(BoundedFrames.frame(Uint8List.fromList(body))), 2000, what: 'x');
      expect(got, body);
    });
  });

  group('the client above this program\'s wrappers', () {
    Transport wrapped(Transport t) => TimedTransport(DeadlineTransport(t, const Duration(seconds: 1)));

    test('Two submissions whose replies cross', () async {
      final t = fp.transport()..hold = true;
      final (client, _) = await CoordinatorClient.open(wrapped(t), timeout: const Duration(seconds: 5));
      final a = PoolSubmission.of(ShieldedTransfer.padding(fp.pool.spendP), fp.pool.spendP);
      final b = PoolSubmission.of(ShieldedTransfer.padding(fp.pool.spendP), fp.pool.spendP);
      final fa = client!.send(a), fb = client.send(b);
      while (t.held.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // the replies come back the other way round: b's to a's call, a's to b's
      t.held[0].$2.complete(PoolReply.accepted(b.id, 7).encode());
      t.held[1].$2.complete(PoolReply.accepted(a.id, 8).encode());
      final (ra, rb) = (await fa, await fb);
      expect(ra.id, a.id);
      expect(ra.round, 8);
      expect(rb.id, b.id);
      expect(rb.round, 7);
    });

    test('A coordinator speaking a later protocol', () async {
      final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys);
      addTearDown(h.dispose);
      await h.initWithPool();
      final t = fp.transport(rounds: 1, head: 1);
      final base = t.answer!;
      t.answer = (frame) async {
        final reply = await base(frame);
        return [PoolMessage.formatVersion + 1, ...reply.sublist(1)];
      };
      h.ports.transportPort = t;
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('speaks pool protocol version ${PoolMessage.formatVersion}'));
      expect(ran.err, contains('arrived at version ${PoolMessage.formatVersion + 1}'));
    });

    test('Mutated frames never crash the wallet', () async {
      final rng = Random(17);
      final sub = PoolSubmission.of(ShieldedTransfer.padding(fp.pool.spendP), fp.pool.spendP);
      final valid = PoolReply.accepted(sub.id, 3).encode();
      final head = fp.headReply(2).encode();
      var refused = 0, taken = 0;
      final steps = <String>{};
      // ten thousand replies to a submission, and five hundred head proofs,
      // which cost a parse of two round transactions each
      for (int i = 0; i < 10500; i++) {
        final isReply = i < 10000;
        final source = isReply ? valid : head;
        final bent = rng.nextBool()
            ? ([...source]..[rng.nextInt(source.length)] = rng.nextInt(256))
            : source.sublist(0, rng.nextInt(source.length));
        final t = FakeTransport(feed: [fp.pool.encode()])..answer = (_) => bent;
        final (client, _) = await CoordinatorClient.open(wrapped(t), timeout: const Duration(seconds: 1), sendAttempts: 1);
        if (isReply) {
          final out = await client!.send(sub);
          if (out.isAccepted) {
            taken++;
          } else {
            refused++;
            steps.add(out.refusal!.step);
          }
        } else {
          final checker = PaymentChecker(pool: fp.pool, headers: HeaderChecker(fp.headers(), confirmations: 1));
          final (got, why) = await client!.headProof(checker);
          if (got == null) {
            refused++;
            steps.add(why!.step);
          } else {
            taken++;
          }
        }
      }
      print('  10,000 mutated replies and 500 mutated head proofs: $refused refused, $taken taken, at '
          '${steps.length} steps');
      expect(refused + taken, 10500, reason: 'every one ended in an answer or a named refusal, none threw');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
