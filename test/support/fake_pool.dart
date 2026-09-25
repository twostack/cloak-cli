import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/testing.dart';
import 'package:tstokenlib/tstokenlib.dart';

import 'package:cloak_cli/cloak_cli.dart' show PoolMailbox;

import 'fakes.dart';

/// A fake pool's transport with a mailbox: notices the coordinator sent
/// unasked, and replies an earlier run gave up waiting for.
class FakePoolTransport extends FakeTransport implements PoolMailbox {
  final List<List<int>> notices = [];
  final List<List<int>> lateReplies = [];

  @override
  String? unreachable;

  FakePoolTransport({super.feed});

  @override
  Future<List<List<int>>> drainReplies() async {
    final out = [...lateReplies];
    lateReplies.clear();
    return out;
  }

  @override
  Future<List<List<int>>> readNotices() async {
    final out = [...notices];
    notices.clear();
    return out;
  }
}

/// A two-round pool, proved at test parameters, and the doubles a wallet
/// reaches it through.
///
/// It is libcloak's end-to-end fixture, lifted to where a command can use it:
/// tstokenlib's `PoolTestChain` proves the rounds, a ledger applies them, and
/// the feed, the catch-up answers and a header chain holding both witnesses
/// are built from what the ledger computed. Building it costs a few seconds,
/// so a test file builds one in `setUpAll` and shares it.
class FakePool {
  final PoolTestChain c;
  final PoolDescriptor pool;
  final PoolShape shape;
  final ShieldedRound round1, round2;
  final List<int> br1, br2, cm1, cm2;
  final PoolAnnouncement ann1, ann2;

  /// The fixture wallet's notes: 500 in round 1, and the 200 round 2 pays
  /// it, both to address 0.
  final ScannedNote note1, note32;
  final List<List<int>> path1, path32;

  final FakeBlock block1, block2;
  final List<int> round1Bytes, witness1Bytes, round2Bytes, witness2Bytes;

  FakePool._(
      this.c,
      this.pool,
      this.shape,
      this.round1,
      this.round2,
      this.br1,
      this.br2,
      this.cm1,
      this.cm2,
      this.ann1,
      this.ann2,
      this.note1,
      this.note32,
      this.path1,
      this.path32,
      this.block1,
      this.block2,
      this.round1Bytes,
      this.witness1Bytes,
      this.round2Bytes,
      this.witness2Bytes);

  /// The pool keys the fixture minted to, which a suite stands in for a
  /// wallet's seed.
  PoolWalletKeys get keys => c.f.wallet;

  static Future<FakePool> build() async {
    final c = await PoolTestChain.build();
    final pool = PoolDescriptor.forPool(
        network: NetworkType.TEST, issuance: c.r0, witness0: c.w0, slot0: c.y0.tx, plan: c.f.agg);
    final shape = PoolShape.forPool(pool).$1!;
    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger =
        ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);
    final scanner = ShieldedNoteScanner.forWallet(c.f.wallet, [c.f.walletD]);

    final round1 = ledger.apply(c.r1, c.w1, c.y1.tx);
    final br1 = List<int>.of(round1.blockRoot);
    final cm1 = List<int>.of(ledger.header.cmRoot);
    final note1 = (await scanner.scan(round1)).single;
    final path1 = [for (final x in ledger.tree.path(note1.position).siblings) List<int>.of(x)];

    final round2 = ledger.apply(c.r2, c.w2, c.y2.tx);
    final br2 = List<int>.of(round2.blockRoot);
    final cm2 = List<int>.of(ledger.header.cmRoot);
    final note32 = (await scanner.scan(round2)).single;
    final path32 = [for (final x in ledger.tree.path(note32.position).siblings) List<int>.of(x)];

    final ann1 = PoolAnnouncement.of(1, round1.header, c.r1, c.w1, c.y1.tx, blockRoot: br1);
    final ann2 = PoolAnnouncement.of(2, round2.header, c.r2, c.w2, c.y2.tx, blockRoot: br2);

