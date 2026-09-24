import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libcloak/libcloak.dart';

import '../wallet/wallet_dir.dart';

/// The wallet's identity on the transport: 32 random bytes, kept in the
/// wallet directory.
///
/// Derived from nothing else the wallet holds, and nothing is derived from
/// it. An identity computed from the seed would mean anybody who learned the
/// identity (every server the wallet talks to learns it) held a value one hash
/// away from the seed, and a seed computed from the identity is worse. Losing
/// this file costs a person nothing but replies already sent to it: a new one
/// is made, and the pool never knew the old one belonged to any wallet.
class TransportIdentity {
  static const length = 32;

  /// Writes a fresh identity to [dir], owner-only before a byte is written.
  static Future<void> create(WalletDir dir, {Random? rng}) async {
    final r = rng ?? Random.secure();
    final f = File(dir.identity);
    if (await f.exists()) {
      throw Refusal('identity', 'there is already a transport identity at ${dir.identity}');
    }
    await f.writeAsBytes(const [], flush: true);
    await WalletDir.ownerOnly(f.path);
    await f.writeAsBytes(List.generate(length, (_) => r.nextInt(256)), flush: true);
  }

  /// The identity in [dir]. A missing one is made on the spot, because it is
  /// worth nothing but the replies already sent to it.
  static Future<Uint8List> read(WalletDir dir) async {
    final f = File(dir.identity);
    if (!await f.exists()) await create(dir);
    final length = await f.length();
    if (length != TransportIdentity.length) {
      throw Refusal('identity', '${dir.identity} is $length bytes and a transport identity is ${TransportIdentity.length}');
    }
    return Uint8List.fromList(await f.readAsBytes());
  }
}
