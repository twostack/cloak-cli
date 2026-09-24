import 'dart:io';

import 'package:args/args.dart';
import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../shell/bounded_file.dart';
import '../shell/call.dart';
import '../wallet/session.dart';
import '../wallet/state_file.dart';
import 'settling.dart';
import 'submitting.dart';

void invoiceNewOptions(ArgParser p) => p
  ..addOption('amount', valueHelp: 'satoshis', help: 'what the invoice asks for')
  ..addOption('expires', valueHelp: 'duration', defaultsTo: '24h', help: 'how long it stays payable: 30m, 24h, 7d, or a UTC time')
  ..addOption('memo', valueHelp: 'text', defaultsTo: '', help: 'what the money is for, at most 512 bytes')
  ..addOption('out', valueHelp: 'file', help: 'where the invoice is written');

void proofOptions(ArgParser p) => p
  ..addOption('invoice', valueHelp: 'id', help: 'the invoice this wallet paid, by its id in hex')
  ..addFlag('short', negatable: false, help: 'the short form, for a payee that follows the pool')
  ..addOption('out', valueHelp: 'file', help: 'where the proof is written');

void ackOptions(ArgParser p) => p
  ..addFlag('check', negatable: false, help: 'check an acknowledgement you were sent, against the invoice it names')
  ..addOption('invoice', valueHelp: 'id', help: 'with --check: the invoice, by its id in hex')
  ..addOption('out', valueHelp: 'file', help: 'where the acknowledgement is written');

/// When an invoice expires: a duration from now (`90s`, `30m`, `24h`, `7d`)
/// or an absolute UTC time.
DateTime _expiry(String text, DateTime now) {
  final m = RegExp(r'^(\d+)([smhd])$').firstMatch(text);
  if (m != null) {
    final n = int.parse(m.group(1)!);
    final unit = switch (m.group(2)) {
      's' => Duration(seconds: n),
      'm' => Duration(minutes: n),
      'h' => Duration(hours: n),
      _ => Duration(days: n),
    };
    return now.add(unit);
  }
  final t = DateTime.tryParse(text);
  if (t == null) throw UsageError('--expires is a duration like 30m, 24h or 7d, or a time, not "$text"');
  return t.toUtc();
}

String _required(Call call, String option, String what) =>
    call.option(option) ?? (throw UsageError('cloak ${call.name} needs --$option, $what'));

List<int> _invoiceId(String text) {
  final List<int> id;
  try {
    id = hex.decode(text);
  } on FormatException {
    throw UsageError('an invoice id is hexadecimal, and "$text" is not');
  }
  if (id.length != Invoice.idLength) throw UsageError('an invoice id is ${Invoice.idLength} bytes, "$text" is ${id.length}');
  return id;
}

Future<void> _writeOut(String path, List<int> bytes) async {
  final f = File(path);
  if (await f.exists()) throw Refusal('file', 'there is already a file at $path, and it is not overwritten');
  await f.writeAsBytes(bytes, flush: true);
}

/// `cloak invoice new`: an invoice for an amount, to a fresh address.
///
/// One invoice, one address, so two payers cannot be told apart by anybody
/// but the payee. The invoice is signed under a key only this wallet can
/// derive for that address, and written to the file named; handing it over is
/// the person's business, over a channel they already trust.
Future<void> runInvoiceNew(Call call) async {
  final amount = call.intOption('amount', min: 1) ?? (throw UsageError('cloak invoice new needs --amount'));
  final out = _required(call, 'out', 'the file the invoice is written to');
  final s = await call.open(write: true, keys: true);
  final pool = s.poolOrRefuse;
  final now = call.world.now();
  final expiry = _expiry(call.option('expires')!, now);
  if (!expiry.isAfter(now)) throw Refusal('expiry', 'an invoice that expires at ${expiry.toIso8601String()} is already expired');
  final index = s.keys.addressesIssued;
  final address = await s.nextAddress();
  // the fields are checked before the counter is saved, so a refused invoice
  // burns no address: nothing below reaches the disk until it is whole
  final invoice = await Invoice.issue(
      tokenId: pool.tokenId,
      ivk: s.poolKeys.ivk,
      address: address,
      amount: amount,
      expiry: expiry,
      memo: call.option('memo')!,
      rng: call.world.rng);
  final bytes = invoice.encode();
  await _writeOut(out, bytes);
  s.state.issued.add(bytes);
  await s.record(JournalEntry.invoiceIssued(invoice, at: now));
  await s.save(view: false, store: false);
  call.report
    ..add('invoice', hex.encode(invoice.id), 'invoice ${hex.encode(invoice.id)}')
    ..add('amount', amount, 'asks for $amount satoshis')
    ..add('expires', expiry.toIso8601String(), 'payable until ${expiry.toIso8601String()}')
    ..add('address', index, 'to address $index of this wallet')
    ..add('file', out, 'written to $out')
    ..quiet('bytes', bytes.length);
}

