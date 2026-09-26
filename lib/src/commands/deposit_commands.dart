import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart' show BEEF, BEEFException;
import 'package:tstokenlib/tstokenlib.dart';

import '../net/beef_service.dart';
import '../shell/bounded_file.dart';
import '../shell/call.dart';
import '../shell/world.dart' show TransparentSide;
import '../wallet/session.dart';
import '../wallet/state_file.dart';
import 'settling.dart';
import 'submitting.dart';

void depositOptions(ArgParser p) => p
  ..addOption('amount', valueHelp: 'satoshis', help: 'what goes into the pool')
  ..addOption('refund-height', valueHelp: 'block', help: 'the block the deposit is refundable from')
  ..addFlag('yes', negatable: false, help: 'hand the deposit over without asking; the refund height is still printed first')
  ..addFlag('submit', negatable: false,
      help: 'submit deposits left unanswered, and those whose covenant this wallet broadcast and is now mined, and nothing else')
  ..addOption('broadcast', valueHelp: 'txid', help: 'put a recorded deposit covenant on the chain yourself, without rebuilding it');

void refundOptions(ArgParser p) => p
  ..addOption('deposit', valueHelp: 'txid', help: 'the deposit covenant to take back')
  ..addOption('broadcast', valueHelp: 'txid', help: 'send a recorded refund without rebuilding it');

void withdrawOptions(ArgParser p) => p
  ..addOption('amount', valueHelp: 'satoshis', help: 'what comes out of the pool')
  ..addOption('to', valueHelp: 'address', help: 'the transparent address it is paid to')
  ..addFlag('yes', negatable: false, help: 'proceed without asking; the warning is still printed');

/// The covenant's output index in a transaction built by [ShieldedPoolTool],
/// and the size bound a deposit's transaction is held to.
const covenantVoutInTool = ShieldedPoolTool.depositVout;

/// The deposit covenant's locking script for these terms.
///
/// tstokenlib writes the covenant inside `createDepositTxn` and does not
/// export the script generator, so the script is read off a transaction built
/// over a throwaway coin: the lock depends on the terms alone, and the coin,
/// the key and the change never leave this function.
List<int> covenantLock(
    {required List<int> commitment, required List<int> pp3Outpoint, required List<int> refundPKH, required int refundAfter}) {
  final key = SVPrivateKey(networkType: NetworkType.TEST);
  final addr = key.toAddress(networkType: NetworkType.TEST);
  final coin = Transaction()
    ..addInput(TransactionInput('00' * 32, 0, TransactionInput.MAX_SEQ_NUMBER))
    ..addOutput(TransactionOutput(BigInt.from(100000000), P2PKHLockBuilder.fromAddress(addr).getScriptPubkey()));
  final tx = ShieldedPoolTool().createDepositTxn(
      fundingTx: coin,
      fundingVout: 0,
      fundingSigner: DefaultTransactionSigner(SighashType.SIGHASH_FORKID.value | SighashType.SIGHASH_ALL.value, key),
      fundingPubKey: key.publicKey,
      changeAddress: addr,
      commitment: commitment,
      satoshis: BigInt.from(1000),
      pp3Outpoint: pp3Outpoint,
      refundPKH: refundPKH,
      refundAfter: refundAfter);
  return tx.outputs[covenantVoutInTool].script.buffer;
}

/// The output a round's PP3 occupies, which tstokenlib writes as a literal 3
/// wherever it names the successor's PP3.
const pp3Vout = 3;

/// The live pool's PP3: round [roundTxId]'s output 3, as a 36-byte outpoint.
/// [roundTxId] is in display order; an outpoint carries the internal order.
List<int> pp3Outpoint(List<int> roundTxId) =>
    [...roundTxId.reversed, ...(Uint8List(4)..buffer.asByteData().setUint32(0, pp3Vout, Endian.little))];

/// `cloak receive`: BSV another person handed over, as BEEF.
///
/// The BEEF is bounded and parsed here first, so a payment that is not one is
/// refused naming what stopped it before libspiffy sees a byte. libspiffy then
/// checks its merkle proof against this wallet's own headers, and parks a
/// payment whose block the chain has not reached, naming the height it waits
/// for; nothing asks for that block.
void receiveOptions(ArgParser p) => p.addOption('txid',
    valueHelp: 'txid',
    help: 'ask the BEEF service (beef.url in config.yaml) for this transaction\'s BEEF, instead of giving it');

