import 'dart:io';

import 'package:yaml/yaml.dart';

/// Writes the release's facts into `lib/src/build_facts.dart`: that this is a
/// released build, the `cloak-cli` commit, and the version of each sibling
/// library as `pubspec.lock` pins it. `cloak --version` prints them, and the
/// release flag decides where the native libraries come from.
///
///     dart run tool/release/facts.dart [--dirty]
///
/// `dart build cli` takes no `--define`, which is why a file is written;
/// `tool/release/compile.sh` writes it, builds, and puts the committed file
/// back. It refuses a working tree with changes, since the commit would then
/// not be what was built, unless `--dirty` is given, for a trial build, which
/// then names the commit with `-dirty` after it. It refuses a sibling the lock
/// does not pin.
void main(List<String> args) {
  final status = Process.runSync('git', ['status', '--porcelain', '--untracked-files=no']);
  final dirty = status.exitCode != 0 || (status.stdout as String).trim().isNotEmpty;
  if (dirty && !args.contains('--dirty')) {
    stderr.writeln('facts: the working tree has changes, so no commit names what would be built:\n${status.stdout}');
    exit(1);
  }
  final head = (Process.runSync('git', ['rev-parse', 'HEAD']).stdout as String).trim();
  final commit = dirty ? '$head-dirty' : head;
  final packages = (loadYaml(File('pubspec.lock').readAsStringSync()) as YamlMap)['packages'] as YamlMap;
  final versions = <String, String>{};
  for (final name in ['libcloak', 'libspiffy', 'tstokenlib', 'ricochet']) {
    final entry = packages[name] as YamlMap?;
    if (entry == null) {
      stderr.writeln('facts: pubspec.lock does not pin $name');
      exit(1);
    }
    versions[name] = '${entry['version']}';
  }
  File('lib/src/build_facts.dart').writeAsStringSync('''
// Written by tool/release/facts.dart for a release build; the committed file
// describes a development build and is put back after the build.
class BuildFacts {
  static const release = true;
  static const commit = '$commit';
  static const libraries = <String, String>{
${versions.entries.map((e) => "    '${e.key}': '${e.value}',").join('\n')}
  };
}
''');
  stdout.writeln('facts: release build of $commit');
}