/// `cloak invoice show`: an invoice somebody handed you, read and checked.
///
/// The checks are the payer's, in libcloak's order: the pool it names, its
/// expiry, its signature. Nothing is spent and nothing is written.
Future<void> runInvoiceShow(Call call) async {
  final path = call.positional(0, 'the invoice file');
  final bytes = await BoundedFile.read(path, MessageKind.invoice);
  final s = await call.open();
  final (invoice, why) = await Invoice.read(bytes, tokenId: s.poolOrRefuse.tokenId, now: call.world.now());
  if (invoice == null) throw why!;
  _describe(call, invoice);
}

void _describe(Call call, Invoice invoice) {
  call.report
    ..add('invoice', hex.encode(invoice.id), 'invoice ${hex.encode(invoice.id)}')
    ..add('amount', invoice.amount, 'asks for ${invoice.amount} satoshis')
    ..add('expires', invoice.expiry.toIso8601String(), 'payable until ${invoice.expiry.toIso8601String()}')
    ..add('memo', invoice.memo, invoice.memo.isEmpty ? 'no memo' : 'for: ${invoice.memo}')
    ..add('checked', true, 'the pool, the expiry and the signature check out');
}

/// `cloak pay`: an invoice paid out of one note this wallet holds.
///
/// Every check that costs nothing runs before the one that costs a STARK:
/// the invoice's pool, expiry and signature, then the note, then the path and
/// the anchor, all in libcloak's order. Then the note is reserved **and that
/// reservation saved** before the frame leaves, so neither a second process
/// nor a crash can pick the same note. The answer alone moves it afterwards:
/// accepted leaves it reserved, refused, expired or unsent release it, and no
/// answer leaves it reserved, because the transfer may be in a round.
Future<void> runPay(Call call) async {
  final whole = Stopwatch()..start();
  final path = call.positional(0, 'the invoice file');
  final bytes = await BoundedFile.read(path, MessageKind.invoice);
  final s = await call.open(write: true, keys: true);
  final pool = s.poolOrRefuse;
  final now = call.world.now();
  final (invoice, whyInvoice) = await Invoice.read(bytes, tokenId: pool.tokenId, now: now);
  if (invoice == null) throw whyInvoice!;

  final view = s.viewOrRefuse;
  // the tip is the last round this wallet folded; a pool that is further on
  // refuses a stale anchor by name, and cloak sync is the fix
  final tip = view.round;
  final (choice, whyChoice) = s.store.choose(amount: invoice.amount, asset: PoolHash.bsvAsset, view: view, tip: tip);
  if (choice == null) {
    // a note that would cover it and cannot be anchored says why in the
    // view's own words: behind, unchecked, or not followed
    for (final n in s.store.notes) {
      if (n.isProven && n.value >= invoice.amount) {
        final (ok, why) = Balance.anchorable(n, view: view, tip: tip);
        if (!ok && why != null) throw Refusal(why.step, '${why.reason}. No spend proof was computed');
      }
    }
    for (final n in s.store.notes) {
      if (n.state == NoteState.reserved && n.value >= invoice.amount) {
        throw Refusal('note',
            'the note at leaf ${n.position} would cover ${invoice.amount} and is reserved by a payment in flight; '
            '${whyChoice!.reason}. No spend proof was computed');
      }
    }
    throw whyChoice!;
  }
  final change = await s.nextAddress();

  final (payment, whyBuild) = await PaymentBuilder.build(
      invoice: invoice,
      keys: s.poolKeys,
      changeAddress: change,
      note: choice.note,
      notes: s.store,
      view: view,
      spendP: pool.spendP,
      tokenId: pool.tokenId,
      tip: tip,
      now: now,
      rng: call.world.rng);
  if (payment == null) throw whyBuild!;
  await s.record(JournalEntry.invoiceReceived(invoice, at: now));
  await s.record(JournalEntry.paymentBuilt(payment, at: now));

  final submission = PoolSubmission.of(payment.transfer, pool.spendP, rng: call.world.rng);
  final record = PaymentRecord(
      invoice: bytes,
      submissionId: submission.id,
      spentPosition: payment.spent.position,
      paid: payment.paid,
      change: payment.change,
      paidTo: payment.paidTo.bytes,
      changeTo: payment.changeTo.bytes,
      anchorRound: payment.anchorRound,
      outcome: 'sending');
  final sent = await submitReserved(s,
      note: payment.spent,
      submission: submission,
      beforeSend: () async => s.state.payments.add(record),
      record: (outcome) async {
        if (outcome == null) {
          record.outcome = 'unsent';
          return;
        }
        await s.record(JournalEntry.paymentSubmitted(invoice, submission.id, at: now));
        record
          ..outcome = outcome.outcome.name
          ..round = outcome.round;
        await s.record(JournalEntry.paymentAnswered(invoice, outcome, at: call.world.now()));
      });
  final outcome = sent.outcome;
  final network = sent.network;
  whole.stop();

  final host = whole.elapsed - payment.proving - network - s.kdf;
  call.report
    ..add('invoice', hex.encode(invoice.id), 'invoice ${hex.encode(invoice.id)}')
    ..add('amount', invoice.amount, 'paying ${invoice.amount} out of the note at leaf ${payment.spent.position}')
    ..quiet('leaf', payment.spent.position)
    ..add('change', payment.change.value, 'change ${payment.change.value} to a fresh address')
    ..add('submission', hex.encode(submission.id), 'submission ${hex.encode(submission.id)}')
    ..add('outcome', outcome.outcome.name, 'the pool: $outcome')
    ..quiet('round', outcome.round)
    ..add(
        'clockMs',
        {
          'whole': whole.elapsedMilliseconds,
          'proving': payment.proving.inMilliseconds,
          'network': network.inMilliseconds,
          'passphrase': s.kdf.inMilliseconds,
          'host': host.inMilliseconds,
          'libcloakOwnWork': payment.ownWork.inMilliseconds,
        },
        'clock: ${whole.elapsedMilliseconds} ms, of which the spend proof ${payment.proving.inMilliseconds} ms, '
            'the pool ${network.inMilliseconds} ms, the passphrase ${s.kdf.inMilliseconds} ms, and this program '
            '${host.inMilliseconds} ms');

  switch (outcome.outcome) {
    case Submitted.accepted:
      call.report.say('the note is reserved until round ${outcome.round} is mined; then cloak proof --invoice '
          '${hex.encode(invoice.id)} makes the proof to hand the payee');
    case Submitted.unanswered:
      throw Refusal('no answer',
          'the pool did not answer submission ${hex.encode(submission.id)}: ${outcome.refusal!.reason}. The transfer '
          'may still be in a round, so the note stays reserved; run cloak sync, then cloak status');
    case Submitted.refused || Submitted.expired || Submitted.unsent:
      final why = outcome.refusal!;
      throw Refusal(why.step, '${why.reason}; the note is released and the invoice is unpaid');
  }
}