Future<void> runReceive(Call call) async {
  final txid = call.option('txid');
  if (txid != null && call.args.rest.isNotEmpty) {
    throw UsageError('cloak receive takes the BEEF or --txid, not both');
  }
  final List<int> bytes;
  final BEEF beef;
  if (txid != null) {
    final config = await call.config();
    final service = BeefService(config.beefUrl, timeout: config.timeout, maxAnswer: MessageKind.beef.max + 1024);
    final given = await service.fetch(txid);
    bytes = _decodeBeefHex(given, 'the BEEF ${config.beefUrl} gave for $txid');
    beef = readBeef(bytes);
    if (!beefHolds(beef, txid)) {
      throw Refusal('BEEF', '${config.beefUrl} answered $txid with a BEEF that does not hold that transaction');
    }
    call.report.say('the BEEF came from ${config.beefUrl}');
  } else {
    bytes = await readBeefHex(call.positional(0, 'the BEEF payment, as hex or a file holding its hex, or --txid'));
    beef = readBeef(bytes);
  }
  final s = await call.open(write: true, keys: true);
  final t = await s.transparent();
  final tip = (await (await s.headers()).tip()).height;
  final above = [for (final b in beef.bumps) if (b.blockHeight > tip) b.blockHeight];
  final got = await t.receive(bytes);
  final r = call.report
    ..add('txid', got.txid, 'payment ${got.txid}')
    ..add('satoshis', got.satoshis, 'pays this wallet ${got.satoshis} satoshis');
  if (got.parked) {
    final waiting = above.isEmpty ? tip + 1 : above.reduce(max);
    r
      ..add('waitingFor', waiting, 'parked: its block is at height $waiting and this wallet\'s chain ends at $tip')
      ..quiet('tip', tip)
      ..say('it is taken on when the chain reaches that height; nothing asks for that block');
  } else {
    r.quiet('waitingFor', null);
  }
  // for cloak balance, which reads what the transparent side holds from here;
  // a payment taken before, or one parked, moves nothing
  if (await t.spendable() != s.state.transparentSats) await s.save(view: false, store: false);
}

/// The bytes of a BEEF payment handed over as hex: [given] is a file holding
/// the hex, or else the hex itself, typed or pasted on the command line.
///
/// Hex is how a payment is handed over: explorers, wallets and ARC give BEEF
/// as hex, and nobody has its raw bytes to hand. Whitespace is ignored, since
/// pasted hex picks up line breaks.
Future<List<int>> readBeefHex(String given) async {
  final bool isFile;
  try {
    isFile = FileSystemEntity.isFileSync(given);
  } on FileSystemException {
    // a string too long to be a path is not one
    return _decodeBeefHex(given, 'the BEEF given');
  }
  if (isFile) {
    final text = await BoundedFile.read(given, MessageKind.beef);
    return _decodeBeefHex(String.fromCharCodes(text), given);
  }
  if (!_hexOnly.hasMatch(given.replaceAll(_space, ''))) {
    throw Refusal('BEEF',
        'there is no file named ${_shown(given)}, and it is not BEEF hex either; give the payment\'s hex, or a '
        'file holding it');
  }
  return _decodeBeefHex(given, 'the BEEF given');
}

final _space = RegExp(r'\s');
final _hexOnly = RegExp(r'^[0-9a-fA-F]+$');

List<int> _decodeBeefHex(String text, String what) {
  final h = text.replaceAll(_space, '');
  if (h.isEmpty) throw Refusal('BEEF', '$what is empty; a BEEF payment is given as hex');
  final bad = RegExp(r'[^0-9a-fA-F]').firstMatch(h);
  if (bad != null) {
    throw Refusal('BEEF',
        '$what is not BEEF hex: it has ${_describe(bad.group(0)!)} at character ${bad.start + 1}. A BEEF payment is '
        'given as hex, the way a wallet or an explorer hands it over');
  }
  if (h.length.isOdd) throw Refusal('BEEF', '$what has an odd number of hex digits (${h.length}), so a digit is missing');
  if (h.length ~/ 2 > PoolMessage.maxTx) {
    throw Refusal('size', 'a BEEF payment is at most ${PoolMessage.maxTx} bytes and $what is ${h.length ~/ 2}');
  }
  return hex.decode(h);
}

String _describe(String c) {
  final code = c.codeUnitAt(0);
  return code >= 0x20 && code < 0x7f ? '"$c"' : 'a byte 0x${code.toRadixString(16).padLeft(2, '0')}';
}

