import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/notices.dart';

/// `THIRD_PARTY_NOTICES`, as the release build writes it.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('cloak-notices'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A package directory named [name], holding [license] under that file
  /// name unless it is null.
  String package(String name, {String? license = 'LICENSE'}) {
    final dir = Directory(p.join(tmp.path, name))..createSync();
    if (license != null) File(p.join(dir.path, license)).writeAsStringSync('the license of $name\n');
    return dir.path;
  }

  final compiled = [
    (name: 'isar', version: '3.1.0+1'),
    (name: 'libcloak', version: '0.1.0'),
    (name: 'tstokenlib', version: '2.0.1'),
  ];

  test('Every package accounted for', () {
    final roots = {
      'isar': package('isar'),
      'libcloak': package('libcloak', license: 'LICENSE.md'),
      'tstokenlib': package('tstokenlib'),
    };
    final text = notices(compiled, roots);
    for (final c in compiled) {
      expect(text, contains('${c.name} ${c.version} (Dart package)'));
      expect(text, contains('the license of ${c.name}'));
    }
    expect(text, contains('libstark_kernels, from tstokenlib 2.0.1 (native library)'));
    expect(text, contains('libisar, from isar 3.1.0+1 (native library)'));
  });

  test('a package with no license fails the generation, naming it', () {
    final roots = {
      'isar': package('isar'),
      'libcloak': package('libcloak', license: null),
      'tstokenlib': package('tstokenlib'),
    };
    expect(
        () => notices(compiled, roots),
        throwsA(isA<MissingLicense>()
            .having((e) => e.missing.keys, 'missing', ['libcloak'])
            .having((e) => '$e', 'says', contains(roots['libcloak']))));
  });

  test('only what is compiled in: no dev dependency is named', () async {
    final deps = await Process.run(Platform.resolvedExecutable, ['pub', 'deps', '--json']);
    expect(deps.exitCode, 0, reason: '${deps.stderr}');
    final names = compiledPackages(jsonDecode(deps.stdout as String) as Map<String, dynamic>).map((c) => c.name);
    expect(names, containsAll(['libcloak', 'libspiffy', 'tstokenlib', 'ricochet', 'isar', 'dartsv']));
    // spiffynode is a dev dependency here and a runtime one of libspiffy's, so it
    // is compiled in, and named
    for (final dev in ['test', 'lints', 'pool_coordinator']) {
      expect(names, isNot(contains(dev)), reason: '$dev is a dev dependency');
    }
    expect(names, isNot(contains('cloak_cli')), reason: 'the program\'s own license is LICENSE');
  });
}
