import 'dart:typed_data';

import 'package:libspiffy/libspiffy.dart';
import 'package:spiffynode/spiffy_node.dart';

/// Regtest headers mined for the suite: real proof of work at regtest's
/// limit, linked to regtest's genesis, ten minutes apart, so libspiffy's
/// chain validates every one of them the way it validates a peer's.
class RegtestHeaders {
  static final params = NetworkParams.forNetwork('regtest');
  static const bits = 0x207fffff;

  /// [count] headers after [from] (regtest's genesis by default), each
  /// committing to [salt] so two runs with different salts are two branches.
  static List<BlockHeader> mine(int count, {BlockHeader? from, int salt = 0}) {
    var prev = from ?? params.genesisHeader;
    final out = <BlockHeader>[];
    final target = _target(bits);
    for (int i = 0; i < count; i++) {
      final time = prev.timestamp.add(const Duration(minutes: 10));
      for (int nonce = 0;; nonce++) {
        final h = BlockHeader(
            version: 1,
            prevBlock: prev.blockHash(),
            merkleRoot: Hash.fromBytes(Uint8List(32)..[0] = salt & 0xff..[1] = (salt >> 8) & 0xff..[2] = i & 0xff..[3] = i >> 8),
            timestamp: time,
            bits: bits,
            nonce: nonce);
        if (BigInt.parse(h.blockHash().toString(), radix: 16) <= target) {
          out.add(h);
          prev = h;
          break;
        }
      }
    }
    return out;
  }

  static BigInt _target(int compact) {
    final exponent = compact >> 24;
    final mantissa = BigInt.from(compact & 0x007fffff);
    return mantissa << (8 * (exponent - 3));
  }
}
