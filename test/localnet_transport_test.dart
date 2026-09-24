@Tags(['localnet'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:pool_coordinator/pool_coordinator.dart' as co;
import 'package:test/test.dart';

import 'support/fake_pool.dart';
import 'support/ricochet_server.dart';

/// The wallet's transport against a real ricochet server, with the
/// coordinator's own transport on the other side of it.
///
///   POOL_LOCALNET=1 dart test test/localnet_transport_test.dart
void main() async {
  final skip = Platform.environment['POOL_LOCALNET'] == null
      ? 'needs ../localnet up; set POOL_LOCALNET=1'
      : await RicochetTestServer.available();

  group('over ricochet', () {
    late RicochetTestServer server;
    late co.RicochetTransport coordinator;
    late FakePool fp;
    final rng = Random(29);
    Uint8List seed() => Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)));

    setUpAll(() async {
      fp = await FakePool.build();
      server = (await RicochetTestServer.start())!;
      coordinator = await co.RicochetTransport.connect(seed: seed(), server: server.address);
      await coordinator.ensureFeed();
    });
    tearDownAll(() async {
      await coordinator.close();
      await server.dispose();
    });

    Future<RicochetWalletTransport> wallet() => RicochetWalletTransport.connect(
        seed: seed(), server: server.address, coordinator: coordinator.peerId, timeout: const Duration(seconds: 5));

    test('The transport does not read messages', () async {
      final t = await wallet();
      addTearDown(t.close);
      final frame = utf8.encode('not a pool message at all');
      // the coordinator side takes whatever arrives and answers with bytes
      // that are not a pool message either
      final answering = () async {
        for (int i = 0; i < 50; i++) {
          final got = await coordinator.drain();
          if (got.isNotEmpty) {
            await coordinator.delivered([for (final m in got) m.id]);
            expect(got.single.payload, frame, reason: 'delivered as it was sent');
            expect(got.single.sender, t.peerId);
            await coordinator.reply(got.single.sender, Uint8List.fromList([7, 7, 7]));
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        fail('nothing arrived');
      }();
      final back = await t.request(frame, timeout: const Duration(seconds: 5));
      await answering;
      expect(back, [7, 7, 7], reason: 'whatever came back, unread');

      // and the refusal comes from the client above it, naming the field
      final (client, why) = await CoordinatorClient.open(t);
      expect(client, isNull);
      expect(why!.step, isNotEmpty);
    });

    test('a reply after its caller gave up is kept, and the next frame is still sent', () async {
      final t = await wallet();
      addTearDown(t.close);
      Future<({Uint8List payload, String sender})> next() async {
        for (int i = 0; i < 50; i++) {
          final got = await coordinator.drain();
          if (got.isNotEmpty) {
            await coordinator.delivered([for (final m in got) m.id]);
            return (payload: got.single.payload, sender: got.single.sender);
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        fail('nothing arrived');
      }

      // the caller holds a request to twice its timeout, as libcloak does
      const timeout = Duration(seconds: 1);
      final first = t.request([1], timeout: timeout).timeout(timeout * 2);
      final a = await next();
      await expectLater(first, throwsA(isA<TimeoutException>()));
      // answered only once nobody waits for it
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await coordinator.reply(a.sender, Uint8List.fromList([11]));
      await Future<void>.delayed(const Duration(seconds: 2));

      // the late reply was not taken by the abandoned wait
      expect(await t.drainReplies(), [
        [11]
      ]);

      // and the next request goes out, and is answered by its own reply
      final second = t.request([2], timeout: timeout);
      final b = await next();
      expect(b.payload, [2], reason: 'the frame was sent');
      await coordinator.reply(b.sender, Uint8List.fromList([22]));
      expect(await second, [22]);
    });

    test('A hundred entries inside the bound', () async {
      final entries = [fp.pool.encode(), for (int i = 0; i < 100; i++) fp.ann1.encode()];
      final start = (await coordinator.feedLength()) + 1;
      for (final e in entries) {
        await coordinator.announce(Uint8List.fromList(e));
      }
      final t = await wallet();
      addTearDown(t.close);
      final times = <int>[];
      for (int i = 0; i < 3; i++) {
        final sw = Stopwatch()..start();
        final got = await t.readFeed(start + 1, max: 100);
        times.add(sw.elapsedMilliseconds);
        expect(got, hasLength(100));
        expect(got.first.sequence, start + 1);
        expect(got.every((e) => e.bytes.length == fp.ann1.encode().length), isTrue);
      }
      times.sort();
      print('  a hundred feed entries over ricochet: best ${times.first} ms, worst ${times.last} ms');
      expect(times.first, lessThan(5000));
    }, tags: ['perf']);
  }, skip: skip);
}
