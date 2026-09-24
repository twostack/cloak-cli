import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/fake_pool.dart';
import 'support/fakes.dart';
import 'support/harness.dart';

/// Invoices, payments, checks and acknowledgements, driven through the
/// commands against the fake pool.
///
/// The fixture's notes are paid to its wallet's address 0, so every wallet
/// here stands the fixture's pool keys in for its seed's, and a wallet's
/// first invoice is always to that address. A payer is made by issuing
/// itself an invoice and checking the fixture's round 1 proof against it,
/// which is how money reaches a wallet: handed over with its proof.
void main() {
  late FakePool fp;
  setUpAll(() async => fp = await FakePool.build());

  // the fixture's blocks are stamped 2023-11-14, and an acknowledgement is
  // against the block's own clock, so the suite's clock stands just before
  final early = DateTime.utc(2023, 11, 1, 12);
  final made = <Harness>[];
  tearDown(() {
    for (final h in made) {
      h.dispose();
    }
    made.clear();
  });

  Future<Harness> wallet({FakeHeaderSource? headers}) async {
    final h = Harness.make(ports: CountingPorts(headerSource: headers ?? fp.headers()), poolKeys: fp.keys, now: early);
    made.add(h);
    expect((await h.initWithPool()).code, Exit.done);
    final config = File(h.dir.config);
    config.writeAsStringSync(config.readAsStringSync().replaceFirst('timeout_seconds: 30', 'timeout_seconds: 1'));
    return h;
  }

  /// A wallet whose view stands checked at round 1.
  Future<Harness> synced() async {
    final h = await wallet();
    h.ports.transportPort = fp.transport(rounds: 1, head: 1);
    final ran = await h.run(['sync', '--from-genesis']);
    expect(ran.code, Exit.done, reason: '$ran');
    return h;
  }

  String file(Harness h, String name) => '${h.root.path}/$name';

  Future<String> invoice(Harness h, int amount, {String name = 'i', List<String> extra = const []}) async {
    final ran = await h.run(['invoice', 'new', '--amount', '$amount', '--expires', '60d', '--out', file(h, name), ...extra]);
    expect(ran.code, Exit.done, reason: '$ran');
    return file(h, name);
  }

  Future<String> proof1(Harness h) async {
    final p = file(h, 'round1.proof');
    File(p).writeAsBytesSync(fp.standingProof(1).encode());
    return p;
  }

  /// A wallet holding the fixture's 500 from round 1, spendable.
  Future<Harness> payer() async {
    final h = await synced();
    await invoice(h, 500, name: 'own');
    final took = await h.run(['check', await proof1(h)]);
    expect(took.code, Exit.done, reason: '$took');
    return h;
  }

  Map<String, Object?> json(Ran r) => jsonDecode(r.out) as Map<String, Object?>;

  NoteStore store(Harness h) => NoteStore.decode(File(h.dir.noteStore).readAsBytesSync(), shape: fp.shape);

  Future<Ran> pay(Harness h, String invoiceFile, FakeTransport t) {
    h.ports.transportPort = t;
    return h.run(['pay', '--json', invoiceFile]);
  }

  group('invoices', () {
    test('Two invoices, two addresses', () async {
      final h = await synced();
      final a = Invoice.decode(File(await invoice(h, 10, name: 'a')).readAsBytesSync());
      final b = Invoice.decode(File(await invoice(h, 10, name: 'b')).readAsBytesSync());
      expect(a.address.bytes, isNot(b.address.bytes));
      expect(a.id, isNot(b.id));
      expect(h.ports.transportOpens, 1, reason: 'the sync; an invoice needs no pool');
    });

    test('A memo too large', () async {
      final h = await synced();
      // 200 characters, 600 bytes: the limit is in bytes
      final memo = '€' * 200;
      final ran = await h.run(['invoice', 'new', '--amount', '5', '--memo', memo, '--out', file(h, 'x')]);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "memo"'));
      expect(ran.err, contains('600 bytes'));
      expect(ran.err, contains('${Invoice.maxMemo}'));
      expect(File(file(h, 'x')).existsSync(), isFalse);
      final after = await h.run(['invoice', 'new', '--amount', '5', '--out', file(h, 'y')]);
      expect(Invoice.decode(File(file(h, 'y')).readAsBytesSync()).address.d, PoolHash.diversifier(fp.keys.ivk, 0),
          reason: 'the refused invoice burned no address: $after');
    });

    test('An invoice from a later version', () async {
      final h = await synced();
      final path = await invoice(h, 10);
      final bytes = File(path).readAsBytesSync()..[0] += 1;
      File(path).writeAsBytesSync(bytes);
      final ran = await h.run(['invoice', 'show', path]);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('writes invoice version ${Invoice.version}'));
      expect(ran.err, contains('does not read ${Invoice.version + 1}'));
    });

    test('An invoice for another pool', () async {
      final h = await payer();
      final other = await Invoice.issue(
          tokenId: List.filled(32, 7),
          ivk: fp.keys.ivk,
          address: await NoteAddress.at(fp.keys.ivk, 5),
          amount: 10,
          expiry: early.add(const Duration(days: 1)));
      File(file(h, 'other')).writeAsBytesSync(other.encode());
      for (final args in [['invoice', 'show', file(h, 'other')], ['pay', file(h, 'other')]]) {
        final ran = await h.run(args);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('refused at "pool"'));
        expect(ran.err, contains(shortHex(List.filled(32, 7))));
        expect(ran.err, contains(shortHex(fp.pool.tokenId)));
      }
    });
  });

  group('paying', () {
    test('An expired invoice costs nothing', () async {
      final payee = await synced();
      final path = await invoice(payee, 100, extra: ['--expires', '1m']);
      final h = await payer();
      h.now = early.add(const Duration(hours: 1));
      final t = fp.transport();
      final journalBefore = Directory(h.dir.journal).listSync().length;
      final ran = await pay(h, path, t);
      expect(ran.code, Exit.refused, reason: 'a refusal and not a usage error: $ran');
      expect(ran.err, contains('refused at "expiry"'));
      expect(t.sent, isEmpty, reason: 'nothing was sent');
      expect(Directory(h.dir.journal).listSync().length, journalBefore, reason: 'nothing was built');
      expect(store(h).notes.single.state, NoteState.proven);
    });

    test('The four answers move the note four ways', () async {
      final answers = <String, List<int> Function(PoolSubmission)>{
        'accepted': (s) => PoolReply.accepted(s.id, 3).encode(),
        'refused': (s) => PoolReply.refused(s.id, RefusalReason.anchor, 'the anchor is not in the ring').encode(),
        'expired': (s) => PoolReply.expired(s.id, 'held until it was too old').encode(),
      };
      final got = <String, NoteState>{};
      for (final e in answers.entries) {
        final h = await payer();
        final path = await invoice(await synced(), 200);
        final t = fp.transport()..answer = (f) => e.value(PoolMessage.decode(f) as PoolSubmission);
        final ran = await pay(h, path, t);
        expect(ran.code, e.key == 'accepted' ? Exit.done : Exit.refused, reason: '${e.key}: $ran');
        got[e.key] = store(h).notes.single.state;
      }
      // unanswered: the transport takes the frame and never comes back
      final h = await payer();
      final path = await invoice(await synced(), 200);
      final t = fp.transport()..hold = true;
      final sw = Stopwatch()..start();
      final ran = await pay(h, path, t);
      sw.stop();
      expect(ran.code, Exit.refused);
      expect(ran.err, contains('refused at "no answer"'));
      got['unanswered'] = store(h).notes.single.state;

      expect(got, {
        'accepted': NoteState.reserved,
        'refused': NoteState.proven,
        'expired': NoteState.proven,
        'unanswered': NoteState.reserved,
      });
      // A transport that never returns: back within twice the timeout
      expect(sw.elapsed, lessThan(const Duration(seconds: 2 * 1 + 2)), reason: 'the second deadline held');
    });

    test('The coordinator goes quiet after taking a submission', () async {
      final h = await payer();
      final path = await invoice(await synced(), 200);
      final ran = await pay(h, path, fp.transport()..hold = true);
      expect(ran.code, Exit.refused);
      expect(ran.err, contains('may still be in a round'));
      expect(ran.err, contains('cloak sync'));
      expect(store(h).notes.single.state, NoteState.reserved);
      final journal = await h.run(['journal', '--json']);
      final entries = json(journal)['entries'] as List<Object?>;
      expect(entries.map((e) => (e as Map)['outcome']), contains('unanswered'));
    });

    test('A reply for a submission never sent', () async {
      final h = await payer();
      final path = await invoice(await synced(), 200);
      final t = fp.transport()..answer = (f) => PoolReply.accepted(List.filled(16, 9), 3).encode();
      final ran = await pay(h, path, t);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('not one this client is waiting for'));
      expect(store(h).notes.single.state, NoteState.reserved, reason: 'nothing was recorded against the payment');
    });

    test('Retried sends carry one id', () async {
      final h = await payer();
      final path = await invoice(await synced(), 200);
      final t = fp.transport()..failFirst = 2;
      final ran = await pay(h, path, t);
      expect(ran.code, Exit.done, reason: '$ran');
      final submissions = [for (final f in t.sent) if (PoolMessage.decode(f) is PoolSubmission) f];
      expect(submissions, hasLength(3));
      expect(submissions[1], submissions[0]);
      expect(submissions[2], submissions[0]);
    });

    test('A second payment cannot pick the same note', () async {
      final h = await payer();
      expect((await pay(h, await invoice(await synced(), 200), fp.transport())).code, Exit.done);
      final t = fp.transport();
      final ran = await pay(h, await invoice(await synced(), 100, name: 'second'), t);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('leaf ${fp.note1.position}'));
      expect(ran.err, contains('reserved'));
      expect(t.sent, isEmpty, reason: 'no spend proof, and nothing sent');
    });

    test('Two payments at once', () async {
      final h = await payer();
      final config = File(h.dir.config);
      config.writeAsStringSync(config.readAsStringSync().replaceFirst('timeout_seconds: 1', 'timeout_seconds: 10'));
      final a = await invoice(await synced(), 200), b = await invoice(await synced(), 100);
      // the pool takes three seconds to answer, so the first payment is still in
      // flight when the second has waited out the lock's two
      h.ports.transportPort = _Slow(fp.transport(), const Duration(seconds: 3));
      final both = await Future.wait([h.run(['pay', a]), h.run(['pay', b])]);
      final codes = both.map((r) => r.code).toList()..sort();
      expect(codes, [Exit.done, Exit.refused], reason: '$both');
      expect(both.firstWhere((r) => r.code == Exit.refused).err, contains('refused at "lock"'));
      expect(store(h).notes.where((n) => n.state == NoteState.reserved), hasLength(1));
    });

    test('Non-interactive use works without a terminal', () async {
      final h = await payer();
      h.terminal = null;
      expect(h.env[passphraseEnv], isNotNull);
      final ran = await pay(h, await invoice(await synced(), 200), fp.transport());
      expect(ran.code, Exit.done, reason: '$ran');
    });

    test('The view refuses to spend while unchecked', () async {
      final h = await wallet();
      h.ports.transportPort = fp.transport(catchUp: false);
      expect((await h.run(['sync', '--from-genesis'])).code, Exit.refused, reason: 'folded, not checked');
      await invoice(h, 500, name: 'own');
      final took = await h.run(['check', await proof1(h)]);
      expect(took.code, Exit.done, reason: '$took');
      final t = fp.transport();
      final ran = await pay(h, await invoice(await synced(), 200), t);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "unchecked"'));
      expect(ran.err, contains('folded to round 2'));
      expect(ran.err, contains('round 0'));
      expect(t.sent, isEmpty);
    });

    test('A held note after a catch-up', () async {
      final h = await payer();
      // the pool has moved on to round 2 and its feed says nothing: the wallet
      // catches up by the published run, folding every round
      h.ports.transportPort = fp.transport(feed: [fp.pool.encode()]);
      final synced2 = await h.run(['sync', '--json']);
      expect(synced2.code, Exit.done, reason: '$synced2');
      expect(json(synced2)['round'], 2);
      final ran = await pay(h, await invoice(await synced(), 200), fp.transport());
      expect(ran.code, Exit.done, reason: 'built with no refusal at the anchor: $ran');
    });

    test('The host\'s share of a payment', () async {
      final shares = <int>[];
      for (int i = 0; i < 3; i++) {
        final h = await payer();
        final ran = await pay(h, await invoice(await synced(), 200), fp.transport());
        expect(ran.code, Exit.done, reason: '$ran');
        final clock = json(ran)['clockMs'] as Map<String, Object?>;
        shares.add(clock['host'] as int);
        print('  pay: $clock');
      }
      shares.sort();
      print('  the host\'s share of cloak pay, best of 3: ${shares.first} ms (worst ${shares.last})');
      expect(shares.first, lessThan(108));
    }, tags: ['perf']);
  });

  group('checking and acknowledging', () {
    test('Checking a payment makes no request', () async {
      final h = await synced();
      await invoice(h, 500);
      final opensBefore = h.ports.transportOpens;
      final headers = h.ports.headerSource as FakeHeaderSource..calls.clear();
      final ran = await h.run(['check', '--json', await proof1(h)]);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(h.ports.transportOpens, opensBefore, reason: 'the pool is not asked');
      expect(headers.calls.every((c) => c == 'tip' || c.startsWith('heightOfBlock') || c.startsWith('headerAtHeight')),
          isTrue,
          reason: 'the header source was asked its three questions from headers it holds: ${headers.calls}');
      // A proof claiming its own depth: the depth is this chain's
      final tip = (await headers.tip()).height;
      expect(json(ran)['confirmations'], tip - fp.block1.height + 1);
    });

    test('A block the chain has not reached', () async {
      final short = FakeHeaderSource.holding([hex.decode(fp.c.w2.id)], before: 3, after: 6);
      final h = await wallet(headers: short);
      h.ports.transportPort = fp.transport(rounds: 0, catchUp: false);
      expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
      await invoice(h, 500);
      final ran = await h.run(['check', await proof1(h)]);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "block"'));
      expect(ran.err, contains('ends at height ${(await short.tip()).height}'));
      expect(ran.err, contains('run cloak sync'));
      expect(File(h.dir.noteStore).existsSync(), isFalse, reason: 'no note taken');
    });

    test('A proof shorter than it claims', () async {
      final h = await synced();
      await invoice(h, 500);
      final whole = fp.standingProof(1).encode();
      final rng = Random(7);
      final cut = file(h, 'cut');
      final steps = <String>{};
      for (int i = 0; i < 100; i++) {
        File(cut).writeAsBytesSync(whole.sublist(0, rng.nextInt(whole.length)));
        final ran = await h.run(['check', cut]);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('refused at "'));
        expect(ran.err, isNot(contains('refused at "unexpected"')), reason: '$ran');
        steps.add(RegExp(r'refused at "([^"]+)"').firstMatch(ran.err)!.group(1)!);
      }
      print('  100 truncated proofs refused at: ${steps.join(', ')}');
      expect(File(h.dir.noteStore).existsSync(), isFalse);
    });

    test('A proof that does not check out: a round with a forged lineage', () async {
      final (forged, chain) = fp.forgery();
      final h = await wallet(headers: chain);
      h.ports.transportPort = fp.transport(rounds: 0, catchUp: false);
      expect((await h.run(['sync', '--from-genesis'])).code, Exit.done);
      await invoice(h, 500);
      File(file(h, 'forged')).writeAsBytesSync(forged.encode());
      final ran = await h.run(['check', file(h, 'forged')]);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "PP1 is this pool\'s script"'));
      expect(ran.err, contains('not its body'), reason: 'the checker\'s own sentence');
      expect(File(h.dir.noteStore).existsSync(), isFalse, reason: 'no note is added to the store');
      final j = json(await h.run(['journal', '--json']));
      expect(jsonEncode(j['entries']), contains('PP1 is this pool'), reason: 'the refusal is on the record');
    });

    test('A payment that arrived late', () async {
      final h = await synced();
      // the invoice expires before the block holding the payment was mined
      final path = await invoice(h, 200, extra: ['--expires', '2023-11-10T00:00:00Z']);
      expect(path, isNotEmpty);
      expect((await h.run(['check', await proof1(h)])).code, Exit.done);
      final ran = await h.run(['ack', await proof1(h), '--out', file(h, 'ack')]);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "expiry"'));
      expect(ran.err, contains('2023-11-10'));
      expect(ran.err, contains('2023-11-14'));
      expect(store(h).notes.single.state, NoteState.proven, reason: 'refusing to sign is not refusing the money');
    });

    test('an acknowledgement, signed and checked; the wrong invoice; a forgery; the threads', () async {
      // the payee issues, the payer pays, the payee checks and acknowledges
      final payee = await synced();
      final inv = await invoice(payee, 200);
      final payer_ = await payer();
      expect((await pay(payer_, inv, fp.transport())).code, Exit.done);
      // the payee is handed the fixture's round 1 proof: see the seam named at
      // the top of this file and in the design record
      final proof = await proof1(payee);
      expect((await payee.run(['check', proof])).code, Exit.done);
      final ack = await payee.run(['ack', proof, '--out', file(payee, 'ack')]);
      expect(ack.code, Exit.done, reason: '$ack');

      final id = hex.encode(Invoice.decode(File(inv).readAsBytesSync()).id);
      final ackCopy = file(payer_, 'ack');
      File(file(payee, 'ack')).copySync(ackCopy);
      final ok = await payer_.run(['ack', '--check', ackCopy, '--invoice', id]);
      expect(ok.code, Exit.done, reason: '$ok');

      // Two encodings agree
      final bytes = File(ackCopy).readAsBytesSync();
      expect(Acknowledgement.decode(bytes).encode(), bytes);

      // A forged acknowledgement
      final forged = file(payer_, 'forged');
      File(forged).writeAsBytesSync([...bytes]..[bytes.length - 1] ^= 1);
      final bad = await payer_.run(['ack', '--check', forged, '--invoice', id]);
      expect(bad.code, Exit.refused);
      expect(bad.err, contains('refused at "signature"'));
      expect(bad.err, contains('does not verify under the key invoice'));

      // An acknowledgement for the wrong invoice: another payee's, for another
      // invoice, checked against this one
      final other = await synced();
      await invoice(other, 200);
      await other.run(['check', await proof1(other)]);
      expect((await other.run(['ack', await proof1(other), '--out', file(other, 'ack')])).code, Exit.done);
      final otherId = Acknowledgement.decode(File(file(other, 'ack')).readAsBytesSync()).invoiceId;
      final wrong = await payer_.run(['ack', '--check', file(other, 'ack'), '--invoice', id]);
      expect(wrong.code, Exit.refused);
      expect(wrong.err, contains(shortHex(otherId)));
      expect(wrong.err, contains(shortHex(hex.decode(id))));

      // A thread for one invoice
      Future<List<String>> thread(Harness h) async {
        final j = json(await h.run(['journal', '--json', '--invoice', id]));
        return [for (final e in j['entries'] as List<Object?>) (e as Map)['kind'] as String];
      }

      expect(await thread(payee), ['invoiceIssued', 'proofChecked', 'acknowledgementSent']);
      expect(await thread(payer_), [
        'invoiceReceived',
        'paymentBuilt',
        'paymentSubmitted',
        'paymentAnswered',
        'acknowledgementReceived',
        'acknowledgementReceived',
        'acknowledgementReceived',
      ]);

      // The wallet directory holds no nullifiers
      final spent = NoteOpening.of(fp.note1.note);
      final nf = PoolHash.nullifierFromNk(fp.keys.nk, spent.rho);
      final nfBytes = BlockFold.lanesToBytes(nf);
      for (final f in Directory(payer_.wallet).listSync(recursive: true).whereType<File>()) {
        final b = f.readAsBytesSync();
        expect(_holds(b, nfBytes), isFalse, reason: '${f.path} holds the spent note\'s nullifier');
        expect(latin1.decode(b).contains(hex.encode(nfBytes)), isFalse, reason: '${f.path} holds it in hex');
      }
    });

    test('An edited journal is refused, not repaired', () async {
      final h = await synced();
      await invoice(h, 10, name: 'a');
      await invoice(h, 20, name: 'b');
      final entries = Directory(h.dir.journal).listSync().whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
      final victim = entries.first;
      victim.writeAsBytesSync([1, 99, 3]);
      final ran = await h.run(['journal', '--json']);
      expect(ran.code, Exit.done, reason: '$ran');
      final j = json(ran);
      expect((j['entries'] as List).length, 1, reason: 'the rest still shows');
      expect(jsonEncode(j['refused']), contains(victim.path));
      expect(victim.readAsBytesSync(), [1, 99, 3], reason: 'not rewritten or deleted');
    });
  });

  group('output', () {
    test('Both forms carry the same facts, and Balance is stable', () async {
      final h = await payer();
      final text = await h.run(['balance']);
      final one = await h.run(['balance', '--json']);
      final two = await h.run(['balance', '--json']);
      expect(one.out, two.out, reason: 'the same state prints the same bytes');
      final facts = jsonDecode(one.out);
      final numbers = <num>{};
      void collect(Object? v) {
        if (v is num) numbers.add(v);
        if (v is Map) v.values.forEach(collect);
        if (v is List) v.forEach(collect);
      }

      collect(facts);
      for (final m in RegExp(r'\d+').allMatches(text.out)) {
        expect(numbers, contains(int.parse(m.group(0)!)), reason: '${m.group(0)} is in the readable form only');
      }
      expect(text.out, contains('500'));
      expect(h.ports.touchedNetwork, isTrue, reason: 'from the setup; balance itself is checked below');
    });

    test('Balance touches no network', () async {
      final h = await payer();
      final ports = CountingPorts();
      final quiet = Harness.make(ports: ports, poolKeys: fp.keys, now: early);
      made.add(quiet);
      final ran = await runCloak(['--wallet', h.wallet, 'balance', '--json'], quiet.world(StringBuffer(), StringBuffer()));
      expect(ran, Exit.done);
      expect(ports.touchedNetwork, isFalse, reason: 'neither the chain nor the pool was started');
    });

    test('A hundred truncations of each valid message', () async {
      final payee = await synced();
      final inv = await invoice(payee, 200);
      final h = await payer();
      expect((await pay(h, inv, fp.transport())).code, Exit.done);
      // an acknowledgement to truncate
      expect((await payee.run(['check', await proof1(payee)])).code, Exit.done);
      expect((await payee.run(['ack', await proof1(payee), '--out', file(payee, 'ack')])).code, Exit.done);
      final id = hex.encode(Invoice.decode(File(inv).readAsBytesSync()).id);
      final cases = {
        'invoice show': (File(inv).readAsBytesSync(), ['invoice', 'show']),
        'pay': (File(inv).readAsBytesSync(), ['pay']),
        'ack --check': (File(file(payee, 'ack')).readAsBytesSync(), ['ack', '--check', '--invoice', id]),
      };
      final rng = Random(23);
      for (final c in cases.entries) {
        final (whole, args) = c.value;
        final steps = <String>{};
        for (int i = 0; i < 100; i++) {
          final cut = file(h, 'cut');
          File(cut).writeAsBytesSync(whole.sublist(0, rng.nextInt(whole.length)));
          h.ports.transportPort = fp.transport();
          final ran = await h.run([...args, cut]);
          expect(ran.code, Exit.refused, reason: '${c.key}: $ran');
          final step = RegExp(r'refused at "([^"]+)"').firstMatch(ran.err)?.group(1);
          expect(step, allOf(isNotNull, isNot('unexpected')), reason: '${c.key}: $ran');
          steps.add(step!);
        }
        print('  100 truncated inputs to ${c.key}: refused at ${steps.join(', ')}');
      }
    });

    test('Bytes that are not a message at all', () async {
      final h = await payer();
      final rng = Random(11);
      final junk = file(h, 'junk');
      final commands = [
        ['invoice', 'show', junk],
        ['pay', junk],
        ['check', junk],
        ['ack', '--check', junk, '--invoice', '00' * 16],
      ];
      for (int i = 0; i < 25; i++) {
        File(junk).writeAsBytesSync(List.generate(rng.nextInt(3000), (_) => rng.nextInt(256)));
        for (final c in commands) {
          h.ports.transportPort = fp.transport();
          final ran = await h.run(c);
          expect(ran.code, lessThanOrEqualTo(Exit.usage), reason: '$c: $ran');
          expect(ran.code, isNot(Exit.done), reason: '$c: $ran');
          expect(ran.err, isNot(contains('refused at "unexpected"')), reason: '$c: $ran');
          expect(ran.err, isNot(contains('#0 ')), reason: 'no stack trace');
        }
      }
    });
  });
}

/// A transport that answers requests after [delay].
class _Slow implements Transport {
  final Transport inner;
  final Duration delay;
  _Slow(this.inner, this.delay);

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) async {
    await Future<void>.delayed(delay);
    return inner.request(frame, timeout: timeout);
  }

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) => inner.readFeed(from, max: max);
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
