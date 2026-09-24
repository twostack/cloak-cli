import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
// the path the hook's library was loaded from, which tstokenlib does not export
// ignore: implementation_imports
import 'package:tstokenlib/src/crypto/bundled_kernels.dart' show bundledKernelsPath;

import 'support/harness.dart';

/// The native libraries as a released build finds them: a bundle made in a
/// temporary directory, its program a file named `bin/cloak`, and whatever a
/// test puts in its `lib/`.
///
/// The program itself is never run here; the suite is a development build, and
/// a released build differs only in where [NativeLibraries] looks, which is
/// what these tests hand it. The bundle run for real is the smoke test's.
class Bundle {
  final Directory root;
  Bundle._(this.root);

  static Bundle make() {
    final root = Directory.systemTemp.createTempSync('cloak-bundle');
    File(p.join(root.path, 'bin', 'cloak')).createSync(recursive: true);
    Directory(p.join(root.path, 'lib')).createSync();
    return Bundle._(Directory(root.resolveSymbolicLinksSync()));
  }

  String get program => p.join(root.path, 'bin', 'cloak');
  String get lib => p.join(root.path, 'lib');
  String get kernels => p.join(lib, NativeLibraries.kernelsName);
  String get isar => p.join(lib, NativeLibraries.isarName);

  NativeLibraries native([Map<String, String> env = const {}]) =>
      NativeLibraries(executable: program, release: true, env: env);

  void dispose() => root.deleteSync(recursive: true);
}

/// The kernels library tstokenlib's build hook bundled for this run, the one
/// the suite already uses.
final _built = bundledKernelsPath() ?? (throw StateError('the build hook bundled no kernels library for the suite'));

/// Compiles [c] into a shared library at [out], or returns false when there is
/// no C compiler, which only a machine without developer tools lacks.
bool _compile(String c, String out) {
  final src = File('$out.c')..writeAsStringSync(c);
  try {
    final r = Process.runSync('cc', ['-shared', '-fPIC', '-o', out, src.path]);
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  } finally {
    src.deleteSync();
  }
}

/// A library that says it is the kernels at interface version [version], and
/// that leaves [marker] behind if it is ever loaded.
String _stub(int version, {String? marker}) => '''
#include <stdio.h>
unsigned int sk_version(void) { return $version; }
${marker == null ? '' : '__attribute__((constructor)) static void loaded(void) { FILE *f = fopen("$marker", "w"); if (f) fclose(f); }'}
''';

