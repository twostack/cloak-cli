import 'dart:math';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart' show BEEF;

/// A transparent side in memory: coins of its own, real transactions built
/// over them, coins held per transaction the way libspiffy holds a deferred
/// payment's inputs, and every broadcast recorded.
class FakeTransparentSide implements TransparentSide {
  final Random _r;

  /// Coins not yet spent or held, as (funding txid, satoshis).
  final List<(String, int)> coins;

  /// Coins held for a transaction built and not yet broadcast or released.
  final Map<String, (String, int)> held = {};

  final List<String> broadcasts = [];
  final List<String> issued = [];
  final Set<String> minedTxids = {};
  final List<String> calls = [];

  /// When set, the next broadcast fails with it.
  String? failBroadcast;

  /// When set, [payTo] adds an output of this many bytes, to make an
  /// over-long transaction.
  int padding = 0;

  /// What [receive] says: parked, or refused with this reason.
  bool parkReceives = false;
  String? refuseReceives;

  FakeTransparentSide({int seed = 1, List<(String, int)>? coins})
      : _r = Random(seed),
        coins = coins ?? [('aa' * 32, 100000), ('bb' * 32, 100000), ('cc' * 32, 100000)];

  @override
  Future<ReceiveOutcome> receive(List<int> beef) async {
    calls.add('receive');
    final b = BEEF.parse(Uint8List.fromList(beef));
    final tx = Transaction.fromHex(hex.encode(b.txs.last));
    if (refuseReceives != null) throw Refusal('BEEF', refuseReceives!);
    return ReceiveOutcome(tx.id, 1234, waitingFor: parkReceives ? -1 : null);
  }

  @override
  Future<int> spendable() async => coins.fold<int>(0, (a, c) => a + c.$2);

  @override
  Future<String> freshAddress() async {
    calls.add('freshAddress');
    final a = SVPrivateKey(networkType: NetworkType.TEST).toAddress(networkType: NetworkType.TEST).toBase58();
    issued.add(a);
    return a;
  }

  @override
  Future<(BuiltTransparent?, Refusal?)> payTo(List<int> lockingScript, int satoshis) async {
    calls.add('payTo');
    final i = coins.indexWhere((c) => c.$2 >= satoshis + 500);
    if (i < 0) return (null, Refusal('funding', 'no coin covers $satoshis'));
    final coin = coins.removeAt(i);
    final change = SVPrivateKey(networkType: NetworkType.TEST).toAddress(networkType: NetworkType.TEST);
    final tx = Transaction()
      ..addInput(TransactionInput(coin.$1, 0, TransactionInput.MAX_SEQ_NUMBER))
      ..addOutput(TransactionOutput(BigInt.from(coin.$2 - satoshis - 500), P2PKHLockBuilder.fromAddress(change).getScriptPubkey()))
      ..addOutput(TransactionOutput(BigInt.from(satoshis), SVScript.fromByteArray(Uint8List.fromList(lockingScript))));
    if (padding > 0) {
      tx.addOutput(TransactionOutput(BigInt.zero,
          SVScript.fromByteArray(Uint8List.fromList([0x00, 0x6a, 0x4d, padding & 0xff, padding >> 8, ...List.filled(padding, 1)]))));
    }
    held[tx.id] = coin;
    return (BuiltTransparent(tx.id, tx.serialize()), null);
  }

  @override
  Future<void> release(String txid) async {
    calls.add('release');
    final c = held.remove(txid);
    if (c != null) coins.add(c);
  }

  @override
  Future<Refusal?> broadcast(String txHex, {bool fundedHere = true}) async {
    calls.add('broadcast');
    final f = failBroadcast;
    if (f != null) {
      failBroadcast = null;
      return Refusal('broadcast', f);
    }
    broadcasts.add(txHex);
    return null;
  }

  @override
  Future<bool> mined(String txid) async {
    calls.add('mined $txid');
    return minedTxids.contains(txid);
  }

  /// The input outpoint [txHex] spends first, as `txid:vout`.
  static String fundingOf(String txHex) {
    final tx = Transaction.fromHex(txHex);
    return '${tx.inputs.first.prevTxnId}:${tx.inputs.first.prevTxnOutputIndex}';
  }

  int nextInt(int max) => _r.nextInt(max);
}