String _shown(String s) => s.length <= 40 ? '"$s"' : '"${s.substring(0, 32)}..." (${s.length} characters)';

/// Whether one of [beef]'s transactions is [txid].
bool beefHolds(BEEF beef, String txid) {
  final want = txid.toLowerCase();
  return beef.txs.any((raw) => Transaction.fromHex(hex.encode(raw)).id == want);
}

/// A BEEF payment's structure, or a refusal naming what stopped it.
BEEF readBeef(List<int> bytes) {
  try {
    return BEEF.parse(Uint8List.fromList(bytes));
  } on BEEFException catch (e) {
    throw Refusal('BEEF', e.message);
  } catch (e) {
    throw Refusal('BEEF', 'does not read: $e');
  }
}

/// `cloak deposit`: BSV into the pool, behind the covenant.
///
/// The one place this wallet acts before it can check. It locks coins to a
/// covenant naming the live round's PP3, a round it has folded and checked,
/// and nothing can prove in advance that the next round will take the
/// deposit in. So the loss is bounded to time: the covenant pays the money
/// back to a key only this wallet holds, from a block height chosen here,
/// printed before anything is broadcast, and confirmed by the person.
///
/// It is one step. This builds the covenant and the deposit's transfer,
/// records both, and hands them to the coordinator, which broadcasts the
/// covenant and takes the deposit in once the network has seen it
/// (pool-coordinator 0.1.8 and later). A coordinator from before that wants
/// the covenant mined first: then this broadcasts it and a later `cloak sync`
/// submits it, as deposits used to go.
Future<void> runDeposit(Call call) async {
  final rebroadcast = call.option('broadcast');
  if (rebroadcast != null) return _rebroadcast(call, rebroadcast, kind: 'deposit');
  if (call.flag('submit')) {
    final s = await call.open(write: true, keys: true);
    await s.transparent();
    await settleStaleReplies(s);
    await submitWaitingDeposits(call, s);
    return;
  }
  final whole = Stopwatch()..start();
  final amount = call.intOption('amount', min: 1) ?? (throw UsageError('cloak deposit needs --amount'));
  final s = await call.open(write: true, keys: true);
  final pool = s.poolOrRefuse;
  final view = s.viewOrRefuse;

  // the covenant names a round this wallet has folded and checked
  if (view.checkedTo != view.round) {
    throw Refusal('unchecked',
        'the pool view has folded to round ${view.round} and is checked to round ${view.checkedTo}; a deposit names '
        'the live round\'s PP3, so that round has to be one this wallet proved. Nothing was spent');
  }
  final live = s.state.liveRound, liveTx = s.state.liveRoundTxId;
  if (live != view.round || liveTx == null) {
    throw Refusal('round',
        'this wallet has not read round ${view.round}\'s announcement, so it does not know that round\'s '
        'transaction; run cloak sync. Nothing was spent');
  }

  final t = await s.transparent();
  final tip = (await (await s.headers()).tip()).height;
  final earliest = tip + s.config.refundMinimum;
  final refundAfter = call.intOption('refund-height') ?? tip + s.config.refundMargin;
  if (refundAfter < earliest) {
    throw Refusal('refund height',
        'a refund from block $refundAfter opens too soon: a coordinator skips a deposit whose refund could be mined '
        'before its round. The earliest this wallet accepts is block $earliest');
  }

  final own = Stopwatch()..start();
  final (proved, whyProve) = await DepositBuilder.prove(
      keys: s.poolKeys, address: await s.nextAddress(), amount: amount, spendP: pool.spendP, rng: call.world.rng);
  if (proved == null) throw whyProve!;
  final refundKey = SVPrivateKey(networkType: NetworkType.TEST);
  final refundPKH = hex.decode(refundKey.toAddress(networkType: NetworkType.TEST).pubkeyHash160);
  final lock = covenantLock(
      commitment: proved.commitment, pp3Outpoint: pp3Outpoint(liveTx), refundPKH: refundPKH, refundAfter: refundAfter);
  own.stop();

  await confirm(call, [
    'depositing $amount satoshis into the pool, to be taken in by round ${view.round + 1}.',
    'if no round takes it in, it is refundable in full from block $refundAfter (the chain is at $tip), by cloak '
        'refund, with nobody\'s cooperation. Until then the money is locked.',
    'this is public: the amount and the coins it is paid from are on the chain for anyone to read.',
  ], what: 'the deposit');

  final network = Stopwatch()..start();
  final (built, whyFund) = await t.payTo(lock, amount);
  network.stop();
  if (built == null) throw whyFund!;
  final covenant = Transaction.fromHex(built.txHex);
  final vout = covenant.outputs.indexWhere((o) => _same(o.script.buffer, lock));
  final (deposit, whyBack) = vout < 0 ? (null, const Refusal('covenant', 'the funded transaction carries no covenant')) : proved.backedBy(covenant, vout: vout);
  if (deposit == null) {
    await t.release(built.txid);
    throw whyBack!;
  }

  // recorded before it is broadcast: a broadcast the program did not live to
  // record is a coin spent by a transaction the wallet has forgotten
  final sealed = await s.sealed();
  await sealed.setString('refund/${built.txid}', refundKey.toWIF());
  s.state.transparent.add(TransparentRecord(kind: 'deposit', txid: built.txid, txHex: built.txHex));
  s.state.deposits.add(DepositRecord(
      covenantTxid: built.txid,
      intoRound: view.round + 1,
      satoshis: amount,
      refundAfter: refundAfter,
      note: proved.note,
      commitment: proved.commitment,
      vout: vout,
      transfer: deposit.transfer.encode(pool.spendP),
      status: 'recorded'));
  await s.record(JournalEntry.depositBuilt(deposit, at: call.world.now()));
  await s.save(view: false, store: false);
  whole.stop();

  final r = call.report
    ..add('covenant', built.txid, 'deposit covenant ${built.txid}')
    ..add('amount', amount, '$amount satoshis, for round ${view.round + 1}')
    ..quiet('intoRound', view.round + 1)
    ..add('refundAfter', refundAfter, 'refundable from block $refundAfter')
    ..add('clockMs', {'building': whole.elapsedMilliseconds - network.elapsedMilliseconds - deposit.proving.inMilliseconds, 'proving': deposit.proving.inMilliseconds, 'funding': network.elapsedMilliseconds},
        'clock: building ${whole.elapsedMilliseconds - network.elapsedMilliseconds - deposit.proving.inMilliseconds} ms outside the spend proof (${deposit.proving.inMilliseconds} ms) and the funding (${network.elapsedMilliseconds} ms)');
  final d = s.state.deposits.last;
  final handed = Stopwatch()..start();
  final said = await _handOver(call, s, t, d);
  r
    ..quiet('status', d.status)
    ..quiet('answerMs', handed.elapsedMilliseconds)
    ..say(said);
  if (d.status == 'released') {
    throw Refusal('pool', 'the pool refused the deposit: ${d.reason}. The covenant was never broadcast, and its coins are '
        'spendable again; nothing was spent');
  }
}

