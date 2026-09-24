import 'dart:io';

import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:path/path.dart' as p;
import 'package:tstokenlib/tstokenlib.dart';

import '../net/rounds.dart';
import '../shell/call.dart';
import '../wallet/session.dart';
import '../wallet/state_file.dart';
import '../wallet/wallet_dir.dart';

/// The rounds something of this wallet's is waiting on: a payment, a
/// withdrawal or a deposit the pool accepted into a round whose leaves this
/// wallet has not read yet.
Set<int> awaitedRounds(CloakState st) => {
      for (final x in st.payments)
        if (x.outcome == 'accepted' && x.round != null) x.round!,
      for (final x in st.withdrawals)
        if (x.outcome == 'accepted' && x.round != null) x.round!,
      for (final x in st.deposits)
        if (x.status == 'accepted') x.intoRound,
    };

/// Whether a sync has anything to settle, which is what makes it ask for the
/// passphrase: marking a spent note spent needs the nullifier key.
bool needsKeys(CloakState st) =>
    awaitedRounds(st).isNotEmpty ||
    st.payments.any((x) => x.outcome == 'unanswered') ||
    st.withdrawals.any((x) => x.outcome == 'unanswered');

/// Takes the replies an earlier run gave up waiting for out of the mailbox,
/// and moves what they answer.
///
/// A reply that arrives after its command stopped waiting stays in the
/// replies folder, and the next command's request would take it as its own
/// answer. So every command that sends drains the folder first, and a late
/// answer is matched to its submission by id: an accepted one leaves the note
/// reserved and records the round, a refused one releases it.
Future<void> settleStaleReplies(Session s) async {
  final mailbox = await s.mailbox();
  if (mailbox == null) return;
  for (final frame in await mailbox.drainReplies()) {
    final reply = _decodeReply(frame);
    if (reply != null) _settle(s, reply);
  }
}

/// Takes the notices waiting in the mailbox out of it: the mined-round
/// notices, by round, for [settleRounds], and the pool's word that it dropped
/// a transfer it had accepted, which releases that transfer's note here.
///
/// The coordinator sends both unasked, to the notices folder, so neither is
/// ever mistaken for the answer to a request. A dropped transfer is told as
/// an `expired` reply after its `accepted` one; nothing else a notice folder
/// holds is an answer, so any other reply found there is ignored.
Future<Map<int, PoolRoundMined>> drainNotices(Session s) async {
  final mailbox = await s.mailbox();
  if (mailbox == null) return {};
  final out = <int, PoolRoundMined>{};
  for (final frame in await mailbox.readNotices()) {
    final PoolMessage m;
    try {
      m = PoolMessage.decode(frame);
    } catch (_) {
      // a notice that does not decode is a notice nobody can use
      continue;
    }
    if (m is PoolRoundMined) out[m.round] = m;
    if (m is PoolReply && m.outcome == ReplyOutcome.expired) _settle(s, m);
  }
  return out;
}

PoolReply? _decodeReply(List<int> frame) {
  try {
    final m = PoolMessage.decode(frame);
    return m is PoolReply ? m : null;
  } catch (_) {
    return null;
  }
}

/// Moves whatever of this wallet's [reply] answers, matched by submission id:
/// an accepted one records the round and leaves the note reserved; a refused
/// or expired one releases the note, since no round will spend it.
void _settle(Session s, PoolReply reply) {
  final id = hex.encode(reply.id);
  void move(int spent, void Function(String outcome, int? round) set) {
    final note = s.store.at(spent);
    switch (reply.outcome) {
      case ReplyOutcome.accepted:
        set('accepted', reply.round);
      case ReplyOutcome.refused || ReplyOutcome.expired:
        if (note != null && note.state == NoteState.reserved) s.store.release(note);
        set(reply.outcome.name, null);
    }
  }

  for (final x in s.state.payments) {
    if (hex.encode(x.submissionId) == id) {
      move(x.spentPosition, (o, r) => x
        ..outcome = o
        ..round = r ?? x.round);
    }
  }
  for (final x in s.state.withdrawals) {
    if (hex.encode(x.submissionId) == id) {
      move(x.spentPosition, (o, r) => x
        ..outcome = o
        ..round = r ?? x.round);
    }
  }
  for (final d in s.state.deposits) {
    if (d.submissionId != null && hex.encode(d.submissionId!) == id) {
      if (reply.outcome == ReplyOutcome.accepted) {
        d.status = 'accepted';
      } else {
        d
          ..status = 'refused'
          ..reason = '${reply.outcome.name}: ${reply.sentence ?? ''}';
      }
    }
  }
}

