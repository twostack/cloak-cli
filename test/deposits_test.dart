import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libspiffy/libspiffy.dart' show BEEF, BUMP, beefMagicAndVersion;
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/fake_pool.dart';
import 'support/fake_transparent.dart';
import 'support/fakes.dart';
import 'support/harness.dart';

/// Money into the pool and back out: withdrawals, deposits and refunds.
void main() {
  late FakePool fp;
  setUpAll(() async => fp = await FakePool.build());
  final early = DateTime.utc(2023, 11, 1);
  final made = <Harness>[];
  tearDown(() {
    for (final h in made) {
      h.dispose();
    }
    made.clear();
  });

  /// A wallet holding the fixture's 500 from round 1, spendable.
  Future<Harness> payer() async {
    final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
    made.add(h);
    final init = await h.initWithPool();
    expect(init.code, Exit.done);
    File('${h.root.path}/seed').writeAsStringSync(init.out);
    h.ports.transportPort = fp.transport(rounds: 1, head: 1);
    expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
    await h.run(['invoice', 'new', '--amount', '500', '--expires', '60d', '--out', '${h.root.path}/own']);
    File('${h.root.path}/p').writeAsBytesSync(fp.standingProof(1).encode());
    expect((await h.run(['check', '${h.root.path}/p'])).code, Exit.done);
    return h;
  }

  final to = SVPrivateKey(networkType: NetworkType.TEST).toAddress(networkType: NetworkType.TEST);

  group('withdrawing', () {
    test('The withdrawal and the public amount agree', () async {
      final h = await payer();
      final t = fp.transport();
      h.ports.transportPort = t;
      final ran = await h.run(['withdraw', '--amount', '300', '--to', to.toBase58(), '--yes']);
      expect(ran.code, Exit.done, reason: '$ran');
      final sent = [for (final f in t.sent) PoolMessage.decode(f)].whereType<PoolSubmission>().single;
      final transfer = sent.transfer(fp.pool.spendP);
      expect(transfer.withdrawal!.satoshis, BigInt.from(300));
      expect(transfer.publics.publicOut, 300);
      expect(hex.encode(transfer.withdrawal!.pubkeyHash), to.pubkeyHash160, reason: 'paid to the address named');
      expect(transfer.verifyProof(fp.pool.spendP), isNull);

      // a transfer where the two differ is refused naming both
      final lying = ShieldedTransfer(transfer.publics, transfer.proof, transfer.bundle,
          withdrawal: PoolWithdrawal(transfer.withdrawal!.pubkeyHash, BigInt.from(250)));
      final why = WithdrawalBuilder.check(lying);
      expect(why, isNotNull);
      expect(why!.reason, contains('300'));
      expect(why.reason, contains('250'));
      final store = NoteStore.decode(File(h.dir.noteStore).readAsBytesSync(), shape: fp.shape);
      expect(store.notes.single.state, NoteState.reserved);
    });

    test('Withdrawing more than the note holds', () async {
      final h = await payer();
      final t = fp.transport();
      h.ports.transportPort = t;
      final ran = await h.run(['withdraw', '--amount', '600', '--to', to.toBase58(), '--yes']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('600'));
      expect(ran.err, contains('500'));
      expect(ran.err, contains('No proof was computed'));
      expect(t.sent, isEmpty);
    });

    test('The warning is shown, and nothing happens unconfirmed', () async {
      final h = await payer();
      final t = fp.transport();
      h.ports.transportPort = t;
      final unattended = await h.run(['withdraw', '--amount', '100', '--to', to.toBase58()]);
      expect(unattended.code, Exit.refused);
      expect(unattended.err, contains('public'));
      expect(unattended.err, contains('--yes'));
      h.terminal = (_) => 'n';
      final declined = await h.run(['withdraw', '--amount', '100', '--to', to.toBase58()]);
      expect(declined.code, Exit.refused);
      expect(declined.err, contains('not confirmed'));
      expect(t.sent, isEmpty);
      h.terminal = (_) => 'y';
      final ok = await h.run(['withdraw', '--amount', '100', '--to', to.toBase58()]);
      expect(ok.code, Exit.done, reason: '$ok');
    });
  });

  group('depositing', () {
    late FakeTransparentSide spiffy;

    Future<Harness> depositor({FakeHeaderSource? headers}) async {
      final h = await payer();
      spiffy = FakeTransparentSide();
      h.ports.transparentSide = spiffy;
      if (headers != null) h.ports.headerSource = headers;
      return h;
    }

    Map<String, Object?> state(Harness h) => jsonDecode(File(h.dir.state).readAsStringSync()) as Map<String, Object?>;
    Map<String, Object?> deposit0(Harness h) => (state(h)['deposits'] as List).first as Map<String, Object?>;

    test('Depositing against an unchecked view', () async {
      final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
      made.add(h);
      await h.initWithPool();
      h.ports.transportPort = fp.transport(catchUp: false);
      await h.run(['sync', '--from-genesis']);
      spiffy = FakeTransparentSide();
      h.ports.transparentSide = spiffy;
      final ran = await h.run(['deposit', '--amount', '500', '--yes']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('folded to round 2'));
      expect(ran.err, contains('checked to round 0'));
      expect(spiffy.calls, isEmpty, reason: 'nothing was spent');
    });

    test('The covenant names the round the wallet checked', () async {
      final h = await depositor();
      final ran = await h.run(['deposit', '--amount', '5000', '--yes', '--json']);
      expect(ran.code, Exit.done, reason: '$ran');
      final covenant = Transaction.fromHex(spiffy.broadcasts.single);
      final live = ShieldedPoolTool().getOutpoint(fp.c.r1.hash, outputIndex: 3);
      final found = ShieldedPoolTool.findDeposits([covenant], live, minRefundAfter: 0);
      expect(found, hasLength(1), reason: 'it names round 1\'s PP3, the round this wallet folded and checked');
      expect(found.single.receipt.satoshis, BigInt.from(5000));
      expect(deposit0(h)['intoRound'], 2);
    });

    test('a new pool\'s first deposit names the genesis PP3', () async {
      final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
      made.add(h);
      await h.initWithPool();
      h.ports.transportPort = fp.transport(rounds: 0);
      await h.run(['sync', '--from-genesis']);
      spiffy = FakeTransparentSide();
      h.ports.transparentSide = spiffy;
      final ran = await h.run(['deposit', '--amount', '5000', '--yes']);
      expect(ran.code, Exit.done, reason: '$ran');
      final covenant = Transaction.fromHex(spiffy.broadcasts.single);
      final genesis = ShieldedPoolTool().getOutpoint(fp.c.r0.hash, outputIndex: 3);
      expect(ShieldedPoolTool.findDeposits([covenant], genesis, minRefundAfter: 0), hasLength(1),
          reason: 'before round 1 the live PP3 is the issuance\'s');
      expect(deposit0(h)['intoRound'], 1);
    });

    test('The transfer\'s shape is checked before it is sent', () async {
      final h = await depositor();
      expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      final d = deposit0(h);
      final transfer = ShieldedTransfer.decode(hex.decode(d['transfer'] as String), fp.pool.spendP);
      expect(DepositBuilder.check(transfer), isNull, reason: 'both inputs dummy, BSV, money in');
      expect(transfer.publics.real1 || transfer.publics.real2, isFalse);
      expect(transfer.publics.publicOut, -5000);
      expect(transfer.verifyProof(fp.pool.spendP), isNull);
      // and a transfer with a real input beside a deposit is refused naming the rule
      final real = fp.c.f.transfers2.firstWhere((t) => t.publics.real1 || t.publics.real2);
      final beside = ShieldedTransfer(real.publics, real.proof, real.bundle,
          withdrawal: real.withdrawal, depositOutpoint: List.filled(36, 1));
      final why = DepositBuilder.check(beside);
      expect(why, isNotNull);
      expect(why!.reason, contains('real note beside a deposit'));
    });

    test('Submitted once mined', () async {
      final h = await depositor();
      expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      final txid = deposit0(h)['covenant'] as String;
      final status = await h.run(['status']);
      expect(status.out, contains('deposit $txid: broadcast'));
      expect(status.out, contains('refundable from block'));

      // not mined yet: the sync leaves it waiting and says so
      final t1 = fp.transport(rounds: 1, head: 1);
      h.ports.transportPort = t1;
      final early1 = await h.run(['sync']);
      expect(early1.code, Exit.done, reason: '$early1');
      expect(early1.out, contains('not mined yet'));
      expect(t1.sent.where((f) => PoolMessage.decode(f) is PoolSubmission), isEmpty);

      // mined: the next sync submits it, covenant attached
      spiffy.minedTxids.add(txid);
      final t2 = fp.transport(rounds: 1, head: 1, acceptInto: 2);
      h.ports.transportPort = t2;
      final later = await h.run(['sync']);
      expect(later.code, Exit.done, reason: '$later');
      final sub = [for (final f in t2.sent) PoolMessage.decode(f)].whereType<PoolSubmission>().single;
      expect(Transaction.fromHex(hex.encode(sub.depositTx!)).id, txid);
      expect(deposit0(h)['status'], 'accepted');
    });

    test('The person is told what they are risking, and The warning is shown', () async {
      final h = await depositor();
      final prompts = <String>[];
      h.terminal = (p) {
        prompts.add(p);
        return 'n';
      };
      final ran = await h.run(['deposit', '--amount', '5000']);
      expect(ran.code, Exit.refused);
      expect(ran.err, contains('5000 satoshis'));
      expect(ran.err, contains('round 2'));
      expect(ran.err, contains('refundable in full from block'));
      expect(ran.err, contains('public'));
      expect(prompts, hasLength(1), reason: 'it waited for confirmation');
      expect(spiffy.calls, isNot(contains('payTo')), reason: 'nothing was funded or broadcast unconfirmed');
    });

    test('A refund height too close to be included', () async {
      final h = await depositor();
      final tip = (await fp.headers().tip()).height;
      final ran = await h.run(['deposit', '--amount', '5000', '--yes', '--refund-height', '${tip + 10}']);
      expect(ran.code, Exit.refused);
      expect(ran.err, contains('block ${tip + 10}'));
      expect(ran.err, contains('earliest this wallet accepts is block ${tip + 100}'));
      expect(spiffy.calls, isNot(contains('payTo')));
    });

    test('Refunding too early, and refunding at the height', () async {
      final h = await depositor();
      expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      final d = deposit0(h);
      final txid = d['covenant'] as String;
      final tooEarly = await h.run(['refund', '--deposit', txid]);
      expect(tooEarly.code, Exit.refused);
      expect(tooEarly.err, contains('refundable from block ${d['refundAfter']}'));
      expect(tooEarly.err, contains('chain is at block ${(await fp.headers().tip()).height}'));

      // the chain reaches the height
      h.ports.headerSource = FakeHeaderSource.holding([List.filled(32, 3)], before: 3, after: 300);
      final ok = await h.run(['refund', '--deposit', txid, '--json']);
      expect(ok.code, Exit.done, reason: '$ok');
      final refund = Transaction.fromHex(spiffy.broadcasts.last);
      expect(refund.inputs.single.prevTxnId, txid);
      expect(refund.nLockTime, greaterThanOrEqualTo(d['refundAfter'] as int));
      expect(deposit0(h)['status'], 'refunded');
    });

    test('Refunding a deposit that was taken in', () async {
      final h = await depositor();
      expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      final txid = deposit0(h)['covenant'] as String;
      spiffy.minedTxids.add(txid);
      h.ports.transportPort = fp.transport(rounds: 1, head: 1, acceptInto: 2);
      expect((await h.run(['sync'])).code, Exit.done);
      // round 2 is announced and folded: the round took the deposit in
      h.ports.transportPort = fp.transport();
      await h.run(['sync']);
      h.ports.headerSource = FakeHeaderSource.holding([List.filled(32, 3)], before: 3, after: 300);
      final broadcasts = spiffy.broadcasts.length;
      final ran = await h.run(['refund', '--deposit', txid]);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('$txid:'));
      expect(ran.err, contains('already spent'));
      expect(spiffy.broadcasts, hasLength(broadcasts), reason: 'nothing was broadcast');
    });

    test('Killed between recording and broadcasting', () async {
      final h = await depositor();
      spiffy.failBroadcast = 'the process died here';
      final ran = await h.run(['deposit', '--amount', '5000', '--yes']);
      expect(ran.code, Exit.refused);
      final recorded = (state(h)['transparent'] as List).single as Map;
      expect(recorded['broadcast'], isFalse);
      final status = await h.run(['status']);
      expect(status.out, contains('${recorded['txid']}: recorded and not broadcast'));
      final again = await h.run(['deposit', '--broadcast', recorded['txid'] as String]);
      expect(again.code, Exit.done, reason: '$again');
      expect(spiffy.broadcasts.single, recorded['tx'], reason: 'sent as it was recorded, not rebuilt');
    });

    test('Killed after broadcasting', () async {
      final h = await depositor();
      expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      final first = FakeTransparentSide.fundingOf(spiffy.broadcasts.single);
      // the next run finds the record, and the coins it spent are held for it
      expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      final second = FakeTransparentSide.fundingOf(spiffy.broadcasts.last);
      expect(second, isNot(first), reason: 'no second deposit spends the same funding outpoint');
      expect((state(h)['deposits'] as List), hasLength(2));
    });

    test('Fresh addresses each time, and The two key trees are unrelated', () async {
      final h = await depositor();
      final seed = WalletSeed.fromHex((await _seedOf(h)));
      for (int i = 0; i < 2; i++) {
        expect((await h.run(['deposit', '--amount', '5000', '--yes'])).code, Exit.done);
      }
      final pkhs = <String>{};
      for (final tx in spiffy.broadcasts) {
        final t = Transaction.fromHex(tx);
        final found = ShieldedPoolTool.findDeposits([t], ShieldedPoolTool().getOutpoint(fp.c.r1.hash, outputIndex: 3), minRefundAfter: 0);
        final script = t.outputs[found.single.vout].script.buffer;
        pkhs.add(hex.encode(script));
      }
      expect(pkhs, hasLength(2), reason: 'two covenants, two refund keys');
      final sealed = await SealedStore.open(h.dir, seed);
      final refunds = [for (final e in (await sealed.getAll()).entries) if (e.key.startsWith('refund/')) e.value];
      expect(refunds.toSet(), hasLength(2));
      final keys = WalletKeys(seed: seed, birthday: 0);
      for (final wif in refunds) {
        final k = SVPrivateKey.fromWIF(wif);
        final kb = hex.decode(k.toHex()).toString();
        for (final derived in [seed.bytes, seed.expand('tsl1-libcloak/derivation/1/sk', 32), keys.ivk, keys.nk]) {
          expect(kb, isNot(derived.toString()), reason: 'a refund key is generated, not derived from the seed');
        }
      }
    });

    test('An over-long deposit transaction', () async {
      final h = await depositor();
      spiffy.padding = PoolMessage.maxDepositTx;
      final ran = await h.run(['deposit', '--amount', '5000', '--yes']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('${PoolMessage.maxDepositTx}'));
      expect(spiffy.broadcasts, isEmpty);
      expect(spiffy.held, isEmpty, reason: 'its coins were given back');
    });

    test('Building a deposit inside the bound', () async {
      final times = <int>[];
      for (int i = 0; i < 3; i++) {
        final h = await depositor();
        final ran = await h.run(['deposit', '--amount', '5000', '--yes', '--json']);
        expect(ran.code, Exit.done, reason: '$ran');
        final clock = (jsonDecode(ran.out) as Map)['clockMs'] as Map;
        times.add(clock['building'] as int);
        print('  deposit: $clock');
      }
      times.sort();
      print('  building a deposit outside the spend proof and the network, best of 3: ${times.first} ms');
      expect(times.first, lessThan(500));
    }, tags: ['perf']);
  });

  group('receiving', () {
    List<int> beefAt(int height) {
      final tx = hex.decode(fp.c.w1.serialize());
      final txid = Uint8List.fromList(hex.decode(fp.c.w1.id).reversed.toList());
      return BEEF(
          version: beefMagicAndVersion,
          bumps: [BUMP.fromMerklePath(blockHeight: height, txid: txid, index: 0, siblings: const [])],
          txs: [Uint8List.fromList(tx)],
          hasMerkle: const [true],
          bumpIndex: const [0]).serialize();
    }

    test('A payment whose block the wallet has not reached', () async {
      final h = await payer();
      final spiffy = FakeTransparentSide()..parkReceives = true;
      final headers = fp.headers();
      h.ports
        ..transparentSide = spiffy
        ..headerSource = headers;
      File('${h.root.path}/beef').writeAsStringSync(hex.encode(beefAt(5000)));
      headers.calls.clear();
      final ran = await h.run(['receive', '${h.root.path}/beef', '--json']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect((jsonDecode(ran.out) as Map)['waitingFor'], 5000);
      expect(headers.calls, ['tip'], reason: 'the block it waits for is never asked about');
    });

    test('A payment with a bad merkle proof', () async {
      final h = await payer();
      h.ports.transparentSide = FakeTransparentSide()..refuseReceives = 'the merkle proof does not reach the header at height 5';
      File('${h.root.path}/beef').writeAsStringSync(hex.encode(beefAt(5)));
      final ran = await h.run(['receive', '${h.root.path}/beef']);
      expect(ran.code, Exit.refused);
      expect(ran.err, contains('refused at "BEEF"'));
      expect(ran.err, contains('merkle proof'));
    });

    test('The hex typed on the command line', () async {
      final h = await payer();
      final spiffy = FakeTransparentSide();
      h.ports.transparentSide = spiffy;
      final ran = await h.run(['receive', hex.encode(beefAt(5)), '--json']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(spiffy.calls, contains('receive'));
    });

    test('A file of pasted hex, line breaks and all', () async {
      final h = await payer();
      h.ports.transparentSide = FakeTransparentSide();
      final text = hex.encode(beefAt(5)).toUpperCase();
      final lines = [for (int i = 0; i < text.length; i += 64) text.substring(i, min(i + 64, text.length))];
      File('${h.root.path}/payment.txt').writeAsStringSync('${lines.join('\r\n')}\n');
      final ran = await h.run(['receive', '${h.root.path}/payment.txt']);
      expect(ran.code, Exit.done, reason: '$ran');
    });

    test('A file that is not hex is refused, naming where', () async {
      final h = await payer();
      h.ports.transparentSide = FakeTransparentSide();
      File('${h.root.path}/payment.beef').writeAsBytesSync(beefAt(5));
      final ran = await h.run(['receive', '${h.root.path}/payment.beef']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "BEEF"'));
      expect(ran.err, contains('is not BEEF hex: it has a byte 0x01 at character 1'));
    });

    group('by txid, from a BEEF service', () {
      late HttpServer service;
      final answers = <String, (int, Object)>{};
      final asked = <String>[];
      setUpAll(() async {
        service = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        service.listen((q) {
          final txid = q.uri.pathSegments.last;
          asked.add(txid);
          final (status, body) = answers[txid] ?? (400, {'error': 'no raw tx associated with that txid', 'txid': txid});
          q.response
            ..statusCode = status
            ..headers.contentType = ContentType.json
            ..write(body is String ? body : jsonEncode(body))
            ..close();
        });
      });
      tearDownAll(() => service.close(force: true));
      setUp(asked.clear);

      Future<Harness> served() async {
        final h = await payer();
        h.ports.transparentSide = FakeTransparentSide();
        final config = File(h.dir.config);
        config.writeAsStringSync(config
            .readAsStringSync()
            .replaceFirst('  url: ${CloakConfig.defaultBeefService}', '  url: http://127.0.0.1:${service.port}/'));
        return h;
      }

      test('The BEEF is asked for by its txid, and checked like any other', () async {
        final h = await served();
        answers[fp.c.w1.id] = (200, {'beef': hex.encode(beefAt(5))});
        final ran = await h.run(['receive', '--txid', fp.c.w1.id.toUpperCase()]);
        expect(ran.code, Exit.done, reason: '$ran');
        expect(asked, [fp.c.w1.id], reason: 'asked once, about that transaction and nothing else');
        expect(ran.out, contains('the BEEF came from http://127.0.0.1:${service.port}/'));
        expect((h.ports.transparentSide as FakeTransparentSide).calls, contains('receive'));
      });

      test('A service that has no BEEF for it says why', () async {
        final h = await served();
        final ran = await h.run(['receive', '--txid', '00' * 32]);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('refused at "BEEF service"'));
        expect(ran.err, contains('answered HTTP 400: '));
        expect(ran.err, contains('no raw tx associated with that txid'));
      });

      test('A BEEF for another transaction is refused', () async {
        final h = await served();
        answers['11' * 32] = (200, {'beef': hex.encode(beefAt(5))});
        final ran = await h.run(['receive', '--txid', '11' * 32]);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('does not hold that transaction'));
        expect((h.ports.transparentSide as FakeTransparentSide).calls, isNot(contains('receive')));
      });

      test('An answer that is not BEEF hex, or not JSON', () async {
        final h = await served();
        answers['22' * 32] = (200, {'beef': 'not hex at all'});
        answers['33' * 32] = (200, '<html>a page</html>');
        final notHex = await h.run(['receive', '--txid', '22' * 32]);
        expect(notHex.err, contains('is not BEEF hex'));
        final notJson = await h.run(['receive', '--txid', '33' * 32]);
        expect(notJson.err, contains('no JSON'));
      });

      test('A txid and the BEEF both, or a txid that is not one', () async {
        final h = await served();
        expect((await h.run(['receive', hex.encode(beefAt(5)), '--txid', fp.c.w1.id])).code, Exit.usage);
        final ran = await h.run(['receive', '--txid', 'abc']);
        expect(ran.code, Exit.refused);
        expect(ran.err, contains('is not a txid'));
        expect(asked, isEmpty, reason: 'nothing is asked about a malformed txid');
      });

      test('A plaintext service is refused, unless it is on this machine', () async {
        final h = await served();
        final config = File(h.dir.config);
        config.writeAsStringSync(
            config.readAsStringSync().replaceFirst(RegExp(r'  url: http://127\.0\.0\.1:\d+/'), '  url: http://beef.example'));
        final ran = await h.run(['receive', '--txid', fp.c.w1.id]);
        expect(ran.code, Exit.refused);
        expect(ran.err, contains('beef.url as http://beef.example'));
      });
    });

    test('Neither a file nor hex', () async {
      final h = await payer();
      h.ports.transparentSide = FakeTransparentSide();
      for (final (given, says) in [
        ('payment.beef', 'there is no file named "payment.beef", and it is not BEEF hex either'),
        ('${hex.encode(beefAt(5))}0', 'odd number of hex digits'),
      ]) {
        final ran = await h.run(['receive', given]);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains(says), reason: given);
      }
    });

    test('Mutated BEEF never crashes the wallet', () async {
      final h = await payer();
      h.ports.transparentSide = FakeTransparentSide();
      final valid = beefAt(5);
      final rng = Random(31);
      final steps = <String>{};
      var taken = 0;
      for (int i = 0; i < 1000; i++) {
        final bent = rng.nextBool()
            ? ([...valid]..[rng.nextInt(valid.length)] = rng.nextInt(256))
            : valid.sublist(0, rng.nextInt(valid.length));
        File('${h.root.path}/beef').writeAsStringSync(hex.encode(bent));
        final ran = await h.run(['receive', '${h.root.path}/beef']);
        expect(ran.code, lessThanOrEqualTo(Exit.refused), reason: '$ran');
        expect(ran.err, isNot(contains('refused at "unexpected"')), reason: '$ran');
        if (ran.code == Exit.done) {
          taken++;
        } else {
          steps.add(RegExp(r'refused at "([^"]+)"').firstMatch(ran.err)!.group(1)!);
        }
      }
      print('  1,000 mutated BEEF payments: $taken read, ${1000 - taken} refused at ${steps.join(', ')}');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

Future<String> _seedOf(Harness h) async => File('${h.root.path}/seed').readAsStringSync().trim();