    final headers = chainHolding(c);
    return FakePool._(
        c,
        pool,
        shape,
        round1,
        round2,
        br1,
        br2,
        cm1,
        cm2,
        ann1,
        ann2,
        note1,
        note32,
        path1,
        path32,
        headers.blockOf(hex.decode(c.w1.id))!,
        headers.blockOf(hex.decode(c.w2.id))!,
        hex.decode(c.r1.serialize()),
        hex.decode(c.w1.serialize()),
        hex.decode(c.r2.serialize()),
        hex.decode(c.w2.serialize()));
  }

  /// A header chain holding both rounds' witnesses, six blocks deep.
  static FakeHeaderSource chainHolding(PoolTestChain c) => FakeHeaderSource.holding([
        crypto.sha256.convert([0]).bytes,
        hex.decode(c.w1.id),
        hex.decode(c.w2.id),
      ], before: 3, after: 6);

  /// A fresh header source over the same chain, so each test counts its own
  /// calls.
  FakeHeaderSource headers() => chainHolding(c);

  /// The pool's side: a feed of [rounds] announcements after the descriptor,
  /// or [feed] when given, and a coordinator that accepts submissions into
  /// [acceptInto] and answers the three catch-up questions with the head at
  /// [head] (the last round by default) and the block roots in [roots]. With
  /// [catchUp] false it answers them with nothing at all, as
  /// `../pool-coordinator` does today; [answer] overrides any one reply.
  /// With [undelivered] the catch-up frames never reach the server, for that
  /// reason, as when the server cannot be dialled.
  FakePoolTransport transport({
    int rounds = 2,
    int acceptInto = 3,
    bool catchUp = true,
    List<List<int>>? feed,
    int? head,
    Map<int, List<int>>? roots,
    PoolCatchUpReply? Function(PoolCatchUpRequest request)? answer,
    String? undelivered,
  }) {
    final t = FakePoolTransport(feed: feed ??
        [
          pool.encode(),
          if (rounds >= 1) ann1.encode(),
          if (rounds >= 2) ann2.encode(),
        ]);
    final headRound = head ?? (rounds >= 2 ? 2 : (rounds == 1 ? 1 : 0));
    // the pool's own rules for answering, over this fake's blocks; built on
    // the first catch-up request, because building it replays the ledger
    PoolCatchUpResponder? built;
    PoolCatchUpResponder responder() => built ??= c.responder(minedTip: headRound, placement: (round, witness) {
          final block = round == 1 ? block1 : block2;
          final i = _index(block, witness.id);
          return (blockHash: block.hash, txIndex: i, branch: block.branchFor(i).$2);
        });
    t.answer = (frame) async {
      final msg = PoolMessage.decode(frame);
      if (msg is PoolSubmission) return PoolReply.accepted(msg.id, acceptInto).encode();
      if (msg is PoolCatchUpRequest) {
        if (undelivered != null) {
          t.unreachable = undelivered;
          throw TransportFailure('request', undelivered);
        }
        if (!catchUp) throw const TransportFailure('request', 'no reply arrived before the deadline');
        final special = answer?.call(msg);
        if (special != null) return special.encode();
        if (roots != null && msg.what == CatchUpKind.blockRoots) {
          return PoolCatchUpReply.blockRoots(id: msg.id, from: msg.from, roots: [
            for (int r = msg.from; r <= headRound && r - msg.from < msg.count; r++) roots[r]!
          ]).encode();
        }
        return (await responder().answer(msg)).encode();
      }
      throw StateError('the pool was asked ${msg.kind.name}');
    };
    return t;
  }

  /// The notice the coordinator sends a submitter when [round] is mined,
  /// naming the submissions [ids]: the round's txids and the witness's place
  /// in its block, and no transactions. [roundTxId] overrides the round's.
  PoolRoundMined notice(int round, List<List<int>> ids, {List<int>? roundTxId}) {
    final r = headReply(round);
    return PoolRoundMined(
        ids: ids,
        round: round,
        roundTxId: roundTxId ?? hex.decode((round == 1 ? c.r1 : c.r2).id),
        witnessTxId: hex.decode((round == 1 ? c.w1 : c.w2).id),
        blockHash: r.blockHash!,
        txIndex: r.txIndex,
        branch: r.branch);
  }

  /// A block root [root] with its first lane nudged, still inside the field:
  /// a root of some other tree.
  static List<int> bent(List<int> root) => [root[0] ^ 1, ...root.sublist(1)];

  /// The head proof for [round], as a coordinator that served catch-up would
  /// answer it.
  PoolCatchUpReply headReply(int round) => round == 1
      ? PoolCatchUpReply.head(
          round: 1,
          roundTx: round1Bytes,
          witnessTx: witness1Bytes,
          blockHash: block1.hash,
          txIndex: _index(block1, c.w1.id),
          branch: block1.branchFor(_index(block1, c.w1.id)).$2)
      : PoolCatchUpReply.head(
          round: 2,
          roundTx: round2Bytes,
          witnessTx: witness2Bytes,
          blockHash: block2.hash,
          txIndex: _index(block2, c.w2.id),
          branch: block2.branchFor(_index(block2, c.w2.id)).$2);

  /// The frontier at [round].
  PoolCatchUpReply frontierReply(int round) {
    final layout = ShieldedPoolLayout.forArities([2, 2], nullifierLevel: 1, receiptSlots: 2);
    final ledger =
        ShieldedLedger.open(layout, c.r0, c.w0, c.y0.tx, tokenId: c.tokenId, genesisHeader: c.genesisHeader);
    ledger.apply(c.r1, c.w1, c.y1.tx);
    if (round >= 2) ledger.apply(c.r2, c.w2, c.y2.tx);
    final f = ledger.frontier();
    return PoolCatchUpReply.frontier(round: f.round, blockRoot: f.blockRoot, left: f.left);
  }

  /// A standing proof of the fixture wallet's note from [round], as a payer
  /// hands one over.
  PaymentProof standingProof(int round) {
    final (proof, why) = round == 1
        ? PaymentProofs.standing(
            note: NoteOpening.of(note1.note),
            round: 1,
            roundTx: round1Bytes,
            witnessTx: witness1Bytes,
            blockHash: block1.hash,
            txIndex: _index(block1, c.w1.id),
            branch: block1.branchFor(_index(block1, c.w1.id)).$2,
            position: note1.position,
            path: path1)
        : PaymentProofs.standing(
            note: NoteOpening.of(note32.note),
            round: 2,
            roundTx: round2Bytes,
            witnessTx: witness2Bytes,
            blockHash: block2.hash,
            txIndex: _index(block2, c.w2.id),
            branch: block2.branchFor(_index(block2, c.w2.id)).$2,
            position: note32.position,
            path: path32);
    if (proof == null) throw StateError('the fixture proof did not build: $why');
    return proof;
  }

  /// libcloak's lineage attack (`test/lineage_attack_test.dart` there): round
  /// 1 with its PP1 replaced by a lookalike, the pool's first 563 bytes over a
  /// body that spends on a signature, and a witness the forger mined into a
  /// chain the payee's own header source vouches for. Returns the standing
  /// proof of the fixture wallet's round 1 note under it, and that chain.
  (PaymentProof, FakeHeaderSource) forgery() {
    final forgerKey = SVPrivateKey.fromWIF('cRHYFwjjw2Xn2gjxdGw6RRgKJZqipZx7j8i64NdwzxcD6SezEZV5');
    final forgerAddr = Address.fromPublicKey(forgerKey.publicKey, NetworkType.TEST);
    final real = c.r1.outputs[PoolEvidence.pp1Vout].script;
    final lookalike = SVScript.fromByteArray([
      ...real.buffer.sublist(0, PP1SpScriptGen.scriptBodyStart),
      for (var i = 0; i < 5; i++) OpCodes.OP_DROP,
      ...P2PKHLockBuilder.fromAddress(forgerAddr).getScriptPubkey().buffer,
    ]);
    final round = Transaction();
    for (final i in c.r1.inputs) {
      round.addInput(TransactionInput(i.prevTxnId, i.prevTxnOutputIndex, i.sequenceNumber,
          scriptBuilder: DefaultUnlockBuilder.fromScript(i.script ?? SVScript())));
    }
    for (int k = 0; k < c.r1.outputs.length; k++) {
      final o = c.r1.outputs[k];
      round.addOutput(TransactionOutput(o.satoshis, k == PoolEvidence.pp1Vout ? lookalike : o.script));
    }
    final witness = Transaction()
      ..addInput(TransactionInput('11' * 32, 1, TransactionInput.MAX_SEQ_NUMBER))
      ..addInput(TransactionInput(round.id, PoolEvidence.pp1Vout, TransactionInput.MAX_SEQ_NUMBER))
      ..addInput(TransactionInput(round.id, PoolEvidence.pp2Vout, TransactionInput.MAX_SEQ_NUMBER))
      ..addOutputs([TransactionOutput(BigInt.one, P2PKHLockBuilder.fromAddress(forgerAddr).getScriptPubkey())]);
    final chain = FakeHeaderSource.holding([
      crypto.sha256.convert([7]).bytes,
      hex.decode(witness.id),
    ], before: 3, after: 6);
    final block = chain.blockOf(hex.decode(witness.id))!;
    final index = _index(block, witness.id);
    final proof = PaymentProof.standing(
        round: 1,
        roundTx: hex.decode(round.serialize()),
        witnessTx: hex.decode(witness.serialize()),
        blockHash: block.hash,
        txIndex: index,
        branch: block.branchFor(index).$2,
        position: note1.position,
        path: path1,
        note: NoteOpening.of(note1.note));
    return (proof, chain);
  }

  static int _index(FakeBlock b, String txid) {
    final want = hex.decode(txid);
    for (int i = 0; i < b.txids.length; i++) {
      if (hex.encode(b.txids[i]) == hex.encode(want)) return i;
    }
    throw StateError('$txid is not in block ${b.height}');
  }
}