/// Hands deposit [d] to the coordinator, covenant attached, and records what
/// came of it; returns a sentence for the person. The covenant is broadcast by
/// the coordinator, not here, unless the coordinator is one that wants it
/// mined first.
Future<String> _handOver(Call call, Session s, TransparentSide t, DepositRecord d) async {
  final covenant = s.state.transparent.firstWhere((x) => x.txid == d.covenantTxid);
  // submitting from here on: a run that dies before the answer leaves a
  // deposit `cloak sync` submits again, never one it forgets
  d.status = 'submitting';
  await s.save(view: false, store: false);
  final submission = PoolSubmission(_freshId(call), d.transfer, depositTx: hex.decode(covenant.txHex));
  final (client, whyOpen) = await CoordinatorClient.open(await s.transport(), timeout: s.config.timeout);
  if (client == null) {
    return 'the pool could not be reached (${whyOpen!.reason}); the deposit is recorded and nothing was spent. cloak sync '
        'hands it over again';
  }
  final outcome = await client.send(submission);
  d.submissionId = submission.id;
  final String said;
  switch (outcome.outcome) {
    case Submitted.accepted:
      d.status = 'accepted';
      _markSent(s, d.covenantTxid);
      await t.settle(d.covenantTxid);
      said = 'handed over: the pool broadcast the covenant and took the deposit in for round ${outcome.round ?? d.intoRound}';
    case Submitted.refused || Submitted.expired:
      final reason = outcome.sentence ?? outcome.refusal?.reason ?? 'no reason given';
      if (outcome.reason == RefusalReason.depositPending) {
        // an earlier hand-over of this very covenant is pending
        d.status = 'accepted';
        _markSent(s, d.covenantTxid);
        await t.settle(d.covenantTxid);
        said = 'the pool already holds this deposit for round ${d.intoRound}';
      } else if (outcome.reason == RefusalReason.depositCovenant && reason.contains('is not mined')) {
        // a coordinator from before 0.1.8: the covenant goes on the chain
        // from here, and `cloak sync` submits it once mined
        final why = await t.broadcast(covenant.txHex);
        if (why != null) {
          d.status = 'recorded';
          said = 'the pool wants the covenant mined first, and broadcasting it failed (${why.reason}); cloak deposit '
              '--broadcast ${d.covenantTxid} sends it';
        } else {
          _markBroadcast(s, d.covenantTxid);
          said = 'this pool takes a deposit once its covenant is mined: broadcast here, and cloak sync submits it when it is';
        }
      } else if (await t.release(d.covenantTxid)) {
        // never on the chain: nothing to refund, and nothing left to send
        d.status = 'released';
        d.reason = reason;
        s.state.transparent.removeWhere((x) => x.txid == d.covenantTxid);
        said = 'refused: $reason';
      } else {
        // the network knows the covenant, so the pool broadcast it before
        // refusing: its coins are spent, and the refund is the way back
        d.status = 'broadcast';
        d.reason = reason;
        _markSent(s, d.covenantTxid);
        said = 'refused after the covenant reached the network: $reason. It is refundable from block ${d.refundAfter} '
            'by cloak refund';
      }
    case Submitted.unanswered || Submitted.unsent:
      said = 'the pool did not answer; the deposit stays recorded as submitting and cloak sync hands it over again';
  }
  await s.save(view: false, store: false);
  return said;
}

