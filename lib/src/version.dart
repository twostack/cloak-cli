import 'package:libcloak/libcloak.dart';

import 'build_facts.dart';
import 'wallet/state_file.dart';

/// What this build is, and which state formats it reads and writes.
///
/// Every state file a wallet keeps carries a version, and a file written by a
/// newer build is refused naming both numbers rather than read on a guess. So
/// `cloak status` prints this table: a person who copied a wallet between two
/// machines can see at once which build is the older one.
class CloakVersion {
  /// The program's own version, as the manifest states it.
  static const program = '0.1.4';

  /// The `cloak-cli` commit this binary was built from, which only a release
  /// build knows; any other build says it is a development build rather than
  /// name a commit it cannot vouch for.
  static const commit = BuildFacts.commit;

  /// The version of each sibling library a release was built against.
  static const libraries = BuildFacts.libraries;

  /// Whether the build facts were given, which only the release build does.
  static bool get released => commit.isNotEmpty;

  /// `cloak --version`, as a line.
  static String get line => released ? 'cloak $program ($commit)' : 'cloak $program development build';

  /// `cloak --version --json`, as an object.
  static Map<String, Object?> get facts => released
      ? {'version': program, 'commit': commit, 'libraries': libraries}
      : {'version': program, 'build': 'development'};

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
