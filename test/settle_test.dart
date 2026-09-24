import 'dart:convert';
import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'support/fake_pool.dart';
import 'support/harness.dart';

/// Mined rounds, read: a payment's proof made from the round the pool mined,
/// a deposit taken on from the round that carried it, late answers matched to
/// what they answer, and the catch-up refusals a pool gives.
///
/// **The seam, named.** The fake pool's two rounds were proved by tstokenlib's
/// fixture, and a transfer this wallet builds is not in either of them:
/// assembling a round is the coordinator's work. So where a test needs its
/// payment to be in round 2, it points the payment's record at the note round
/// 2 really pays the fixture's wallet, which is what libcloak's own
/// end-to-end run does. Everything after that, the round read, the leaf
/// found, the path made, the proof checked, runs on the real bytes.
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

  Future<Harness> wallet({int rounds = 1}) async {
    final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
    made.add(h);
    expect((await h.initWithPool()).code, Exit.done);
    final c = File(h.dir.config);
    c.writeAsStringSync(c.readAsStringSync().replaceFirst('timeout_seconds: 30', 'timeout_seconds: 1'));
    h.ports.transportPort = fp.transport(rounds: rounds, head: rounds == 0 ? 0 : rounds, catchUp: rounds > 0);
    final ran = await h.run(['sync', '--from-genesis']);
    expect(ran.code, Exit.done, reason: '$ran');
    return h;
  }

  Future<String> invoice(Harness h, int amount, String name) async {
    final path = '${h.root.path}/$name';
    final ran = await h.run(['invoice', 'new', '--amount', '$amount', '--expires', '60d', '--out', path]);
    expect(ran.code, Exit.done, reason: '$ran');
    return path;
  }

  /// A wallet holding the fixture's round 1 note, which has paid an invoice
  /// of another wallet's into round 2.
  Future<(Harness, String)> paid() async {
    final h = await wallet();
    await invoice(h, 500, 'own');
    File('${h.root.path}/p1').writeAsBytesSync(fp.standingProof(1).encode());
    expect((await h.run(['check', '${h.root.path}/p1'])).code, Exit.done);
    final payee = await wallet();
    final inv = await invoice(payee, 200, 'inv');
    h.ports.transportPort = fp.transport(rounds: 1, head: 1, acceptInto: 2);
    final ran = await h.run(['pay', inv]);
    expect(ran.code, Exit.done, reason: '$ran');
    return (h, inv);
  }

  Map<String, Object?> state(Harness h) => jsonDecode(File(h.dir.state).readAsStringSync()) as Map<String, Object?>;

  /// Points the wallet's one payment at the note round 2 really pays.
  Future<void> pointAtRound2(Harness h) async {
    final st = await CloakState.open(h.dir);
    final p = st.payments.single;
    final to = await NoteAddress.derive(fp.keys.ivk, fp.note32.note.d);
    st.payments[0] = PaymentRecord(
        invoice: p.invoice,
        submissionId: p.submissionId,
        spentPosition: p.spentPosition,
        paid: NoteOpening.of(fp.note32.note),
        change: p.change,
        paidTo: to.bytes,
        changeTo: p.changeTo,
        anchorRound: p.anchorRound,
        outcome: p.outcome,
        round: p.round);
    await st.save(h.dir);
  }

  group('a payment\'s proof', () {
    test('The leaf comes from the round, by notice', () async {
      final (h, inv) = await paid();
      await pointAtRound2(h);
      final id = hex.encode(Invoice.decode(File(inv).readAsBytesSync()).id);
      final sub = (await CloakState.open(h.dir)).payments.single.submissionId;
      final t = fp.transport();
      t.notices.add(fp.notice(2, [sub]).encode());
      h.ports.transportPort = t;
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(ran.out, contains('is at leaf ${fp.note32.position}'));
      expect(
          [for (final f in t.sent) PoolMessage.decode(f)]
              .whereType<PoolCatchUpRequest>()
              .where((q) => q.what == CatchUpKind.round)
              .map((q) => q.round),
          [2],
          reason: 'a notice carries no transactions, so the round it names is asked for by number');
      expect(t.notices, isEmpty, reason: 'the notice was taken out of the folder');
      expect((state(h)['checkpoints'] as Map), isEmpty, reason: 'the frontier kept at round 2 is dropped once read');

      // the spent note is spent: round 2 spent the round 1 note
      final store = NoteStore.decode(File(h.dir.noteStore).readAsBytesSync(), shape: fp.shape);
      expect(store.at(fp.note1.position)!.state, NoteState.spent);

      // cloak proof, and the payee's check of it
      final proof = await h.run(['proof', '--invoice', id, '--out', '${h.root.path}/proof', '--json']);
      expect(proof.code, Exit.done, reason: '$proof');
      expect((jsonDecode(proof.out) as Map)['leaf'], fp.note32.position);
      final payee = await wallet(rounds: 2);
      await invoice(payee, 200, 'inv');
      File('${h.root.path}/proof').copySync('${payee.root.path}/proof');
      final checked = await payee.run(['check', '${payee.root.path}/proof', '--json']);
      expect(checked.code, Exit.done, reason: 'the proof made from the round checks out for the payee: $checked');
      expect((jsonDecode(checked.out) as Map)['value'], fp.note32.note.value);

      // and the short form, for a payee that follows the pool
      final short = await h.run(['proof', '--invoice', id, '--short', '--out', '${h.root.path}/short']);
      expect(short.code, Exit.done, reason: '$short');
      expect(PaymentProof.decode(File('${h.root.path}/short').readAsBytesSync()).form, ProofForm.short);
    });

    test('The leaf comes from the round, asked for by number', () async {
      final (h, inv) = await paid();
      await pointAtRound2(h);
      final id = hex.encode(Invoice.decode(File(inv).readAsBytesSync()).id);
      final t = fp.transport();
      h.ports.transportPort = t;
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      final asked = [for (final f in t.sent) PoolMessage.decode(f)].whereType<PoolCatchUpRequest>()
          .where((q) => q.what == CatchUpKind.round)
          .toList();
      expect(asked.map((q) => q.round), [2]);
      final proof = await h.run(['proof', '--invoice', id, '--out', '${h.root.path}/proof']);
      expect(proof.code, Exit.done, reason: '$proof');
    });

    test('a notice naming other transactions than the answer is believed in neither', () async {
      final (h, _) = await paid();
      await pointAtRound2(h);
      final sub = (await CloakState.open(h.dir)).payments.single.submissionId;
      final t = fp.transport();
      t.notices.add(fp.notice(2, [sub], roundTxId: List.filled(32, 7)).encode());
      h.ports.transportPort = t;
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(ran.out, contains('refused at "notice"'));
      final p = (await CloakState.open(h.dir)).payments.single;
      expect(p.outcome, 'accepted', reason: 'still waiting on its round');
      expect(File('${h.dir.path}/proofs/${hex.encode(Invoice.decode(p.invoice).id)}.proof').existsSync(), isFalse);
    });

    test('The round does not hold it', () async {
      final (h, inv) = await paid();
      final id = hex.encode(Invoice.decode(File(inv).readAsBytesSync()).id);
      h.ports.transportPort = fp.transport();
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(ran.out, contains('round 2 does not hold its commitment'));
      final proof = await h.run(['proof', '--invoice', id, '--out', '${h.root.path}/proof']);
      expect(proof.code, Exit.refused);
      expect(proof.err, contains('round 2 does not hold'));
      expect(File('${h.root.path}/proof').existsSync(), isFalse, reason: 'no proof is emitted');
    });

    test('a proof before its round is read', () async {
      final (h, inv) = await paid();
      final id = hex.encode(Invoice.decode(File(inv).readAsBytesSync()).id);
      final ran = await h.run(['proof', '--invoice', id, '--out', '${h.root.path}/proof']);
      expect(ran.code, Exit.refused);
      expect(ran.err, contains('round 2'));
      expect(ran.err, contains('cloak sync'));
    });
  });

  group('a deposit\'s note', () {
    /// A wallet at round 0 with the fixture's round 1 deposit recorded as its
    /// own and accepted into round 1: the seam, as above.
    Future<Harness> depositor() async {
      final h = await wallet(rounds: 0);
      final st = await CloakState.open(h.dir);
      st.deposits.add(DepositRecord(
          covenantTxid: fp.c.depositTx.id,
          intoRound: 1,
          satoshis: 500,
          refundAfter: 1000,
          note: NoteOpening.of(fp.note1.note),
          commitment: BlockFold.lanesToBytes(fp.note1.cm),
          vout: ShieldedPoolTool.depositVout,
          transfer: const [1],
          status: 'accepted'));
      await st.save(h.dir);
      return h;
    }

    test('Pending until mined', () async {
      final h = await depositor();
      final status = await h.run(['status']);
      expect(status.out, contains('deposit ${fp.c.depositTx.id}: accepted, 500 satoshis, for round 1'));
      final balance = jsonDecode((await h.run(['balance', '--json'])).out) as Map;
      expect(balance['assets'], isEmpty, reason: 'not counted as spendable');
    });

    test('Taken on when the round arrives', () async {
      final h = await depositor();
      h.ports.transportPort = fp.transport(rounds: 1, head: 1);
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(ran.out, contains('is a note at leaf ${fp.note1.position}'));
      final balance = jsonDecode((await h.run(['balance', '--json'])).out) as Map;
      final bsv = (balance['assets'] as List).single as Map;
      expect(bsv['spendable'], 500, reason: 'spendable once the view is checked to that round');
      expect((state(h)['deposits'] as List).single['status'], 'taken');
    });
  });

  group('the mailbox', () {
    test('a late answer settles a payment that went unanswered', () async {
      final h = await wallet();
      await invoice(h, 500, 'own');
      File('${h.root.path}/p1').writeAsBytesSync(fp.standingProof(1).encode());
      await h.run(['check', '${h.root.path}/p1']);
      final payee = await wallet();
      final inv = await invoice(payee, 200, 'inv');
      h.ports.transportPort = fp.transport()..hold = true;
      expect((await h.run(['pay', inv])).code, Exit.refused, reason: 'unanswered');
      final sub = (await CloakState.open(h.dir)).payments.single.submissionId;

      // the answer arrives after the command stopped waiting
      final t = fp.transport(rounds: 1, head: 1);
      t.lateReplies.add(PoolReply.accepted(sub, 2).encode());
      h.ports.transportPort = t;
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      final p = (await CloakState.open(h.dir)).payments.single;
      expect(p.outcome, 'accepted');
      expect(p.round, 2);
    });

    test('an accepted transfer the pool later drops is released by its notice', () async {
      final (h, _) = await paid();
      final before = (await CloakState.open(h.dir)).payments.single;
      expect(before.outcome, 'accepted');
      final t = fp.transport(rounds: 1, head: 1);
      t.notices.add(PoolReply.expired(before.submissionId, 'dropped at close').encode());
      h.ports.transportPort = t;
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.done, reason: '$ran');
      final p = (await CloakState.open(h.dir)).payments.single;
      expect(p.outcome, 'expired');
      final store = NoteStore.decode(File(h.dir.noteStore).readAsBytesSync(), shape: fp.shape);
      expect(store.at(before.spentPosition)!.state, isNot(NoteState.reserved), reason: 'no round will spend it');
      expect([for (final f in t.sent) PoolMessage.decode(f)].whereType<PoolCatchUpRequest>().where((q) => q.what == CatchUpKind.round),
          isEmpty,
          reason: 'nothing waits on round 2 any more');
    });

    test('an answer in the notices folder is not taken for one', () async {
      final (h, _) = await paid();
      final before = (await CloakState.open(h.dir)).payments.single;
      final t = fp.transport(rounds: 1, head: 1);
      t.notices.add(PoolReply.refused(before.submissionId, RefusalReason.malformed, 'a notice is never an answer').encode());
      h.ports.transportPort = t;
      expect((await h.run(['sync'])).code, Exit.done);
      expect((await CloakState.open(h.dir)).payments.single.outcome, 'accepted');
    });

    test('a notice never reaches a request', () async {
      final (h, _) = await paid();
      final t = fp.transport();
      // a notice waiting, and a submission's answer: the answer is the answer
      t.notices.add(fp.notice(2, [List.filled(16, 3)]).encode());
      h.ports.transportPort = t;
      final payee = await wallet();
      final inv = await invoice(payee, 100, 'second');
      File('${h.root.path}/own2').writeAsStringSync('');
      final ran = await h.run(['pay', inv]);
      // the only note is reserved, so this is refused before anything is sent;
      // what matters is that the notice was not consumed as an answer
      expect(ran.err, isNot(contains('roundMined')));
      expect(t.notices, hasLength(1), reason: 'pay reads replies, never notices');
    });
  });

  group('the pool\'s catch-up refusals', () {
    test('notYet before anything is mined', () async {
      final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
      made.add(h);
      await h.initWithPool();
      h.ports.transportPort = fp.transport(rounds: 0);
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "notYet"'));
      expect(ran.err, contains('asking again after the next round'));
    });

    test('notServed is a pool that does not serve catch-up', () async {
      final h = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
      made.add(h);
      await h.initWithPool();
      h.ports.transportPort = fp.transport(
          answer: (q) => PoolCatchUpReply.refused(q.what, CatchUpRefusal.notServed, 'this pool serves no catch-up', id: q.id));
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('does not serve catch-up'));
      expect(ran.err, contains('round 0'));
    });
  });
}