/// `cloak proof`: the payment proof for an invoice this wallet paid.
///
/// The leaf comes from the round: when `cloak sync` read the mined round this
/// payment was accepted into, it found the payee's commitment among the
/// round's own leaves, made its path from those leaves and the pool's
/// frontier at that round, and kept the standing proof. This hands it over,
/// or the short form of it for a payee that follows the pool. A round that
/// did not hold the commitment makes no proof, and says so.
Future<void> runProof(Call call) async {
  final id = _invoiceId(_required(call, 'invoice', 'the invoice this wallet paid'));
  final out = _required(call, 'out', 'the file the proof is written to');
  final s = await call.open(write: true);
  final record = _paymentFor(s, id);
  final invoice = Invoice.decode(record.invoice);
  if (record.outcome == 'not in round') {
    final (payee, _) = AddressCodec.read(record.paidTo);
    final cm = BlockFold.lanesToBytes(record.paid.plaintext.cmUnder(payee!.pkd));
    throw Refusal('round',
        'round ${record.round} does not hold this payment\'s commitment ${shortHex(cm)}, so there is no proof to '
        'make; the note stays reserved until the pool says what became of the submission');
  }
  final file = File(proofPath(s.dir, id));
  if (record.paidPosition == null || !file.existsSync()) {
    throw Refusal('round',
        record.round == null
            ? 'the payment for invoice ${hex.encode(id)} was not accepted into a round (${record.outcome})'
            : 'round ${record.round}, which took the payment for invoice ${hex.encode(id)}, has not been read yet; '
                'run cloak sync once it is mined');
  }
  final standing = PaymentProof.decode(await file.readAsBytes());
  final PaymentProof proof;
  if (call.flag('short')) {
    final (short, why) = PaymentProofs.short(
        note: standing.note, round: standing.round, position: standing.position, path: standing.path);
    if (short == null) throw why!;
    proof = short;
  } else {
    proof = standing;
  }
  final bytes = proof.encode();
  await _writeOut(out, bytes);
  await s.record(JournalEntry.proofBuilt(invoice, proof, at: call.world.now()));
  call.report
    ..add('invoice', hex.encode(id), 'the ${proof.form.name} proof for invoice ${hex.encode(id)}')
    ..add('round', proof.round, 'the payment is in round ${proof.round}, at leaf ${proof.position}')
    ..quiet('leaf', proof.position)
    ..add('bytes', bytes.length, '${bytes.length} bytes, written to $out')
    ..quiet('file', out);
}

