import 'package:libcloak/libcloak.dart';

import 'world.dart';

/// Where a wallet passphrase comes from: a terminal prompt with echo off, or
/// a named environment variable for a script that has no terminal.
///
/// Never an argument. Every process on the machine can read another's
/// arguments, and a shell writes them to its history, so a passphrase typed on
/// the command line has been handed to whoever looks. The shell refuses such
/// an argument before a command runs; see [argumentRefusal].
class Passphrase {
  /// The variable a script puts the passphrase in.
  static const envName = 'CLOAK_PASSPHRASE';

  /// The options a person might reach for, all refused.
  static const _asArguments = ['--passphrase', '--password', '--pass', '-p'];

  /// Why [args] cannot be run, when one of them tries to carry a passphrase.
  static String? argumentRefusal(List<String> args) {
    for (final a in args) {
      final name = a.split('=').first;
      if (_asArguments.contains(name)) {
        return 'a passphrase is never given as an argument ($name): every process on this machine can read '
            'another\'s arguments and the shell keeps them in its history. Type it at the prompt, or put it in '
            '$envName for a script';
      }
    }
    return null;
  }

  /// The passphrase, from [envName] or a prompt. [confirm] asks twice, for a
  /// new wallet, so a typo does not become the passphrase.
  static Future<String> obtain(World world, {bool confirm = false}) async {
    final fromEnv = world.env[envName];
    if (fromEnv != null) {
      if (fromEnv.isEmpty) throw Refusal('passphrase', '$envName is set and empty; a wallet passphrase is not empty');
      return fromEnv;
    }
    final read = world.readSecret;
    if (read == null) {
      throw Refusal('passphrase', 'no terminal is attached to prompt on, and $envName is not set');
    }
    final first = await read('wallet passphrase: ');
    if (first == null || first.isEmpty) {
      throw const Refusal('passphrase', 'no passphrase was typed; a wallet passphrase is not empty');
    }
    if (confirm) {
      final again = await read('the same passphrase again: ');
      if (again != first) throw const Refusal('passphrase', 'the two passphrases typed differ');
    }
    return first;
  }
}