void main() {
  late Bundle b;
  late Harness h;
  setUp(() {
    b = Bundle.make();
    h = Harness.make();
  });
  tearDown(() {
    b.dispose();
    h.dispose();
  });

  group('the bundle', () {
    test('is found from the program, and through a link to it', () {
      final direct = b.native();
      expect(direct.bundle, b.root.path);
      expect(direct.kernelsPath, b.kernels);
      expect(direct.isarPath, b.isar);

      final elsewhere = Directory.systemTemp.createTempSync('cloak-path');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      final link = Link(p.join(elsewhere.path, 'cloak'))..createSync(b.program);
      final linked = NativeLibraries(executable: link.path, release: true, env: const {});
      expect(linked.kernelsPath, b.kernels, reason: 'the bundle is where the link points, not where it is');
      expect(linked.isarPath, b.isar);
    });

    test('a development build keeps each library\'s own lookup', () {
      final dev = NativeLibraries(executable: b.program, release: false, env: const {});
      expect(dev.bundle, isNull);
      expect(dev.kernelsPath, isNull);
      expect(dev.isarPath, isNull);
      expect(() => dev.checkKernels(), returnsNormally);
      expect(() => dev.checkIsar(), returnsNormally);
    });

    test('the person\'s variable wins over the bundle', () {
      expect(b.native({NativeLibraries.kernelsVariable: '/somewhere/else.dylib'}).kernelsPath, '/somewhere/else.dylib');
    });
  });

  group('A missing or unusable library is a refusal a person can act on', () {
    test('The kernels library removed', () async {
      expect((await h.init()).code, Exit.done);
      h.native = b.native();
      final ran = await h.run(['address']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "native library"'));
      expect(ran.err, contains(NativeLibraries.kernelsName));
      expect(ran.err, contains(b.lib));
      expect(ran.err, contains('reinstall'));
      expect(ran.err, isNot(contains('cargo')));
      expect(ran.out, isEmpty);

      // the counter did not move: the next address a working install gives
      // is still the first
      h.native = null;
      final next = await h.run(['--json', 'address']);
      expect(next.code, Exit.done, reason: '$next');
      expect((jsonDecode(next.out) as Map)['index'], 0);
    });

    test('init refuses before it prints a seed', () async {
      h.native = b.native();
      final ran = await h.init();
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "native library"'));
      expect(ran.out, isEmpty, reason: 'no seed');
      expect(Directory(h.wallet).existsSync(), isFalse, reason: 'no wallet was made');
    });

    test('A library of the wrong version', () async {
      if (!_compile(_stub(99), b.kernels)) return markTestSkipped('no C compiler to build a stub library with');
      expect((await h.init()).code, Exit.done);
      h.native = b.native();
      final ran = await h.run(['address']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "native library"'));
      expect(ran.err, contains('interface version 99'));
      expect(ran.err, contains('expects version 7'));
    });

    test('tstokenlib\'s own complaint is the same refusal, without its build instruction', () async {
      expect((await h.initWithPool()).code, Exit.done);
      h.ports.transportPort = _Throwing(StateError(
          'ML-KEM needs the native crate: cargo build --release --manifest-path native/stark_kernels/Cargo.toml'));
      h.native = b.native({NativeLibraries.kernelsVariable: _built});
      final ran = await h.run(['sync']);
      expect(ran.code, Exit.refused, reason: '$ran');
      expect(ran.err, contains('refused at "native library"'));
      expect(ran.err, contains('could not be loaded from $_built'), reason: 'it came from tstokenlib, not the check');
      expect(ran.err, isNot(contains('cargo')));
    });
  });

  group('No library is ever loaded from the working directory', () {
    test('A planted library is not loaded', () async {
      final stranger = Directory.systemTemp.createTempSync('cloak-cwd');
      addTearDown(() => stranger.deleteSync(recursive: true));
      final planted = p.join(stranger.path, 'native', 'stark_kernels', 'target', 'release', NativeLibraries.kernelsName);
      Directory(p.dirname(planted)).createSync(recursive: true);
      final marker = p.join(stranger.path, 'opened');
      if (!_compile(_stub(7, marker: marker), planted)) {
        return markTestSkipped('no C compiler to build a stub library with');
      }
      expect((await h.init()).code, Exit.done);
      h.native = b.native();
      final was = Directory.current;
      Directory.current = stranger;
      try {
        final ran = await h.run(['address']);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('refused at "native library"'));
      } finally {
        Directory.current = was;
      }
      expect(File(marker).existsSync(), isFalse, reason: 'the planted library was never opened');
    });
  });

  group('No library is ever downloaded', () {
    test('Isar\'s library absent', () async {
      expect((await h.init()).code, Exit.done);
      final before = _listing(h.root);
      Process.runSync('chmod', ['-R', 'a-w', b.root.path]);
      addTearDown(() => Process.runSync('chmod', ['-R', 'u+w', b.root.path]));
      final config = await CloakConfig.load(h.dir.config);
      final start = SpiffyChain.start(h.dir, config, native: b.native());
      await expectLater(
          start,
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'native library')
              .having((r) => r.reason, 'reason', allOf(contains(NativeLibraries.isarName), contains(b.lib)))));
      expect(_listing(h.root), before, reason: 'nothing was written into the wallet directory');
      expect(_listing(b.root), ['bin', 'bin/cloak', 'lib'], reason: 'nothing was written into the bundle');
    });
  });

  group('Commands that need no native library work without them', () {
    test('A bundle with no libraries', () async {
      expect((await h.init()).code, Exit.done);
      Directory(b.lib).deleteSync();
      for (final args in [
        ['--help'],
        ['--version'],
        ['status'],
        ['balance'],
        ['notes'],
        ['journal'],
      ]) {
        h.native = null;
        final present = await h.run(args);
        h.native = b.native();
        final absent = await h.run(args);
        expect(absent.code, present.code, reason: '$args\n$absent');
        expect(absent.code, Exit.done, reason: '$args\n$absent');
        expect(absent.err, isNot(contains('native library')), reason: '$args');
      }
    });
  });

  group('status reports the native libraries', () {
    test('Both present', () async {
      File(b.kernels).writeAsStringSync('not loaded, only looked for');
      File(b.isar).writeAsStringSync('not loaded, only looked for');
      h.native = b.native();
      final ran = await h.run(['--json', 'status']);
      expect(ran.code, Exit.done, reason: '$ran');
      final libs = ((jsonDecode(ran.out) as Map)['nativeLibraries'] as List).cast<Map>();
      expect({for (final l in libs) l['name']: l['path']}, {'kernels': b.kernels, 'isar': b.isar});
      expect(libs.every((l) => l['present'] == true), isTrue);
      expect(h.ports.touchedNetwork, isFalse);
    });

    test('One missing', () async {
      File(b.isar).writeAsStringSync('not loaded, only looked for');
      h.native = b.native();
      final ran = await h.run(['status']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(ran.out, contains('MISSING: no ${NativeLibraries.kernelsName} at ${b.kernels}'));
      expect(h.ports.touchedNetwork, isFalse);
    });
  });

  group('robustness', () {
    // every way the kernels file or the variable can be wrong, each one a
    // refusal at the same step, exit 1, and no trace
    test('a mutated kernels library, or a wrong variable, is always a refusal', () async {
      expect((await h.init()).code, Exit.done);
      final rng = Random(24);
      final real = File(_built).existsSync() ? File(_built).readAsBytesSync() : null;
      final files = <String, List<int>>{
        'empty': [],
        'zeroed': List.filled(4096, 0),
        'random bytes': List.generate(4096, (_) => rng.nextInt(256)),
        'another platform\'s library': [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, ...List.generate(4088, (_) => rng.nextInt(256))],
        if (real != null) 'truncated': real.sublist(0, real.length ~/ 3),
        if (real != null) 'a flipped header': [...real]..[0] ^= 0xff,
      };
      final variables = <String, String>{
        'a directory': b.lib,
        'a missing path': p.join(b.lib, 'nothing-here.dylib'),
        'an empty string': '',
      };
      var cases = 0;
      Future<void> expectRefused(String what) async {
        final ran = await h.run(['address']);
        expect(ran.code, Exit.refused, reason: '$what\n$ran');
        expect(ran.err, contains('refused at "native library"'), reason: what);
        expect(ran.err, isNot(contains('#0')), reason: '$what: no stack trace');
        expect(ran.err, isNot(contains('cargo')), reason: what);
        cases++;
      }

      for (final e in files.entries) {
        // a fresh name for each, since a loader may keep what it opened once
        final name = p.join(b.lib, '${e.key.replaceAll(RegExp(r"[^a-z]"), '_')}-${NativeLibraries.kernelsName}');
        File(name).writeAsBytesSync(e.value);
        h.native = b.native({NativeLibraries.kernelsVariable: name});
        await expectRefused(e.key);
      }
      for (final e in variables.entries) {
        h.native = b.native({NativeLibraries.kernelsVariable: e.value});
        await expectRefused(e.key);
      }
      printOnFailure('$cases cases');
      expect(cases, files.length + variables.length);
    });
  });
}

/// Every path under [dir], relative to it and sorted.
List<String> _listing(Directory dir) =>
    [for (final e in dir.listSync(recursive: true)) p.relative(e.path, from: dir.path)]..sort();

/// A transport whose opening throws what tstokenlib throws.
class _Throwing implements Transport {
  final Object error;
  _Throwing(this.error);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw error;
}