PaymentRecord _paymentFor(Session s, List<int> id) {
  for (final p in s.state.payments.reversed) {
    if (hex.encode(p.invoiceId) == hex.encode(id)) return p;
  }
  throw Refusal('invoice', 'this wallet has paid no invoice ${hex.encode(id)}');
}

/// The invoice this wallet issued to the address with diversifier [d].
Invoice? _issuedFor(Session s, List<int> d) {
  for (final bytes in s.state.issued) {
    final i = Invoice.decode(bytes);
    if (_eq(i.address.d, d)) return i;
  }
  return null;
}

/// Decodes and checks a payment proof the way a payee does, against this
/// wallet's own headers and its own address key, and names the invoice it
/// pays.
Future<(PaymentProof, Invoice, CheckedPayment?, Refusal?)> _checkProof(Call call, Session s, String path) async {
  final bytes = await BoundedFile.read(path, MessageKind.paymentProof);
  final PaymentProof proof;
  try {
    proof = PaymentProof.decode(bytes);
  } on Refusal catch (e) {
    throw Refusal(e.step, '${e.reason} (reading $path)');
  }
  final pool = s.poolOrRefuse;
  final invoice = _issuedFor(s, proof.note.d);
  if (invoice == null) {
    throw Refusal('invoice',
        'this proof pays an address this wallet issued no invoice for; a payment is checked against the invoice it '
        'pays');
  }
  final view = s.view;
  final checker = PaymentChecker(
      pool: pool,
      headers: await s.headerChecker(),
      foldedRoot: (round) =>
          view != null && view.round == round && view.checkedTo == round ? view.cmRoot : null,
      foldedTo: () => view?.round ?? 0);
  final (paid, why) = await checker.check(proof, pkd: s.pkdFor(proof.note.d));
  if (paid == null && (why!.step == 'block' || why.step == 'confirmations')) {
    final tip = await (await s.headers()).tip();
    return (
      proof,
      invoice,
      null,
      Refusal(why.step,
          '${why.reason}; this wallet\'s chain ends at height ${tip.height}, so a block newer than that is not '
          'here yet: run cloak sync and check again')
    );
  }
  return (proof, invoice, paid, why);
}

/// `cloak check`: a payment proof, checked against this wallet's own headers,
/// and the note taken on only if it checks out.
///
/// There is no other way a note gets into the store from a proof: libcloak's
/// store takes only a `CheckedPayment`, and only the checker makes one. The
/// confirmations reported are this wallet's own count, from its own tip,
/// whatever the payer said.
Future<void> runCheck(Call call) async {
  final path = call.positional(0, 'the payment proof file');
  final s = await call.open(write: true, keys: true);
  final (proof, invoice, paid, why) = await _checkProof(call, s, path);
  final now = call.world.now();
  if (paid == null) {
    await s.record(JournalEntry.proofChecked(invoice, refusal: why, at: now));
    throw why!;
  }
  final (note, whyTake) = s.store.take(paid);
  if (note == null) throw whyTake!;
  await s.record(JournalEntry.proofChecked(invoice, payment: paid, at: now));
  final tracked = _track(s, proof, paid, note.commitmentFor(s.pkdFor(proof.note.d)));
  await s.save();
  call.report
    ..add('invoice', hex.encode(invoice.id), 'pays invoice ${hex.encode(invoice.id)}')
    ..add('value', paid.value, 'paid ${paid.value} satoshis')
    ..add('round', paid.round, 'in round ${paid.round}, at leaf ${paid.position}')
    ..quiet('leaf', paid.position)
    ..add('confirmations', paid.confirmations,
        proof.form == ProofForm.standing ? '${paid.confirmations} confirmations deep, by this wallet\'s own chain' : 'a short proof, against this wallet\'s own fold')
    ..add('spendable', tracked == null, tracked == null ? 'the note is held and its path is kept' : 'the note is held; $tracked');
}