/// Where a paid invoice's standing proof is kept once its round is read.
String proofPath(WalletDir dir, List<int> invoiceId) => p.join(dir.path, 'proofs', '${hex.encode(invoiceId)}.proof');

/// Reads every mined round this wallet waits on and takes on what is its own.
///
/// For each round: the round is asked for by number (a notice in [notices]
/// only names what the answer must be), proved off this wallet's own headers
/// and its leaves read; the nullifiers it spent mark this wallet's spent notes spent;
/// a payment's payee leaf becomes a standing proof kept for `cloak proof`,
/// and the payer's change is taken on; a withdrawal's change is taken on; a
/// deposit's note is taken on. A path is made from the round's own leaves and
/// the frontier this wallet kept at that round, and the view checks it
/// reaches a root it folded.
Future<void> settleRounds(Call call, Session s, Map<int, PoolRoundMined> notices) async {
  final r = call.report;
  final view = s.view;
  if (view == null) return;
  final pool = s.poolOrRefuse;
  final shape = s.shape;
  final checker = PaymentChecker(pool: pool, headers: await s.headerChecker());
  final done = <Map<String, Object?>>[];
  for (final round in awaitedRounds(s.state).toList()..sort()) {
    if (round > view.round) continue;
    final kept = s.state.checkpoints[round];
    if (kept == null) {
      r.say('round $round: this wallet\'s fold passed it without keeping its frontier, so its leaves cannot be '
          'placed; the pool would have to serve the frontier as of that round');
      continue;
    }
    final (bytes, why) = await Rounds.fetch(await s.transport(), round, timeout: s.config.timeout);
    if (bytes == null) {
      r.say('round $round: not read yet (${why!.step}: ${why.reason})');
      continue;
    }
    final notice = notices[round];
    if (notice != null && !bytes.isNamedBy(notice)) {
      r.say('round $round: refused at "notice": the pool\'s notice named other transactions than its answer for '
          'that round, so neither is believed');
      continue;
    }
    final (read, whyRead) = await Rounds.check(pool, checker, bytes);
    if (read == null) {
      r.say('round $round: refused at "${whyRead!.step}": ${whyRead.reason}');
      continue;
    }
    final checkpoint = Checkpoint.decode(kept, shape: shape);

    // this wallet's notes the round spent
    for (final spent in s.store.settle(read.leaves.nullifiers, nk: s.poolKeys.nk)) {
      final tracked = view.trackedAt(spent.position);
      if (tracked != null) view.forget(tracked);
    }

    String? takeOn(NoteOpening opening, List<int> address, String what) {
      final (addr, whyAddr) = AddressCodec.read(address);
      if (addr == null) return '${whyAddr!.step}: ${whyAddr.reason}';
      final cm = BlockFold.lanesToBytes(opening.plaintext.cmUnder(addr.pkd));
      final offset = read.offsetOf(cm);
      if (offset == null) return 'round $round does not hold $what ${shortHex(cm)}';
      final position = shape.firstLeafOf(round) + offset;
      final (path, whyPath) = Rounds.pathAt(shape, read, checkpoint, offset);
      if (path == null) return '${whyPath!.step}: ${whyPath.reason}';
      final (_, whyTrack) = view.track(round: round, position: position, leaf: cm, path: path);
      if (whyTrack != null) return '${whyTrack.step}: ${whyTrack.reason}';
      final (_, whyTake) = s.store.takeChange(opening: opening, position: position, round: round);
      if (whyTake != null) return '${whyTake.step}: ${whyTake.reason}';
      return null;
    }

    for (final x in s.state.payments.where((x) => x.outcome == 'accepted' && x.round == round)) {
      final invoice = Invoice.decode(x.invoice);
      final (payee, _) = AddressCodec.read(x.paidTo);
      final cm = BlockFold.lanesToBytes(x.paid.plaintext.cmUnder(payee!.pkd));
      final offset = read.offsetOf(cm);
      if (offset == null) {
        x.outcome = 'not in round';
        r.say('payment for invoice ${hex.encode(invoice.id)}: round $round does not hold its commitment '
            '${shortHex(cm)}; the note stays reserved until the pool says what became of it');
        continue;
      }
      final position = shape.firstLeafOf(round) + offset;
      final (path, whyPath) = Rounds.pathAt(shape, read, checkpoint, offset);
      final (proof, whyProof) = path == null
          ? (null, whyPath)
          : PaymentProofs.standing(
              note: x.paid,
              round: round,
              roundTx: bytes.roundTx,
              witnessTx: bytes.witnessTx,
              blockHash: bytes.blockHash,
              txIndex: bytes.txIndex,
              branch: bytes.branch,
              position: position,
              path: path);
      if (proof == null) {
        r.say('payment for invoice ${hex.encode(invoice.id)}: no proof made: ${whyProof!.step}: ${whyProof.reason}');
        continue;
      }
      final file = File(proofPath(s.dir, invoice.id));
      await file.parent.create(recursive: true);
      await WalletDir.ownerOnly(file.parent.path, directory: true);
      await file.writeAsBytes(proof.encode(), flush: true);
      x
        ..paidPosition = position
        ..outcome = 'mined';
      if (x.change.value > 0) {
        final why = takeOn(x.change, x.changeTo, 'the change');
        if (why == null) {
          x.changePosition = s.store.notes.last.position;
        } else {
          r.say('payment for invoice ${hex.encode(invoice.id)}: the change was not taken on: $why');
        }
      }
      done.add({'round': round, 'invoice': hex.encode(invoice.id), 'leaf': position});
      r.say('round $round: the payment for invoice ${hex.encode(invoice.id)} is at leaf $position; cloak proof makes '
          'its proof');
    }
    for (final x in s.state.withdrawals.where((x) => x.outcome == 'accepted' && x.round == round)) {
      final why = x.change.value > 0 ? takeOn(x.change, x.changeTo, 'the change') : null;
      x.outcome = 'mined';
      if (why == null && x.change.value > 0) x.changePosition = s.store.notes.last.position;
      done.add({'round': round, 'withdrawal': x.amount});
      r.say('round $round: the withdrawal of ${x.amount} is mined${why == null ? '' : '; the change was not taken on: $why'}');
    }
    for (final d in s.state.deposits.where((d) => d.status == 'accepted' && d.intoRound == round)) {
      final addressOfNote = await _addressOf(s, d.note.d);
      final why = takeOn(d.note, addressOfNote, 'the deposit\'s note');
      if (why == null) {
        d
          ..status = 'taken'
          ..position = s.store.notes.last.position;
        done.add({'round': round, 'deposit': d.covenantTxid, 'leaf': d.position});
        r.say('round $round: the deposit ${d.covenantTxid} is a note at leaf ${d.position}');
      } else {
        r.say('round $round: the deposit ${d.covenantTxid} was not taken on: $why');
      }
    }
    if (!awaitedRounds(s.state).contains(round)) s.state.checkpoints.remove(round);
  }
  r.quiet('settled', done);
}

/// The address of this wallet's with diversifier [d], as bytes. A note's
/// commitment is made under the address key alone, which the diversifier and
/// the incoming viewing key fix.
Future<List<int>> _addressOf(Session s, List<int> d) async => (await NoteAddress.derive(s.poolKeys.ivk, d)).bytes;
