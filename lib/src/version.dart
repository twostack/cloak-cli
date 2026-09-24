import 'package:libcloak/libcloak.dart';

import 'wallet/state_file.dart';

/// What this build is, and which state formats it reads and writes.
///
/// Every state file a wallet keeps carries a version, and a file written by a
/// newer build is refused naming both numbers rather than read on a guess. So
/// `cloak status` prints this table: a person who copied a wallet between two
/// machines can see at once which build is the older one.
class CloakVersion {
  /// The program's own version, as the manifest states it.
  static const program = '0.1.0';

  /// The format each state file is written in, by the name `cloak status`
  /// uses for it.
  static const formats = <String, int>{
    'wallet file': WalletFile.version,
    'note store': NoteStore.version,
    'pool view': PoolView.version,
    'journal entry': JournalEntry.version,
    'wallet state': CloakState.version,
  };
}
