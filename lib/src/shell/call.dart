import 'package:args/args.dart';

import '../wallet/config.dart';
import '../wallet/session.dart';
import '../wallet/wallet_dir.dart';
import 'report.dart';
import 'world.dart';

/// A command that was not well formed. Exit code 2.
///
/// Kept apart from a refusal on purpose: "you typed it wrong" and "a rule said
/// no" call for different things from a person, and a script needs to tell
/// them apart without reading prose.
class UsageError implements Exception {
  final String message;
  const UsageError(this.message);
  @override
  String toString() => message;
}

/// One command being run: its arguments, the world it may reach, the wallet
/// directory it resolved, and the report it fills in.
class Call {
  final String name;
  final World world;
  final ArgResults args;
  final WalletDir dir;
  final bool json;
  final bool verbose;
  final Report report = Report();

  /// Set by a command whose standard output is reserved for one value, which
  /// is `init` and its seed: the report then goes to standard error, so the
  /// seed can be redirected to a file with nothing beside it.
  bool reportToErr = false;

  /// Whatever a command opened that must be closed when it returns.
  final List<Future<void> Function()> _closers = [];

  Call({
    required this.name,
    required this.world,
    required this.args,
    required this.dir,
    required this.json,
    required this.verbose,
  });

  /// Opens the wallet for reading or, with [write], for changing it under the
  /// wallet lock. [keys] asks for the passphrase and decrypts the seed; a
  /// command that needs no key never asks. Keys are derived with ML-KEM, so a
  /// command opening them first checks the kernels library, before it asks
  /// for the passphrase or takes the lock.
  Future<Session> open({bool write = false, bool keys = false}) async {
    if (keys) world.native.checkKernels();
    final s = await Session.open(this, write: write, keys: keys);
    _closers.add(s.close);
    return s;
  }

  /// The config, for a command that needs it before or without a session.
  Future<CloakConfig> config() => CloakConfig.load(dir.config);

  /// The positional argument at [i], or a usage error naming [what].
  String positional(int i, String what) {
    if (args.rest.length <= i) throw UsageError('cloak $name needs $what');
    return args.rest[i];
  }

  String? option(String name) => args[name] as String?;

  bool flag(String name) => args[name] as bool;

  /// A whole number from option [option], or a usage error.
  int? intOption(String option, {int min = 0}) {
    final v = args[option] as String?;
    if (v == null) return null;
    final n = int.tryParse(v);
    if (n == null || n < min) throw UsageError('--$option is a whole number of at least $min, not "$v"');
    return n;
  }

  Future<void> closeAll() async {
    for (final c in _closers.reversed) {
      await c();
    }
    _closers.clear();
  }
}
