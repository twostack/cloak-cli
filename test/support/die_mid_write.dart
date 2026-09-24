import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';

/// Writes the wallet state in the directory given with one more issued
/// invoice, and kills itself after the temporary file is whole and before it
/// is renamed: the wreckage "interrupted in the middle of a write" is about.
Future<void> main(List<String> args) async {
  final dir = WalletDir(args.single, DirSource.argument);
  final state = await CloakState.open(dir);
  state.issued.add(List.filled(40, 7));
  await state.save(dir, beforeRename: () async {
    Process.killPid(pid, ProcessSignal.sigkill);
    await Future<void>.delayed(const Duration(seconds: 10));
  });
}
