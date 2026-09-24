import 'dart:convert';
import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart' show NoteAddress;
import 'package:test/test.dart';

import 'support/fake_pool.dart';
import 'support/harness.dart';

/// One payment between two wallets, every step a command line through the
/// same parser the binary uses, against the fake pool.
///
/// The seam is the one libcloak's own end-to-end run names: the transfer the
/// payer builds is not in the fixture's round 2, so after it is accepted the
/// payer's record is pointed at the note round 2 really pays; the round is
/// then read, the leaf found and the proof made from the round's own bytes.
void main() {
  test('A payment, end to end, through the commands', () async {
    final fp = await FakePool.build();
    final early = DateTime.utc(2023, 11, 1);
    final payer = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
    final payee = Harness.make(ports: CountingPorts(headerSource: fp.headers()), poolKeys: fp.keys, now: early);
    addTearDown(payer.dispose);
    addTearDown(payee.dispose);
    Future<Ran> run(Harness h, List<String> args) async {
      final ran = await h.run(args);
      expect(ran.code, Exit.done, reason: '${args.join(' ')}: $ran');
      return ran;
    }

    // two wallets, following the pool from its start
    for (final h in [payer, payee]) {
      await run(h, ['init', '--network', 'regtest', '--server', '/ip4/127.0.0.1/udp/1/udx/p2p/x', '--pool', 'c']);
      h.ports.transportPort = fp.transport(rounds: 1, head: 1);
      await run(h, ['sync', '--from-genesis']);
    }

    // the payer holds money: the fixture's round 1 note, handed over with its proof
    await run(payer, ['invoice', 'new', '--amount', '500', '--expires', '60d', '--out', '${payer.root.path}/own']);
    File('${payer.root.path}/p1').writeAsBytesSync(fp.standingProof(1).encode());
    await run(payer, ['check', '${payer.root.path}/p1']);

    // the payee asks for 200
    final invoice = '${payee.root.path}/invoice';
    await run(payee, ['invoice', 'new', '--amount', '200', '--expires', '60d', '--memo', 'a crate of oranges', '--out', invoice]);
    final id = hex.encode(Invoice.decode(File(invoice).readAsBytesSync()).id);
    File(invoice).copySync('${payer.root.path}/invoice');
    final shown = await run(payer, ['invoice', 'show', '${payer.root.path}/invoice']);
    expect(shown.out, contains('a crate of oranges'));

    // the payer pays, and the pool takes it into round 2
    payer.ports.transportPort = fp.transport(rounds: 1, head: 1, acceptInto: 2);
    final paid = await run(payer, ['pay', '${payer.root.path}/invoice', '--json']);
    expect(jsonDecode(paid.out)['outcome'], 'accepted');

    // the seam: point the record at the note round 2 pays
    final st = await CloakState.open(payer.dir);
    final p = st.payments.single;
    st.payments[0] = PaymentRecord(
        invoice: p.invoice,
        submissionId: p.submissionId,
        spentPosition: p.spentPosition,
        paid: NoteOpening.of(fp.note32.note),
        change: p.change,
        paidTo: (await NoteAddress.derive(fp.keys.ivk, fp.note32.note.d)).bytes,
        changeTo: p.changeTo,
        anchorRound: p.anchorRound,
        outcome: p.outcome,
        round: p.round);
    await st.save(payer.dir);

    // round 2 is mined; the notice arrives; the payer syncs and proves
    final t = fp.transport();
    t.notices.add(fp.notice(2, [p.submissionId]).encode());
    payer.ports.transportPort = t;
    await run(payer, ['sync']);
    await run(payer, ['proof', '--invoice', id, '--out', '${payer.root.path}/proof']);

    // the payee checks it against its own headers, and acknowledges
    File('${payer.root.path}/proof').copySync('${payee.root.path}/proof');
    payee.ports.transportPort = fp.transport();
    await run(payee, ['sync']);
    final checked = await run(payee, ['check', '${payee.root.path}/proof', '--json']);
    expect(jsonDecode(checked.out)['value'], fp.note32.note.value);
    await run(payee, ['ack', '${payee.root.path}/proof', '--out', '${payee.root.path}/ack']);

    // the payer checks the acknowledgement against the invoice it kept
    File('${payee.root.path}/ack').copySync('${payer.root.path}/ack');
    await run(payer, ['ack', '--check', '${payer.root.path}/ack', '--invoice', id]);

    // what each side holds, and what each side's record says
    final payeeBalance = jsonDecode((await run(payee, ['balance', '--json'])).out) as Map;
    expect(((payeeBalance['assets'] as List).single as Map)['spendable'], fp.note32.note.value);
    Future<List<String>> thread(Harness h) async => [
          for (final e in (jsonDecode((await run(h, ['journal', '--json', '--invoice', id])).out)['entries'] as List))
            (e as Map)['kind'] as String
        ];
    expect(await thread(payee), ['invoiceIssued', 'proofChecked', 'acknowledgementSent']);
    expect(await thread(payer), [
      'invoiceReceived',
      'paymentBuilt',
      'paymentSubmitted',
      'paymentAnswered',
      'proofBuilt',
      'acknowledgementReceived',
    ]);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