/// The covenant [txid] is on the network, sent by someone else: its
/// transparent record counts as broadcast.
void _markSent(Session s, String txid) {
  for (final t in s.state.transparent) {
    if (t.txid == txid) t.broadcast = true;
  }
}

void _markBroadcast(Session s, String txid) {
  for (final t in s.state.transparent) {
    if (t.txid == txid) t.broadcast = true;
  }
  for (final d in s.state.deposits) {
    if (d.covenantTxid == txid && (d.status == 'recorded' || d.status == 'submitting')) d.status = 'broadcast';
  }
}

/// Sends a recorded transaction that was never broadcast, byte for byte as it
/// was built.
Future<void> _rebroadcast(Call call, String txid, {required String kind}) async {
  final s = await call.open(write: true, keys: true);
  final record = s.state.transparent.where((t) => t.txid == txid && t.kind == kind).firstOrNull;
  if (record == null) throw Refusal('record', 'this wallet recorded no $kind $txid');
  if (record.broadcast) throw Refusal('record', 'the $kind $txid was broadcast already');
  final why = await (await s.transparent()).broadcast(record.txHex, fundedHere: kind == 'deposit');
  if (why != null) throw why;
  _markBroadcast(s, txid);
  await s.save(view: false, store: false);
  call.report.add('broadcast', txid, 'broadcast $kind $txid, as it was recorded');
}

/// Submits every deposit left submitting (the pool did not answer) and every
/// deposit whose covenant this wallet broadcast itself and is now mined,
/// recording what the coordinator said. A broadcast one not yet mined is
/// left waiting, and said to be.
Future<void> submitWaitingDeposits(Call call, Session s) async {
  final waiting = [for (final d in s.state.deposits) if (d.status == 'broadcast' || d.status == 'submitting') d];
  final r = call.report;
  if (waiting.isEmpty) {
    r.add('deposits', const [], 'no deposit is waiting to be submitted');
    return;
  }
  final t = await s.transparent();
  final out = <Map<String, Object?>>[];
  for (final d in waiting) {
    if (d.status == 'submitting') {
      final said = await _handOver(call, s, t, d);
      out.add({'covenant': d.covenantTxid, 'status': d.status});
      r.say('deposit ${d.covenantTxid}: $said');
      continue;
    }
    if (!await t.mined(d.covenantTxid)) {
      out.add({'covenant': d.covenantTxid, 'status': 'waiting'});
      r.say('deposit ${d.covenantTxid}: its covenant is not mined yet');
      continue;
    }
    final covenant = s.state.transparent.firstWhere((x) => x.txid == d.covenantTxid);
    final submission = PoolSubmission(_freshId(call), d.transfer, depositTx: hex.decode(covenant.txHex));
    final (client, whyOpen) = await CoordinatorClient.open(await s.transport(), timeout: s.config.timeout);
    if (client == null) throw whyOpen!;
    final outcome = await client.send(submission);
    d.submissionId = submission.id;
    switch (outcome.outcome) {
      case Submitted.accepted:
        d.status = 'accepted';
      case Submitted.refused || Submitted.expired:
        if (outcome.reason == RefusalReason.depositPending) {
          d.status = 'accepted';
        } else {
          d.status = 'refused';
          d.reason = '${outcome.refusal!.step}: ${outcome.refusal!.reason}';
        }
      case Submitted.unanswered || Submitted.unsent:
        break;
    }
    out.add({'covenant': d.covenantTxid, 'status': d.status, 'outcome': outcome.outcome.name, 'round': outcome.round});
    r.say('deposit ${d.covenantTxid}: the pool: $outcome');
  }
  await s.save(view: false, store: false);
  r.quiet('deposits', out);
}

