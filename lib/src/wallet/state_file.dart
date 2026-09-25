import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'wallet_dir.dart';

/// A payment this wallet built and submitted, kept so a later command can
/// finish it.
///
/// `cloak pay` and `cloak proof` are two processes, often a day apart, and
/// libcloak's `BuiltPayment` lives in memory. So what the proof needs is
/// written down here: the invoice, the note paid and the address it was paid
/// to, the change and where it went, the note spent, and what the pool said.
///
/// The payee's note opening is not a secret of the payer's: the payer built
/// it for the payee and hands it over inside the proof. The change opening is
/// the payer's own note, the same kind of thing the note store holds.
class PaymentRecord {
  final List<int> invoice;
  final List<int> submissionId;
  final int spentPosition;
  final NoteOpening paid, change;
  final List<int> paidTo, changeTo;
  final int anchorRound;

  /// `accepted`, `refused`, `expired`, `unanswered` or `unsent`, as libcloak
  /// names a submission's outcome.
  String outcome;

  /// The round the coordinator accepted it into.
  int? round;

  /// The leaf the payee's note landed at, once the round has been read.
  int? paidPosition;

  /// The leaf the payer's change landed at, once the round has been read.
  int? changePosition;

  PaymentRecord({
    required this.invoice,
    required this.submissionId,
    required this.spentPosition,
    required this.paid,
    required this.change,
    required this.paidTo,
    required this.changeTo,
    required this.anchorRound,
    required this.outcome,
    this.round,
    this.paidPosition,
    this.changePosition,
  });

  List<int> get invoiceId => Invoice.decode(invoice).id;

  Map<String, Object?> toJson() => {
        'invoice': hex.encode(invoice),
        'submission': hex.encode(submissionId),
        'spent': spentPosition,
        'paid': _opening(paid),
        'paidTo': hex.encode(paidTo),
        'change': _opening(change),
        'changeTo': hex.encode(changeTo),
        'anchorRound': anchorRound,
        'outcome': outcome,
        'round': round,
        'paidPosition': paidPosition,
        'changePosition': changePosition,
      };

  static PaymentRecord fromJson(Map<String, Object?> j) => PaymentRecord(
        invoice: _hex(j, 'invoice'),
        submissionId: _hex(j, 'submission'),
        spentPosition: _int(j, 'spent'),
        paid: _readOpening(j, 'paid'),
        change: _readOpening(j, 'change'),
        paidTo: _hex(j, 'paidTo'),
        changeTo: _hex(j, 'changeTo'),
        anchorRound: _int(j, 'anchorRound'),
        outcome: _str(j, 'outcome'),
        round: j['round'] == null ? null : _int(j, 'round'),
        paidPosition: j['paidPosition'] == null ? null : _int(j, 'paidPosition'),
        changePosition: j['changePosition'] == null ? null : _int(j, 'changePosition'),
      );
}

/// A withdrawal this wallet submitted, kept until its round is read and its
/// change taken on.
class WithdrawalRecord {
  final List<int> submissionId;
  final int spentPosition;
  final int amount;
  final NoteOpening change;
  final List<int> changeTo;

  /// As a payment's: `accepted`, `unanswered`, and so on; `mined` once its
  /// round is read.
  String outcome;
  int? round;
  int? changePosition;

  WithdrawalRecord({
    required this.submissionId,
    required this.spentPosition,
    required this.amount,
    required this.change,
    required this.changeTo,
    required this.outcome,
    this.round,
    this.changePosition,
  });

  Map<String, Object?> toJson() => {
        'submission': hex.encode(submissionId),
        'spent': spentPosition,
        'amount': amount,
        'change': _opening(change),
        'changeTo': hex.encode(changeTo),
        'outcome': outcome,
        'round': round,
        'changePosition': changePosition,
      };

  static WithdrawalRecord fromJson(Map<String, Object?> j) => WithdrawalRecord(
        submissionId: _hex(j, 'submission'),
        spentPosition: _int(j, 'spent'),
        amount: _int(j, 'amount'),
        change: _readOpening(j, 'change'),
        changeTo: _hex(j, 'changeTo'),
        outcome: _str(j, 'outcome'),
        round: j['round'] == null ? null : _int(j, 'round'),
        changePosition: j['changePosition'] == null ? null : _int(j, 'changePosition'),
      );
}

/// A transparent transaction this wallet built, recorded before it was
/// broadcast.
///
/// The two failures are not symmetrical. Recording a broadcast that did not
/// happen costs a re-broadcast of bytes already built, and `cloak status`
/// shows it. Broadcasting without a record means a funding coin is spent by a
/// transaction the wallet has forgotten, and the next run builds a second one
/// against the same coin, which the chain rejects and nobody can explain. So
/// the record comes first, always.
class TransparentRecord {
  /// `deposit`, `refund` or `withdrawal`.
  final String kind;
  final String txid;
  final String txHex;
  bool broadcast;

  TransparentRecord({required this.kind, required this.txid, required this.txHex, this.broadcast = false});

