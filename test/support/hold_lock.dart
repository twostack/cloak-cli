import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';

/// Takes the wallet lock at the path given, says so, and holds it until it is
/// killed: the other process in "a second writer in another process".
Future<void> main(List<String> args) async {
  await WalletLock.take(args.single);
  stdout.writeln('held');
  await stdout.flush();
  await Future<void>.delayed(const Duration(minutes: 5));
}