List<int> _freshId(Call call) {
  final rng = call.world.rng ?? Random.secure();
  return List.generate(16, (_) => rng.nextInt(256));
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// `cloak refund`: a deposit no round took in, taken back at its refund
/// height.
///
/// Refused before the height, naming the height and the chain's tip, and
/// refused for a deposit a round has taken in. The refund spends the
/// covenant with the key only this wallet holds, to a fresh address of its
/// own, and is recorded before it is broadcast.
Future<void> runRefund(Call call) async {
  final rebroadcast = call.option('broadcast');
  if (rebroadcast != null) return _rebroadcast(call, rebroadcast, kind: 'refund');
  final txid = call.option('deposit') ?? (throw UsageError('cloak refund needs --deposit, the covenant\'s txid'));
  final s = await call.open(write: true, keys: true);
  final d = s.state.deposits.where((x) => x.covenantTxid == txid).firstOrNull;
  if (d == null) throw Refusal('deposit', 'this wallet made no deposit $txid');
  if (d.status == 'refunded') throw Refusal('deposit', 'the deposit $txid was refunded already');
  final outpoint = '$txid:${d.vout}';
  if (d.status == 'taken' || (d.status == 'accepted' && (s.state.liveRound ?? 0) >= d.intoRound)) {
    throw Refusal('spent',
        'the covenant output $outpoint is already spent: round ${d.intoRound} took the deposit in, so there is '
        'nothing to refund and nothing was broadcast');
  }
  final t = await s.transparent();
  final tip = (await (await s.headers()).tip()).height;
  if (tip < d.refundAfter) {
    throw Refusal('refund height',
        'the deposit $txid is refundable from block ${d.refundAfter} and this wallet\'s chain is at block $tip');
  }
  final wif = await (await s.sealed()).getString('refund/$txid');
  if (wif == null) throw Refusal('refund key', 'this wallet holds no refund key for the deposit $txid');
  final covenant = s.state.transparent.firstWhere((x) => x.txid == txid);
  final payTo = await t.freshAddress();
  final refund = ShieldedPoolTool().createDepositRefundTxn(
      depositTx: Transaction.fromHex(covenant.txHex),
      depositVout: d.vout,
      refundKey: SVPrivateKey.fromWIF(wif),
      payTo: Address(payTo),
      lockTime: tip);
  s.state.transparent.add(TransparentRecord(kind: 'refund', txid: refund.id, txHex: refund.serialize()));
  await s.save(view: false, store: false);
  final why = await t.broadcast(refund.serialize(), fundedHere: false);
  call.report
    ..add('refund', refund.id, 'refund ${refund.id}')
    ..add('deposit', txid, 'of deposit $txid, ${d.satoshis} satoshis less the fee, to $payTo')
    ..quiet('satoshis', d.satoshis);
  if (why != null) {
    throw Refusal(why.step,
        '${why.reason}. The refund is recorded and not broadcast; cloak refund --broadcast ${refund.id} sends it');
  }
  for (final x in s.state.transparent) {
    if (x.txid == refund.id) x.broadcast = true;
  }
  d.status = 'refunded';
  await s.save(view: false, store: false);
}

/// Asks the person to confirm, after [lines] have been printed. `--yes`
/// proceeds without asking; with no terminal and no `--yes`, it refuses,
/// because a public, irreversible step is not taken on nobody's say-so.
Future<void> confirm(Call call, List<String> lines, {required String what}) async {
  for (final l in lines) {
    call.world.err.writeln('cloak: $l');
  }
  if (call.flag('yes')) return;
  final read = call.world.readLine;
  if (read == null) {
    throw Refusal('confirmation', 'no terminal is attached to confirm $what on; run it again with --yes to proceed');
  }
  final answer = (await read('proceed? [y/N] '))?.trim().toLowerCase();
  if (answer != 'y' && answer != 'yes') throw Refusal('confirmation', '$what was not confirmed, and nothing was done');
}

/// `cloak withdraw`: BSV out of the pool to a transparent address.
///
/// A transfer spending one note this wallet holds, taking the amount out to
/// the address named and carrying the withdrawal record that must name
/// exactly that amount; change returns as a note to a fresh address of this
/// wallet's. The pool's round pays the address; this wallet broadcasts
/// nothing. The amount and the destination are public, and the person is
/// told so before anything is built.
Future<void> runWithdraw(Call call) async {
  final amount = call.intOption('amount', min: 1) ?? (throw UsageError('cloak withdraw needs --amount'));
  final to = call.option('to') ?? (throw UsageError('cloak withdraw needs --to, the transparent address it pays'));
  final List<int> payTo;
  try {
    payTo = hex.decode(Address.fromBase58(to).pubkeyHash160);
  } catch (_) {
    throw UsageError('--to is a transparent address, and "$to" is not one');
  }
  final s = await call.open(write: true, keys: true);
  final pool = s.poolOrRefuse;
  final view = s.viewOrRefuse;
  final tip = view.round;
  final (choice, why) = s.store.choose(amount: amount, asset: PoolHash.bsvAsset, view: view, tip: tip);
  if (choice == null) {
    throw Refusal(why!.step, 'withdrawing $amount: ${why.reason}. No proof was computed');
  }
  await confirm(call, [
    'withdrawing $amount satoshis out of the pool to $to.',
    'this is public: the amount and the address it is paid to are on the chain for anyone to read.',
  ], what: 'the withdrawal');
  final change = await s.nextAddress();
  final (w, whyBuild) = await WithdrawalBuilder.build(
      keys: s.poolKeys,
      note: choice.note,
      notes: s.store,
      amount: amount,
      payTo: payTo,
      changeAddress: change,
      view: view,
      spendP: pool.spendP,
      tip: tip,
      rng: call.world.rng);
  if (w == null) throw whyBuild!;
  final whyShape = WithdrawalBuilder.check(w.transfer);
  if (whyShape != null) throw whyShape;
  await s.record(JournalEntry.withdrawalBuilt(w, at: call.world.now()));
  final submission = PoolSubmission.of(w.transfer, pool.spendP, rng: call.world.rng);
  final record = WithdrawalRecord(
      submissionId: submission.id,
      spentPosition: w.spent.position,
      amount: amount,
      change: w.change,
      changeTo: w.changeTo.bytes,
      outcome: 'sending');
  final sent = await submitReserved(s,
      note: w.spent,
      submission: submission,
      beforeSend: () async => s.state.withdrawals.add(record),
      record: (outcome) async {
        if (outcome == null) {
          record.outcome = 'unsent';
          return;
        }
        record
          ..outcome = outcome.outcome.name
          ..round = outcome.round;
        await s.record(JournalEntry.withdrawalAnswered(w, outcome, at: call.world.now()));
      });
  final outcome = sent.outcome;
  call.report
    ..add('amount', amount, 'withdrawing $amount satoshis to $to')
    ..add('to', to, 'out of the note at leaf ${w.spent.position}, change ${w.change.value} to a fresh address')
    ..quiet('leaf', w.spent.position)
    ..quiet('change', w.change.value)
    ..add('outcome', outcome.outcome.name, 'the pool: $outcome')
    ..quiet('round', outcome.round);
  switch (outcome.outcome) {
    case Submitted.accepted:
      call.report.say('round ${outcome.round} pays $to when it is mined');
    case Submitted.unanswered:
      throw Refusal('no answer',
          'the pool did not answer: ${outcome.refusal!.reason}. The withdrawal may still be in a round, so the note '
          'stays reserved; run cloak sync, then cloak status');
    case Submitted.refused || Submitted.expired || Submitted.unsent:
      final r = outcome.refusal!;
      throw Refusal(r.step, '${r.reason}; the note is released and nothing was withdrawn');
  }
}