  Map<String, Object?> toJson() => {'kind': kind, 'txid': txid, 'tx': txHex, 'broadcast': broadcast};

  static TransparentRecord fromJson(Map<String, Object?> j) => TransparentRecord(
      kind: _str(j, 'kind'), txid: _str(j, 'txid'), txHex: _str(j, 'tx'), broadcast: j['broadcast'] == true);
}

/// A deposit this wallet made into the pool, from covenant to note.
class DepositRecord {
  /// The covenant transaction's id, and the round it can be taken in by.
  final String covenantTxid;
  final int intoRound;
  final int satoshis;
  final int refundAfter;

  /// The note the deposit becomes, and its commitment.
  final NoteOpening note;
  final List<int> commitment;

  /// The covenant's output index in its transaction.
  final int vout;

  /// The deposit transfer, as its submission carries it, kept so it can be
  /// submitted by a later run once the covenant is mined.
  final List<int> transfer;

  /// `recorded`, `broadcast`, `accepted`, `taken`, `refunded` or `refused`.
  String status;
  List<int>? submissionId;
  int? position;

  /// What the coordinator said, when it refused.
  String? reason;

  DepositRecord({
    required this.covenantTxid,
    required this.intoRound,
    required this.satoshis,
    required this.refundAfter,
    required this.note,
    required this.commitment,
    required this.vout,
    required this.transfer,
    required this.status,
    this.submissionId,
    this.position,
    this.reason,
  });

  Map<String, Object?> toJson() => {
        'covenant': covenantTxid,
        'intoRound': intoRound,
        'satoshis': satoshis,
        'refundAfter': refundAfter,
        'note': _opening(note),
        'commitment': hex.encode(commitment),
        'vout': vout,
        'transfer': hex.encode(transfer),
        'status': status,
        'submission': submissionId == null ? null : hex.encode(submissionId!),
        'position': position,
        'reason': reason,
      };

  static DepositRecord fromJson(Map<String, Object?> j) => DepositRecord(
        covenantTxid: _str(j, 'covenant'),
        intoRound: _int(j, 'intoRound'),
        satoshis: _int(j, 'satoshis'),
        refundAfter: _int(j, 'refundAfter'),
        note: _readOpening(j, 'note'),
        commitment: _hex(j, 'commitment'),
        vout: _int(j, 'vout'),
        transfer: _hex(j, 'transfer'),
        status: _str(j, 'status'),
        submissionId: j['submission'] == null ? null : _hex(j, 'submission'),
        position: j['position'] == null ? null : _int(j, 'position'),
        reason: j['reason'] as String?,
      );
}

/// This program's own state: what libcloak's four files do not hold and a
/// later command needs.
///
/// It holds the pool's descriptor, so commands that need no network still
/// know the pool's shape and tokenId; the invoices this wallet issued, so a
/// payee can tell which one a proof pays; and the payments, deposits and
/// transparent transactions still in flight.
///
/// It is JSON rather than a packed encoding because it is small, read whole,
/// and the one file a person debugging a stuck payment will want to open. It
/// is versioned like every other state file, and a newer version is refused
/// naming both numbers.
class CloakState {
  static const version = 1;

  /// A state file is small; anything past this is not one.
  static const maxFile = 16 * 1024 * 1024;

  /// The pool's descriptor, as its feed published it, or null before the
  /// first sync.
  List<int>? descriptor;

  /// The last round the pool announced that this wallet has folded, and that
  /// round's transaction id in display order: a deposit's covenant names the
  /// live round's PP3, which is that transaction's output 3.
  int? liveRound;
  List<int>? liveRoundTxId;

  final List<List<int>> issued;
  final List<PaymentRecord> payments;
  final List<WithdrawalRecord> withdrawals;

  /// The pool's frontier at each round something of this wallet's is waiting
  /// on, kept by `cloak sync` when its fold stood at that round: a leaf's path
  /// above its block is made from it, and a fold that has moved on cannot
  /// give it back. A few hundred bytes each, dropped once the round is read.
  final Map<int, List<int>> checkpoints;
  final List<DepositRecord> deposits;
  final List<TransparentRecord> transparent;

  /// The satoshis the transparent side could spend when a command last opened
  /// it, or null before one has. Only this wallet's own commands move those
  /// coins, each opening the side to do it, so `cloak balance` reads this
  /// rather than asking for the passphrase and starting the chain.
  int? transparentSats;

  CloakState({
    this.descriptor,
    this.liveRound,
    this.liveRoundTxId,
    List<List<int>>? issued,
    List<PaymentRecord>? payments,
    List<WithdrawalRecord>? withdrawals,
    Map<int, List<int>>? checkpoints,
    List<DepositRecord>? deposits,
    List<TransparentRecord>? transparent,
    this.transparentSats,
  })  : issued = issued ?? [],
        payments = payments ?? [],
        withdrawals = withdrawals ?? [],
        checkpoints = checkpoints ?? {},
        deposits = deposits ?? [],
        transparent = transparent ?? [];

