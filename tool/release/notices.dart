import 'dart:convert';
import 'dart:io';

/// Writes `THIRD_PARTY_NOTICES` for a bundle: the name, version and full
/// license text of every package compiled into `cloak`, and of the two native
/// libraries it ships beside it.
///
///     dart run tool/release/notices.dart <output file>
///
/// "Compiled in" is the closure of the program's own dependencies, never its
/// dev dependencies: the test runner and the coordinator are not in the
/// binary, and naming them would say the program carries code it does not. A
/// package whose license cannot be found fails the build, naming it, because a
/// bundle that ships code without its license is not one that can be published.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/release/notices.dart <output file>');
    exit(2);
  }
  final deps = await Process.run(Platform.resolvedExecutable, ['pub', 'deps', '--json']);
  if (deps.exitCode != 0) {
    stderr.writeln('notices: dart pub deps failed: ${deps.stderr}');
    exit(1);
  }
  final config = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map<String, dynamic>;
  try {
    final text = notices(
      compiledPackages(jsonDecode(deps.stdout as String) as Map<String, dynamic>),
      packageRoots(config, Directory.current.uri.resolve('.dart_tool/')),
    );
    File(args.single).writeAsStringSync(text);
  } on MissingLicense catch (e) {
    stderr.writeln('notices: $e');
    exit(1);
  }
}

/// The packages whose license could not be found, each with where it was
/// looked for. All of them, so one run says everything that is owed.
class MissingLicense implements Exception {
  final Map<String, String> missing;
  MissingLicense(this.missing);
  @override
  String toString() => 'no license file for ${missing.entries.map((e) => '${e.key} (in ${e.value})').join(', ')}; '
      'the build stops rather than ship code without its license';
}

/// A package compiled into the program, by name and version.
typedef Compiled = ({String name, String version});

/// The packages compiled into the program, from `dart pub deps --json`: the
/// root's direct dependencies and everything they depend on, sorted by name.
List<Compiled> compiledPackages(Map<String, dynamic> deps) {
  final packages = {
    for (final p in (deps['packages'] as List).cast<Map<String, dynamic>>()) p['name'] as String: p,
  };
  final root = packages[deps['root']]!;
  final seen = <String>{};
  final todo = [...(root['directDependencies'] as List).cast<String>()];
  while (todo.isNotEmpty) {
    final name = todo.removeLast();
    if (!seen.add(name)) continue;
    todo.addAll((packages[name]!['dependencies'] as List).cast<String>());
  }
  return [
    for (final name in seen.toList()..sort()) (name: name, version: packages[name]!['version'] as String),
  ];
}

/// Each package's directory, from a `package_config.json` read from
/// [configDir].
Map<String, String> packageRoots(Map<String, dynamic> config, Uri configDir) => {
      for (final p in (config['packages'] as List).cast<Map<String, dynamic>>())
        p['name'] as String: configDir.resolve(p['rootUri'] as String).toFilePath(),
    };

const _licenseNames = ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'LICENCE', 'COPYING'];

String? _license(String root) {
  for (final f in _licenseNames) {
    final file = File('$root/$f');
    if (file.existsSync()) return file.readAsStringSync().trimRight();
  }
  return null;
}

/// The notices text for [compiled], with each package's license read from its
/// directory in [roots], then the two native libraries: tstokenlib's kernels,
/// built from the crate inside the tstokenlib package and under its license,
/// and Isar's core, built from Isar's repository and under the isar package's.
String notices(List<Compiled> compiled, Map<String, String> roots) {
  final out = StringBuffer()
    ..writeln('THIRD-PARTY NOTICES')
    ..writeln()
    ..writeln('cloak is distributed with the following software. Each is listed with its')
    ..writeln('version and the full text of its license.')
    ..writeln();
  void entry(String title, String license) {
    out
      ..writeln('=' * 78)
      ..writeln(title)
      ..writeln('=' * 78)
      ..writeln()
      ..writeln(license)
      ..writeln();
  }

  final missing = <String, String>{};
  void licensed(String name, String? root, String title) {
    final text = root == null ? null : _license(root);
    if (text == null) {
      missing[name] = root ?? 'no directory in the package config';
    } else {
      entry(title, text);
    }
  }

  final versions = {for (final c in compiled) c.name: c.version};
  for (final c in compiled) {
    licensed(c.name, roots[c.name], '${c.name} ${c.version} (Dart package)');
  }
  for (final (lib, package) in [('libstark_kernels', 'tstokenlib'), ('libisar', 'isar')]) {
    licensed(lib, versions.containsKey(package) ? roots[package] : null,
        '$lib, from $package ${versions[package]} (native library)');
  }
  if (missing.isNotEmpty) throw MissingLicense(missing);
  return '$out';
}
