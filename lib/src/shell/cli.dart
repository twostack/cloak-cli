import 'dart:async';
import 'dart:convert';

import 'package:args/args.dart';
import 'package:libcloak/libcloak.dart';
import 'package:logging/logging.dart';

import '../commands/table.dart';
import '../native/native_libraries.dart';
import '../version.dart';
import '../wallet/wallet_dir.dart';
import 'call.dart';
import 'passphrase.dart';
import 'world.dart';

/// Exit codes, and the only three a handled path returns.
///
/// Done, refused and malformed are three different things for a script to act
/// on: retrying a refusal is pointless until something changes, and retrying a
/// malformed command is pointless until the command changes.
class Exit {
  static const done = 0;
  static const refused = 1;
  static const usage = 2;
}

/// Runs one `cloak` command line against [world] and returns its exit code.
///
/// This is the whole program: `bin/cloak.dart` builds a [World] from the
/// process and calls this, and the suite calls it with doubles. Nothing is
/// started before the command is known and needs it, so `cloak --help` and an
/// unknown command cost an argument parse and nothing else.
Future<int> runCloak(List<String> args, World world) async {
  final passphraseArg = Passphrase.argumentRefusal(args);
  if (passphraseArg != null) {
    world.err.writeln('cloak: $passphraseArg');
    return Exit.usage;
  }

  final parser = CommandTable.parser();
  final ArgResults top;
  try {
    top = parser.parse(args);
  } on FormatException catch (e) {
    world.err
      ..writeln('cloak: ${e.message}')
      ..writeln('run cloak --help for the commands and their options');
    return Exit.usage;
  }

  if (top['version'] as bool) {
    world.out.writeln(top['json'] as bool ? jsonEncode(CloakVersion.facts) : CloakVersion.line);
    return Exit.done;
  }
  final command = top.command;
  if (command == null) {
    if (top.rest.isNotEmpty) {
      world.err
        ..writeln('cloak: ${top.rest.first} is not a command')
        ..writeln('the commands are: ${CommandTable.names.join(', ')}');
      return Exit.usage;
    }
    world.out.write(CommandTable.usage(parser));
    return Exit.done;
  }

  // `invoice new` and `invoice show` are one entry with two verbs
  var spec = CommandTable.byName[command.name]!;
  var results = command;
  if (spec.verbs.isNotEmpty) {
    final verb = command.command;
    if (verb == null && command['help'] as bool) {
      world.out.writeln('cloak ${spec.name}: ${spec.summary}\n');
      for (final v in spec.verbs.values) {
        world.out.writeln('  ${v.fullName.padRight(14)} ${v.summary}');
      }
      world.out.writeln('\ncloak ${spec.name} <verb> --help for a verb\'s options');
      return Exit.done;
    }
    if (verb == null) {
      final what = command.rest.isEmpty ? 'none' : '"${command.rest.first}", which is not one of its verbs';
      world.err.writeln('cloak ${spec.name}: needs one of ${spec.verbs.keys.join(', ')}, and was given $what');
      return Exit.usage;
    }
    spec = spec.verbs[verb.name]!;
    results = verb;
  }
  if (results['help'] as bool) {
    world.out.write(CommandTable.commandUsage(spec, parser));
    return Exit.done;
  }

  final verbose = top['verbose'] as bool;
  StreamSubscription<LogRecord>? logs;
  if (verbose) {
    Logger.root.level = Level.ALL;
    logs = Logger.root.onRecord.listen((r) => world.err.writeln('[${r.level.name} ${r.loggerName}] ${r.message}'));
  }

  final WalletDir dir;
  try {
    dir = WalletDir.resolve(argument: top['wallet'] as String?, env: world.env);
  } on Refusal catch (r) {
    world.err.writeln('cloak: ${r.step}: ${r.reason}');
    await logs?.cancel();
    return Exit.refused;
  }

  // the libraries below print as they go (libspiffy names its network on
  // stdout); stdout is this program's answer, and `--json` promises one
  // object on it, so what they print is a log line under -v and nothing
  // otherwise
  Future<void> below(Future<void> Function() f) => runZoned(f,
      zoneSpecification: ZoneSpecification(print: (_, __, ___, line) {
        if (verbose) world.err.writeln('[print] $line');
      }));

  final call = Call(
      name: spec.fullName, world: world, args: results, dir: dir, json: top['json'] as bool, verbose: verbose);
  try {
    await below(() => spec.run(call));
    final sink = call.reportToErr ? world.err : world.out;
    if (call.json) {
      sink.writeln(call.report.toJson());
    } else {
      sink.write(call.report.toText());
    }
    return Exit.done;
  } on UsageError catch (u) {
    world.err.writeln('cloak ${spec.fullName}: ${u.message}');
    return Exit.usage;
  } on Refusal catch (r) {
    // what completed before the refusal is still said, on its usual stream,
    // so a command that changed durable state and then stopped says how far
    // it got
    if (call.report.lines.isNotEmpty) {
      final sink = call.reportToErr ? world.err : world.out;
      sink.write(call.json ? '${call.report.toJson()}\n' : call.report.toText());
    }
    printRefusal(world, spec.fullName, r);
    return Exit.refused;
  } on HeaderSourceFailure catch (f) {
    printRefusal(world, spec.fullName, Refusal('header source', 'the chain could not answer ${f.call}: ${f.reason}'));
    return Exit.refused;
  } on TransportFailure catch (f) {
    printRefusal(world, spec.fullName, Refusal('transport', 'the pool could not be reached on ${f.call}: ${f.reason}'));
    return Exit.refused;
  } catch (e) {
    if (e is StateError && e.message.contains('native crate')) {
      // tstokenlib found no kernels, and says so with the build instruction
      // for its own developers; a person gets the refusal the check before a
      // key command gives, which only a path around that check reaches here
      printRefusal(world, spec.fullName, _noKernels(world));
      return Exit.refused;
    }
    // a library that threw rather than refusing is a defect below this one;
    // it is still a sentence and an exit code, never a stack trace
    printRefusal(world, spec.fullName, Refusal('unexpected', 'stopped by ${e.runtimeType}: $e'));
    return Exit.refused;
  } finally {
    await below(call.closeAll);
    try {
      await below(world.ports.close);
    } catch (e) {
      world.err.writeln('cloak: warning: stopping the chain or the transport: $e');
    }
    await logs?.cancel();
  }
}

Refusal _noKernels(World world) {
  final path = world.native.kernelsPath;
  return Refusal(
      NativeLibraries.step,
      path == null
          ? 'the kernels library ${NativeLibraries.kernelsName} was found nowhere; set '
              '${NativeLibraries.kernelsVariable} to its path'
          : 'the kernels library ${NativeLibraries.kernelsName} could not be loaded from $path; this installation '
              'is incomplete; reinstall cloak');
}

/// A refusal, as a person reads it: the command, the step that refused, and
/// the library's own sentence, unchanged.
///
/// The step and the sentence are the library's, and this program adds no word
/// of its own to either: "invalid" tells a person nothing, and the step name
/// tells them which rule to go and read.
void printRefusal(World world, String command, Refusal r) {
  world.err.writeln('cloak $command: refused at "${r.step}": ${r.reason}');
}
