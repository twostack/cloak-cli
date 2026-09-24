import 'dart:async';
import 'dart:io';

import 'package:libcloak/libcloak.dart';

/// The one writer a wallet has.
///
/// libcloak's note store stops a note being spent twice within one process,
/// by object identity: a payment is refused unless the store handed out that
/// exact note. Two processes defeat that entirely, because each reads the
/// store, each reserves a different copy of the same note, and each writes
/// back a file that has forgotten the other's reservation. The coordinator
/// would then refuse the second transfer at its nullifier, after the wallet
/// had paid for a spend proof and while it believed both notes were fine.
///
/// So a command that changes any state file takes this first, and a command
/// that only reads takes nothing. The lock is the operating system's, on a
/// file in the wallet directory, so it goes when the process goes however it
/// ends; the holder writes its process id into the file so the refusal can
/// name it.
class WalletLock {
  /// How long a second writer waits before it is refused. Long enough to ride
  /// out a command that is saving, short enough that nobody wonders whether
  /// the program has hung.
  static const defaultWait = Duration(seconds: 2);

  /// Paths locked by this process. POSIX record locks never conflict within
  /// one process, so two commands run in one process (which is what a suite
  /// does) are kept apart here instead.
  static final Set<String> _heldHere = {};

  final String path;
  final RandomAccessFile _file;
  bool _released = false;

  WalletLock._(this.path, this._file);

  /// Takes the lock at [path], or refuses naming the directory and the
  /// process holding it.
  static Future<WalletLock> take(String path, {Duration wait = defaultWait}) async {
    final deadline = DateTime.now().add(wait);
    while (true) {
      // claimed here before the first await, so two commands in one process
      // cannot both pass the check while the other is opening the file
      if (_heldHere.add(path)) {
        final raf = await File(path).open(mode: FileMode.append);
        try {
          await raf.lock(FileLock.exclusive);
          await raf.truncate(0);
          await raf.setPosition(0);
          await raf.writeString('$pid\n');
          await raf.flush();
          return WalletLock._(path, raf);
        } on FileSystemException {
          _heldHere.remove(path);
          await raf.close();
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        final holder = _holder(path);
        final dir = File(path).parent.path;
        throw Refusal('lock',
            'another cloak process is changing the wallet in $dir${holder == null ? '' : ' (process $holder)'}, '
            'and a wallet has one writer at a time; run this again when it has finished');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  static String? _holder(String path) {
    try {
      final s = File(path).readAsStringSync().trim();
      return s.isEmpty ? null : s;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    _heldHere.remove(path);
    try {
      await _file.unlock();
    } on FileSystemException {
      // the process is ending, and the operating system releases it then
    }
    await _file.close();
  }
}
