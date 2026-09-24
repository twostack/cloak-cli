// Copied from ../libcloak/test/fakes.dart, where these doubles of the two
// ports were written and are tested; a wallet host tests against the same
// doubles its library does.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:libcloak/libcloak.dart';

/// In-memory stand-ins for the two ports, and the block arithmetic the header
/// fake needs.
///
/// Both record every call, because half of what the suite has to show is not
/// that a check passes but that nothing the wallet holds was ever mentioned on
/// the way.

List<int> _dsha(List<int> b) => crypto.sha256.convert(crypto.sha256.convert(b).bytes).bytes;

/// A block of transactions, as a fake chain holds one: the txids in order, in
/// the display order a node prints them.
class FakeBlock {
  final int height;

  /// Display-order txids, in block order.
  final List<List<int>> txids;

  /// The previous block's hash, display order.
  final List<int> previous;

  /// The header's time and bits, so the 80 bytes are a real header shape.
  final int time, bits, nonce;

  FakeBlock(this.height, this.txids, this.previous, {this.time = 1700000000, this.bits = 0x207fffff, this.nonce = 0});

  /// The block's merkle root, display order, by the chain's own rule: pairs
  /// hashed in internal order, an odd node duplicated.
  List<int> get merkleRoot {
    if (txids.isEmpty) return List.filled(32, 0);
    var level = [for (final t in txids) t.reversed.toList()];
    while (level.length > 1) {
      level = [
        for (int i = 0; i < level.length; i += 2) _dsha([...level[i], ...level[i + (i + 1 < level.length ? 1 : 0)]])
      ];
    }
    return level[0].reversed.toList();
  }

  /// The 80-byte header.
  List<int> get header {
    final out = BytesBuilder(copy: false)
      ..add(_u32(1))
      ..add(previous.reversed.toList())
      ..add(merkleRoot.reversed.toList())
      ..add(_u32(time))
      ..add(_u32(bits))
      ..add(_u32(nonce));
    return out.toBytes();
  }

  /// The block hash, display order.
  List<int> get hash => _dsha(header).reversed.toList();

  /// The merkle branch of the transaction at [index], display order, with the
  /// index the branch is walked with.
  (int, List<List<int>>) branchFor(int index) {
    var level = [for (final t in txids) t.reversed.toList()];
    var at = index;
    final branch = <List<int>>[];
    while (level.length > 1) {
      final sib = at ^ 1;
      branch.add((sib < level.length ? level[sib] : level[at]).reversed.toList());
      level = [
        for (int i = 0; i < level.length; i += 2) _dsha([...level[i], ...level[i + (i + 1 < level.length ? 1 : 0)]])
      ];
      at >>= 1;
    }
    return (index, branch);
  }

  static List<int> _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}

/// A header source over a list of blocks, recording every call.
///
/// It is a fake of the port, not of a node: it answers the three questions and
/// has no way to be asked a fourth. `fail` makes every call throw, for the
/// scenarios about a source that is unavailable.
class FakeHeaderSource implements HeaderSource {
  final List<FakeBlock> blocks;

  /// Every call made, as `'<method> <argument>'`, in order.
  final List<String> calls = [];

  /// When set, every call throws it.
  String? fail;

  FakeHeaderSource(this.blocks);

  /// A chain of [count] blocks, the first holding [txids] and the rest empty,
  /// so a fixture transaction has a block and a branch.
  factory FakeHeaderSource.holding(List<List<int>> txids, {int before = 1, int after = 1}) {
    final blocks = <FakeBlock>[];
    var previous = List<int>.filled(32, 0);
    for (int h = 0; h < before; h++) {
      final b = FakeBlock(h, [_dsha([h]).reversed.toList()], previous);
      blocks.add(b);
      previous = b.hash;
    }
    final held = FakeBlock(before, txids, previous);
    blocks.add(held);
    previous = held.hash;
    for (int h = 0; h < after; h++) {
      final b = FakeBlock(before + 1 + h, [_dsha([100 + h]).reversed.toList()], previous);
      blocks.add(b);
      previous = b.hash;
    }
    return FakeHeaderSource(blocks);
  }

  /// The block holding [txid], or null.
  FakeBlock? blockOf(List<int> txid) {
    for (final b in blocks) {
      if (b.txids.any((t) => _eq(t, txid))) return b;
    }
    return null;
  }

  void _check(String call) {
    calls.add(call);
    final f = fail;
    if (f != null) throw HeaderSourceFailure(call, f);
  }

  @override
  Future<ChainTip> tip() async {
    _check('tip');
    final last = blocks.last;
    return ChainTip(last.height, last.hash);
  }

  @override
  Future<int?> heightOfBlock(List<int> blockHash) async {
    _check('heightOfBlock ${_hex(blockHash)}');
    for (final b in blocks) {
      if (_eq(b.hash, blockHash)) return b.height;
    }
    return null;
  }

  @override
  Future<List<int>?> headerAtHeight(int height) async {
    _check('headerAtHeight $height');
    for (final b in blocks) {
      if (b.height == height) return b.header;
    }
    return null;
  }
}

/// A transport over a queue, recording every frame sent and read.
///
/// [answer] decides what a request is replied with; the default refuses, so a
/// test that forgot to set it fails loudly rather than silently passing.
class FakeTransport implements Transport {
  /// The feed, in order. Entry i is sequence i.
  final List<List<int>> feed;

  /// Every frame sent, in order.
  final List<List<int>> sent = [];

  /// Every feed read, as `'readFeed <from> <max>'`.
  final List<String> reads = [];

  /// What a request is answered with, or null to fail.
  FutureOr<List<int>> Function(List<int> frame)? answer;

  /// When set, every call throws it.
  String? fail;

  /// Requests that failed before this many attempts succeed, for the retry
  /// scenarios.
  int failFirst = 0;
  int attempts = 0;

  /// While set, a request is parked in [held] rather than answered, and the
  /// test completes them in whatever order it likes. That is what makes "two
  /// submissions in flight and their replies arrive out of order" a real
  /// test rather than two calls that happen to be awaited in sequence.
  bool hold = false;

  /// The parked requests, oldest first: the frame and the completer whose
  /// future the caller is waiting on.
  final List<(List<int>, Completer<List<int>>)> held = [];

  FakeTransport({List<List<int>>? feed}) : feed = feed ?? [];

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) async {
    attempts++;
    sent.add(List<int>.from(frame));
    final f = fail;
    if (f != null) throw TransportFailure('request', f);
    if (attempts <= failFirst) throw const TransportFailure('request', 'the pool did not answer');
    if (hold) {
      final waiting = Completer<List<int>>();
      held.add((List<int>.from(frame), waiting));
      return waiting.future;
    }
    final a = answer;
    if (a == null) throw const TransportFailure('request', 'this transport was given no answer');
    return await a(frame);
  }

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) async {
    reads.add('readFeed $from $max');
    final f = fail;
    if (f != null) throw TransportFailure('readFeed', f);
    if (from < 0) throw TransportFailure('readFeed', 'sequence $from is before the start');
    return [
      for (int i = from; i < feed.length && i - from < max; i++) FeedEntry(i, feed[i]),
    ];
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _hex(List<int> b) {
  const d = '0123456789abcdef';
  final s = StringBuffer();
  for (final x in b) {
    s.write(d[(x >> 4) & 15]);
    s.write(d[x & 15]);
  }
  return '$s';
}