/// Keeps the new note's path in the view, so it can be spent. Null when it
/// is kept, else what stops it, which is advice and not a refusal: the money
/// is this wallet's either way.
String? _track(Session s, PaymentProof proof, CheckedPayment paid, List<int> leaf) {
  var view = s.view;
  if (view == null) {
    view = PoolView.atGenesis(s.shape);
    s.view = view;
  }
  if (view.round < paid.round) {
    if (proof.form != ProofForm.standing || view.notes.isNotEmpty) {
      return 'the pool view stands at round ${view.round}; run cloak sync to fold up to round ${paid.round}';
    }
    // a view keeping no note may resume from a verified path: the path is a
    // frontier, and its root is the one the proven round carries
    final (_, why) =
        view.resume(round: paid.round, position: paid.position, leaf: leaf, path: proof.path, cmRoot: paid.cmRoot);
    return why == null ? null : '${why.step}: ${why.reason}';
  }
  if (view.round == paid.round && view.checkedTo < view.round && proof.form == ProofForm.standing) {
    // a proof somebody handed over is a round proved off the chain: the fold
    // becomes evidence against it
    final why = view.check(paid.round, paid.cmRoot);
    if (why != null) return '${why.step}: ${why.reason}';
  }
  final (_, why) = view.track(round: paid.round, position: paid.position, leaf: leaf, path: proof.path);
  return why == null ? null : '${why.step}: ${why.reason}';
}

/// `cloak ack`: the payee's acknowledgement of a payment it checked, or,
/// with `--check`, the payer's check of one it was sent.
///
/// The payee signs only a payment it holds, re-checked against its own
/// headers, and only if the round was mined before the invoice expired, by
/// the block's own clock: the one clock in the exchange the payer did not
/// supply. Refusing to sign is not refusing the money; the note stays held.
Future<void> runAck(Call call) async {
  if (call.flag('check')) return _checkAck(call);
  final path = call.positional(0, 'the payment proof file');
  final out = _required(call, 'out', 'the file the acknowledgement is written to');
  final s = await call.open(write: true, keys: true);
  final (proof, invoice, paid, why) = await _checkProof(call, s, path);
  if (paid == null) throw why!;
  final held = s.store.at(paid.position);
  if (held == null) {
    throw Refusal('check', 'this wallet does not hold the note at leaf ${paid.position}; run cloak check on the proof first');
  }
  if (proof.form != ProofForm.standing) {
    throw const Refusal('short proof',
        'an acknowledgement is signed against the time of the block the payment was mined in, and a short proof '
        'names no block; ask the payer for the standing form');
  }
  final (header, whyHeader) = await (await s.headerChecker()).proven(proof.blockHash!);
  if (header == null) throw whyHeader!;
  final (ack, whyAck) =
      await Acknowledgement.of(invoice: invoice, payment: paid, ivk: s.poolKeys.ivk, minedAt: header.time);
  if (ack == null) throw whyAck!;
  final bytes = ack.encode();
  await _writeOut(out, bytes);
  await s.record(JournalEntry.acknowledgementSent(invoice, ack, at: call.world.now()));
  call.report
    ..add('invoice', hex.encode(invoice.id), 'acknowledges invoice ${hex.encode(invoice.id)}')
    ..add('value', ack.value, 'for ${ack.value} satoshis in round ${ack.round}')
    ..quiet('round', ack.round)
    ..add('file', out, 'written to $out');
}

Future<void> _checkAck(Call call) async {
  final path = call.positional(0, 'the acknowledgement file');
  final id = _invoiceId(_required(call, 'invoice', 'the invoice the acknowledgement is checked against'));
  final bytes = await BoundedFile.read(path, MessageKind.acknowledgement);
  final s = await call.open(write: true);
  final invoice = Invoice.decode(_paymentFor(s, id).invoice);
  final Acknowledgement ack;
  try {
    ack = Acknowledgement.decode(bytes);
  } on Refusal catch (e) {
    throw Refusal(e.step, '${e.reason} (reading $path)');
  }
  final why = await ack.check(invoice);
  await s.record(JournalEntry.acknowledgementReceived(invoice, ack, refusal: why, at: call.world.now()));
  if (why != null) throw why;
  call.report
    ..add('invoice', hex.encode(invoice.id), 'the payee acknowledged invoice ${hex.encode(invoice.id)}')
    ..add('value', ack.value, 'for ${ack.value} satoshis in round ${ack.round}')
    ..quiet('round', ack.round);
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
