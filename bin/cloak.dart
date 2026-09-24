import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';

/// The `cloak` binary: the process's own world, handed to [runCloak].
///
/// Everything here is about the process and nothing is about the wallet: the
/// two streams, the environment, a prompt with echo off, and the ports that
/// start the chain and open the transport on first use.
Future<void> main(List<String> args) async {
  final terminal = stdin.hasTerminal;
  final world = World(
    out: stdout,
    err: stderr,
    env: Platform.environment,
    ports: ProcessPorts(progress: stderr, env: Platform.environment),
    readSecret: terminal ? _readSecret : null,
    readLine: terminal ? _readLine : null,
  );
  final code = await runCloak(args, world);
  await stdout.flush();
  await stderr.flush();
  exit(code);
}

Future<String?> _readSecret(String prompt) async {
  stderr.write(prompt);
  final echo = stdin.echoMode;
  stdin.echoMode = false;
  try {
    return stdin.readLineSync();
  } finally {
    stdin.echoMode = echo;
    stderr.writeln();
  }
}

Future<String?> _readLine(String prompt) async {
  stderr.write(prompt);
  return stdin.readLineSync();
}
