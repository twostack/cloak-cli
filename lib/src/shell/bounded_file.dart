import 'dart:io';

import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart' show PoolMessage;

/// The kinds of message a person hands this program as a file, and the most
/// bytes each may be.
///
/// Each bound is the one the message's own decoder declares, so a file is
/// refused here exactly when the decoder would refuse it, and before it has
/// cost a byte of memory.
enum MessageKind {
  invoice('invoice', Invoice.maxInvoice),
  paymentProof('payment proof', PaymentProof.maxProof),
  acknowledgement('acknowledgement', Acknowledgement.encodedSize),

  /// A BEEF payment, as hex, the way wallets and explorers hand one over: at
  /// most one transaction the chain would carry (the pool protocol's own
  /// per-transaction bound), two characters a byte, with room for the line
  /// breaks a pasted file picks up.
  beef('BEEF payment', 2 * PoolMessage.maxTx + 64 * 1024);

  final String name;
  final int max;
  const MessageKind(this.name, this.max);
}

/// Reads a file of bytes somebody else wrote, refusing it by its size first.
///
/// The size comes from the file system, not from the file, so an oversized
/// file is refused without being opened for reading: no buffer of its size is
/// ever allocated, which is the whole point when the size is a stranger's
/// choice.
class BoundedFile {
  static Future<List<int>> read(String path, MessageKind kind) async {
    final f = File(path);
    final int length;
    try {
      length = await f.length();
    } on FileSystemException catch (e) {
      throw Refusal('file', 'could not read the ${kind.name} at $path: ${e.osError?.message ?? e.message}');
    }
    if (length > kind.max) {
      throw Refusal('size', 'a ${kind.name} is at most ${kind.max} bytes and $path is $length bytes');
    }
    try {
      return await f.readAsBytes();
    } on FileSystemException catch (e) {
      throw Refusal('file', 'could not read the ${kind.name} at $path: ${e.osError?.message ?? e.message}');
    }
  }
}
