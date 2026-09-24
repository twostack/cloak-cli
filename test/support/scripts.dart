import 'dart:io';

/// Runs a helper script from test/support in a second process, the way a
/// test needs a second process: another writer, a death mid-write, a second
/// reader of the chain.
///
/// Not with `dart run`: that runs tstokenlib's build hook again, which writes
/// the kernels library in .dart_tool afresh while this process has it mapped
/// and is running code in it. macOS keeps the mapped copy; Linux does not,
/// and the test process dies of a segmentation fault (measured 2026-09-25, in
/// CI and in the dart:3.11.5 image). The SDK's bare VM runs the script with
/// the package config and no build step; none of the helpers needs the
/// kernels. An SDK without `dartvm` gets `dart run`.
List<String> _command(String script, List<String> args) {
  final vm = File('${File(Platform.resolvedExecutable).parent.path}/dartvm');
  if (vm.existsSync()) {
    return [vm.path, '--packages=${File('.dart_tool/package_config.json').absolute.path}', script, ...args];
  }
  return [Platform.resolvedExecutable, 'run', '--verbosity=error', script, ...args];
}

Future<ProcessResult> runScript(String script, List<String> args) {
  final c = _command(script, args);
  return Process.run(c.first, c.sublist(1));
}

Future<Process> startScript(String script, List<String> args) {
  final c = _command(script, args);
  return Process.start(c.first, c.sublist(1));
}