  PoolDescriptor? get pool => descriptor == null ? null : PoolMessage.decode(descriptor!) as PoolDescriptor;

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'descriptor': descriptor == null ? null : hex.encode(descriptor!),
        'live': liveRound == null ? null : {'round': liveRound, 'roundTxId': hex.encode(liveRoundTxId!)},
        'issued': [for (final i in issued) hex.encode(i)],
        'payments': [for (final p in payments) p.toJson()],
        'withdrawals': [for (final w in withdrawals) w.toJson()],
        'checkpoints': {for (final e in checkpoints.entries) '${e.key}': hex.encode(e.value)},
        'deposits': [for (final d in deposits) d.toJson()],
        'transparent': [for (final t in transparent) t.toJson()],
        if (transparentSats != null) 'transparentSats': transparentSats,
      });

  static CloakState decode(String text, {required String path}) {
    final Object? doc;
    try {
      doc = jsonDecode(text);
    } on FormatException catch (e) {
      throw Refusal('wallet state', '$path is not JSON (${e.message}), and it is refused rather than repaired');
    }
    if (doc is! Map<String, Object?>) throw Refusal('wallet state', '$path does not hold a state object');
    final m = doc;
    final v = m['version'];
    if (v is! int) throw Refusal('version', '$path carries no version');
    if (v != version) {
      throw Refusal('version', '$path is wallet state version $v and this build writes version $version');
    }
    try {
      final d = m['descriptor'];
      final descriptor = d == null ? null : hex.decode(d as String);
      if (descriptor != null) {
        final msg = PoolMessage.decode(descriptor);
        if (msg is! PoolDescriptor) throw const FormatException('the descriptor field is not a descriptor');
      }
      List<Map<String, Object?>> list(String k) =>
          [for (final x in (m[k] as List<Object?>? ?? const [])) x as Map<String, Object?>];
      final live = m['live'] as Map<String, Object?>?;
      return CloakState(
        descriptor: descriptor,
        liveRound: live == null ? null : _int(live, 'round'),
        liveRoundTxId: live == null ? null : _hex(live, 'roundTxId'),
        issued: [for (final x in (m['issued'] as List<Object?>? ?? const [])) hex.decode(x as String)],
        payments: [for (final x in list('payments')) PaymentRecord.fromJson(x)],
        withdrawals: [for (final x in list('withdrawals')) WithdrawalRecord.fromJson(x)],
        checkpoints: {
          for (final e in ((m['checkpoints'] as Map<String, Object?>?) ?? const {}).entries)
            int.parse(e.key): hex.decode(e.value as String)
        },
        deposits: [for (final x in list('deposits')) DepositRecord.fromJson(x)],
        transparent: [for (final x in list('transparent')) TransparentRecord.fromJson(x)],
        transparentSats: m['transparentSats'] as int?,
      );
    } on Refusal catch (e) {
      throw Refusal(e.step, '${e.reason} (reading $path)');
    } catch (e) {
      throw Refusal('wallet state', '$path does not read: $e; it is refused rather than repaired');
    }
  }

  /// The state in [dir], or an empty one when there is none yet.
  static Future<CloakState> open(WalletDir dir) async {
    final f = File(dir.state);
    if (!await f.exists()) return CloakState();
    final length = await f.length();
    if (length > maxFile) throw Refusal('size', 'a wallet state is at most $maxFile bytes and ${dir.state} is $length');
    return decode(await f.readAsString(), path: dir.state);
  }

  static String temporaryFor(String path) => '$path.tmp';

  /// Writes this state to [dir], temp-then-rename, owner-only before a byte
  /// is written.
  ///
  /// [beforeRename] is the suite's handle on the one moment that matters: it
  /// runs after the temporary file is whole and before it replaces the live
  /// one, which is where a killed process leaves its wreckage.
  Future<void> save(WalletDir dir, {Future<void> Function()? beforeRename}) async {
    final tmp = File(temporaryFor(dir.state));
    await tmp.writeAsBytes(const [], flush: true);
    await WalletDir.ownerOnly(tmp.path);
    await tmp.writeAsString(encode(), flush: true);
    if (beforeRename != null) await beforeRename();
    await tmp.rename(dir.state);
  }
}

String _opening(NoteOpening o) {
  final w = Writer.raw();
  o.writeTo(w);
  return hex.encode(w.done());
}

NoteOpening _readOpening(Map<String, Object?> j, String k) {
  final r = Reader.raw(_hex(j, k));
  final o = NoteOpening.read(r);
  r.end(k, '%n bytes after the note opening');
  return o;
}

List<int> _hex(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! String) throw Refusal(k, 'is missing');
  try {
    return hex.decode(v);
  } on FormatException {
    throw Refusal(k, 'is not hexadecimal');
  }
}

int _int(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! int || v < 0) throw Refusal(k, 'is not a whole number');
  return v;
}

String _str(Map<String, Object?> j, String k) {
  final v = j[k];
  if (v is! String) throw Refusal(k, 'is missing');
  return v;
}
