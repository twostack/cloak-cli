import 'package:args/args.dart';

import '../shell/call.dart';
import 'deposit_commands.dart';
import 'payment_commands.dart';
import 'reading_commands.dart';
import 'sync_command.dart';
import 'wallet_commands.dart';

/// One subcommand: its name, what it is for, its options, and what it runs.
class CommandSpec {
  final String name;
  final String summary;

  /// For a verb, the command it belongs to; `invoice` for `invoice new`.
  final String? parent;
  final void Function(ArgParser p) options;
  final Future<void> Function(Call call) run;

  /// Verbs under this command, for a command that has them.
  final Map<String, CommandSpec> verbs;

  const CommandSpec(this.name, this.summary, this.options, this.run, {this.parent, this.verbs = const {}});

  String get fullName => parent == null ? name : '$parent $name';
}

void _none(ArgParser p) {}

Future<void> _noVerb(Call call) async => throw UsageError('cloak ${call.name} needs a verb');

/// The seventeen subcommands, in the order a person meets them.
///
/// Each does one unit of a person's work and returns. None runs a daemon, a
/// watcher or a loop, because a wallet that is a process started and stopped
/// per command is a wallet with no state outside its directory.
class CommandTable {
  static final List<CommandSpec> all = [
    CommandSpec('init', 'make a new wallet, and print its seed once', initOptions, runInit),
    CommandSpec('unlock', 'check the passphrase opens the wallet, and say what it holds', _none, runUnlock),
    CommandSpec('address', 'issue a fresh address of this wallet\'s', addressOptions, runAddress),
    CommandSpec('status', 'the wallet directory, its files, the formats this build reads, and what is pending',
        _none, runStatus),
    CommandSpec('sync', 'bring the pool view up to the pool\'s tip, and check it', syncOptions, runSync),
    CommandSpec('invoice', 'issue an invoice, or read one you were handed', _none, _noVerb, verbs: {
      'new': CommandSpec('new', 'issue an invoice for an amount, to a fresh address', invoiceNewOptions, runInvoiceNew,
          parent: 'invoice'),
      'show': CommandSpec('show', 'read and check an invoice file somebody handed you', _none, runInvoiceShow,
          parent: 'invoice'),
    }),
    CommandSpec('pay', 'pay an invoice out of a note this wallet holds', _none, runPay),
    CommandSpec('proof', 'make the payment proof for an invoice this wallet paid', proofOptions, runProof),
    CommandSpec('check', 'check a payment proof against this wallet\'s own headers, and take the note', _none,
        runCheck),
    CommandSpec('ack', 'acknowledge a payment you checked, or check an acknowledgement you were sent', ackOptions,
        runAck),
    CommandSpec('balance', 'spendable, reserved and stale, per asset', _none, runBalance),
    CommandSpec('notes', 'every note this wallet holds, and its state', _none, runNotes),
    CommandSpec('journal', 'the record of what this wallet issued, paid, proved and acknowledged', journalOptions,
        runJournal),
    CommandSpec('receive', 'take a BEEF payment another person handed you', _none, runReceive),
    CommandSpec('deposit', 'put BSV into the pool behind its deposit covenant', depositOptions, runDeposit),
    CommandSpec('refund', 'take back a deposit no round took in, at its refund height', refundOptions, runRefund),
    CommandSpec('withdraw', 'take BSV out of the pool to a transparent address', withdrawOptions, runWithdraw),
  ];

  static final Map<String, CommandSpec> byName = {for (final c in all) c.name: c};

  static List<String> get names => [for (final c in all) c.name];

  static ArgParser parser() {
    final p = ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false, help: 'this text')
      ..addFlag('version', negatable: false, help: 'the program\'s version')
      ..addOption('wallet', valueHelp: 'dir', help: 'the wallet directory (else \$CLOAK_WALLET, else ~/.cloak)')
      ..addFlag('json', negatable: false, help: 'print the result as one JSON object')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'log what the libraries below are doing, to stderr');
    for (final c in all) {
      final sub = p.addCommand(c.name)..addFlag('help', abbr: 'h', negatable: false, help: 'this command\'s options');
      c.options(sub);
      for (final v in c.verbs.values) {
        final verb = sub.addCommand(v.name)..addFlag('help', abbr: 'h', negatable: false, help: 'this verb\'s options');
        v.options(verb);
      }
    }
    return p;
  }

  static String usage(ArgParser p) {
    final b = StringBuffer()
      ..writeln('cloak: a wallet for the TSL1_SP shielded pool')
      ..writeln()
      ..writeln('usage: cloak [--wallet dir] [--json] [-v] <command> [options]')
      ..writeln()
      ..writeln('commands:');
    for (final c in all) {
      if (c.verbs.isEmpty) {
        b.writeln('  ${c.name.padRight(14)} ${c.summary}');
      } else {
        for (final v in c.verbs.values) {
          b.writeln('  ${v.fullName.padRight(14)} ${v.summary}');
        }
      }
    }
    b
      ..writeln()
      ..writeln('options:')
      ..writeln(p.usage)
      ..writeln()
      ..writeln('A passphrase is typed at a prompt, or read from \$CLOAK_PASSPHRASE; never an argument.');
    return b.toString();
  }

  static String commandUsage(CommandSpec c, ArgParser top) {
    final ArgParser p = c.parent == null ? top.commands[c.name]! : top.commands[c.parent]!.commands[c.name]!;
    return 'cloak ${c.fullName}: ${c.summary}\n\n${p.usage}\n';
  }
}
