import 'dart:async';

import 'package:convert/convert.dart';

import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart';

/// A mined round as the pool answers a request for it by number: the round and
/// witness transactions whole, and the witness's place in its block.
class MinedRoundBytes {
  final int round;
  final List<int> roundTx, witnessTx, blockHash;
  final int txIndex;
  final List<List<int>> branch;

  const MinedRoundBytes(
      {required this.round,
      required this.roundTx,
      required this.witnessTx,
      required this.blockHash,
      required this.txIndex,
      required this.branch});

  /// Whether these are the transactions [notice] named. A notice carries the
  /// two txids and no transactions, so the round is asked for by number and
  /// has to be the one the notice announced; a pool that says two things
  /// about one round is believed in neither.
  bool isNamedBy(PoolRoundMined notice) {
    if (notice.round != round) return false;
    try {
      return ShieldedLedger.parse(roundTx).id == hex.encode(notice.roundTxId) &&
          ShieldedLedger.parse(witnessTx).id == hex.encode(notice.witnessTxId);
    } on LedgerRefusal {
      return false;
    }
  }
}

/// A mined round this wallet has checked: proved off its own headers, and
/// its leaves and nullifiers read out of its own transactions.
class ReadRound {
  final MinedRoundBytes bytes;
  final CheckedHead head;
  final RoundLeaves leaves;
  const ReadRound(this.bytes, this.head, this.leaves);

  int get round => head.round;

  /// Where the leaf with commitment [cm] (32 bytes) sits among this round's
  /// leaves, or null when the round does not hold it.
  int? offsetOf(List<int> cm) {
    final want = BlockFold.bytesToLanes(cm);
    for (int i = 0; i < leaves.leaves.length; i++) {
      if (_same(leaves.leaves[i], want)) return i;
    }
    return null;
  }
}

/// Getting a mined round, and making a leaf's path from it.
///
/// A round comes from asking the pool for it by number, from the same identity
/// the submission went from, so the asking says nothing the submission did
/// not. The notice the coordinator sends a submitter when its round is mined
/// names the round and its txids and carries no transactions, because a
/// production round is megabytes and every submitter would get one; it says
/// when to ask, and what the answer must be. The answer is not believed. The
/// witness is placed in a block this wallet's own headers vouch for and the
/// round is checked to be this pool's, as a head proof is; its leaves are read
/// out of its own transactions by tstokenlib, and must hash to the block root
/// the round was announced with.
class Rounds {
  /// Asks the pool for round [n] by number.
  ///
  /// libcloak's client does not ask this question yet, so the request is
  /// sent here, over the same opaque transport, and the answer is decoded
  /// here and matched by the id the request went out under.
  static Future<(MinedRoundBytes?, Refusal?)> fetch(Transport t, int n, {required Duration timeout}) async {
    final request = PoolCatchUpRequest.round(n);
    final List<int> bytes;
    try {
      bytes = await t.request(request.encode(), timeout: timeout).timeout(timeout * 2);
    } on TransportFailure catch (e) {
      return (null, Refusal('transport', 'round $n could not be asked for: ${e.reason}'));
    } on TimeoutException {
      return (null, Refusal('no answer', 'the pool did not answer a request for round $n'));
    }
    if (bytes.length > PoolMessage.maxCatchUp) {
      return (null, Refusal('size', 'an answer is at most ${PoolMessage.maxCatchUp} bytes and ${bytes.length} arrived'));
    }
    final PoolMessage msg;
    try {
      msg = PoolMessage.decode(bytes);
    } on ProtocolRefusal catch (e) {
      return (null, Refusal(e.field, e.reason));
    } catch (e) {
      return (null, Refusal('malformed', '$e'));
    }
    if (msg is! PoolCatchUpReply) {
      return (null, Refusal('catch-up', 'the pool answered a request for round $n with ${msg.kind.name}'));
    }
    if (!_same(msg.id, request.id)) {
      return (null, Refusal('id', 'the answer is to another request, not the one for round $n'));
    }
    if (msg.isRefused) return (null, Refusal(msg.refusal!.name, msg.sentence ?? 'the pool refused and gave no sentence'));
    if (msg.what != CatchUpKind.round || msg.round != n) {
      return (null, Refusal('catch-up', 'asked for round $n and answered with ${msg.what.name} for round ${msg.round}'));
    }
    return (
      MinedRoundBytes(
          round: n,
          roundTx: msg.roundTx!,
          witnessTx: msg.witnessTx!,
          blockHash: msg.blockHash!,
          txIndex: msg.txIndex,
          branch: msg.branch),
      null
    );
  }

  /// Checks [b] as this pool's round, off this wallet's own headers, and
  /// reads its leaves and nullifiers.
  static Future<(ReadRound?, Refusal?)> check(PoolDescriptor pool, PaymentChecker checker, MinedRoundBytes b) async {
    final MerkleProof membership;
    try {
      membership = MerkleProof.of(b.witnessTx, blockHash: b.blockHash, txIndex: b.txIndex, branch: b.branch);
    } on ArgumentError catch (e) {
      return (null, Refusal('round', '${e.message}'));
    }
    final (head, why) = await checker.head(roundTx: b.roundTx, witnessTx: b.witnessTx, membership: membership);
    if (head == null) return (null, why);
    if (head.round != b.round) {
      return (null, Refusal('round', 'delivered as round ${b.round}, and its header\'s own leaf count makes it round ${head.round}'));
    }
    final RoundLeaves leaves;
    try {
      final layout = ShieldedPoolLayout.forArities(pool.arities,
          nullifierLevel: pool.nullifierLevel, receiptSlots: pool.receiptSlots);
      leaves = ShieldedLedger.readLeaves(layout, ShieldedLedger.parse(b.roundTx), ShieldedLedger.parse(b.witnessTx));
    } on LedgerRefusal catch (e) {
      return (null, Refusal('round', e.reason));
    }
    return (ReadRound(b, head, leaves), null);
  }

  /// The full path of the leaf at [offset] in [round], at that round.
  ///
  /// Below the block level the siblings are the round's own leaves. Above it,
  /// where the block index has a bit set the sibling is a complete subtree to
  /// the left, which [checkpoint] (the pool's frontier at that very round)
  /// carries; where it has none the sibling is still empty. The checkpoint is
  /// the one `cloak sync` kept when its fold stood at that round.
  static (List<List<int>>?, Refusal?) pathAt(PoolShape shape, ReadRound round, Checkpoint checkpoint, int offset) {
    if (checkpoint.round != round.round) {
      return (null, Refusal('checkpoint', 'a path at round ${round.round} needs the frontier at that round, not ${checkpoint.round}\'s'));
    }
    if (!_same(checkpoint.blockRoot, round.leaves.blockRoot)) {
      return (null, Refusal('block root', 'round ${round.round}\'s leaves hash to another block root than the one this wallet folded'));
    }
    final block = NoteCommitmentTree.fromLeaves(round.leaves.leaves);
    final lower = block.path(offset).siblings.sublist(0, shape.blockLevel);
    final m = round.round - 1;
    var k = 0;
    final upper = <List<int>>[
      for (int l = 0; l < shape.upperLevels; l++)
        (m >> l) & 1 == 1 ? BlockFold.bytesToLanes(checkpoint.left[k++]) : MerkleFrontier.emptyRoots[shape.blockLevel + l]
    ];
    return ([for (final s in [...lower, ...upper]) List<int>.of(s)], null);
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
