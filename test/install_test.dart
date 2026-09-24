@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `install.sh`, run in a temporary HOME against a release served from a
/// directory, so every case can be made without GitHub: the platform and the
/// C library are faked by commands of the same names put first on PATH.
///
/// The bundles here are stand-ins whose `bin/cloak` only prints a version;
/// what is being tested is the installer. The same tests run against a real
/// release's assets by pointing CLOAK_INSTALL_BASE at it.
void main() {
  late Directory tmp;
  late String home, releases, shims;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cloak-install');
    home = p.join(tmp.path, 'home');
    releases = p.join(tmp.path, 'releases');
    shims = p.join(tmp.path, 'shims');
    for (final d in [home, releases, shims]) {
      Directory(d).createSync();
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final here = _platform();
  // macOS is released as a disk image, Linux as a tar.gz
  final ext = Platform.isMacOS ? 'dmg' : 'tar.gz';

  /// A release of [version]: a bundle for [platform] and its SHA256SUMS.
  void release(String version, {String? platform}) {
    final name = 'cloak-$version-${platform ?? here}';
    final dir = Directory(p.join(releases, 'download', 'v$version'))..createSync(recursive: true);
    final stage = Directory(p.join(tmp.path, 'stage-$version', name, 'bin'))..createSync(recursive: true);
    final program = File(p.join(stage.path, 'cloak'))
      ..writeAsStringSync('#!/bin/sh\necho "cloak $version (a stand-in)"\n');
    Process.runSync('chmod', ['+x', program.path]);
    final asset = p.join(dir.path, '$name.$ext');
    final made = Platform.isMacOS
        ? Process.runSync('hdiutil', [
            'create', '-quiet', '-volname', 'cloak $version', '-srcfolder', p.join(tmp.path, 'stage-$version'), //
            '-fs', 'HFS+', '-format', 'UDZO', '-ov', asset,
          ])
        : Process.runSync('tar', ['-czf', asset, '-C', p.join(tmp.path, 'stage-$version'), name]);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    File(p.join(dir.path, 'SHA256SUMS'))
        .writeAsStringSync('${sha256.convert(File(asset).readAsBytesSync())}  $name.$ext\n');
  }

  void shim(String name, String output) {
    final f = File(p.join(shims, name))..writeAsStringSync('#!/bin/sh\necho "$output"\n');
    Process.runSync('chmod', ['+x', f.path]);
  }

  /// A fake `uname` answering -s with [os] and -m with [arch].
  void fakeUname(String os, String arch) {
    final f = File(p.join(shims, 'uname'))
      ..writeAsStringSync('#!/bin/sh\ncase "\$1" in -s) echo $os ;; -m) echo $arch ;; *) echo $os ;; esac\n');
    Process.runSync('chmod', ['+x', f.path]);
  }

  ProcessResult install([List<String> args = const []]) => Process.runSync(
        'sh',
        [p.join(Directory.current.path, 'install.sh'), ...args],
        environment: {'HOME': home, 'PATH': '$shims:/usr/bin:/bin', 'CLOAK_INSTALL_BASE': 'file://$releases'},
        includeParentEnvironment: false,
      );

  String link() => p.join(home, '.local', 'bin', 'cloak');
  String share() => p.join(home, '.local', 'share', 'cloak');
  String runInstalled() => (Process.runSync(link(), ['--version']).stdout as String).trim();

  /// Everything under [dir], each path with its bytes' digest or its link
  /// target, so "as it was" can be compared.
  Map<String, String> snapshot(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return {};
    return {
      for (final e in d.listSync(recursive: true, followLinks: false))
        p.relative(e.path, from: dir): e is Link
            ? '-> ${e.targetSync()}'
            : e is File
                ? '${sha256.convert(e.readAsBytesSync())}'
                : 'dir',
    };
  }

  test('A clean install', () {
    release('0.1.0');
    final r = install(['--version', '0.1.0']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(runInstalled(), startsWith('cloak 0.1.0'));
    expect(Link(link()).targetSync(), p.join(share(), '0.1.0', 'bin', 'cloak'));
    expect(r.stdout, contains('is not on your PATH'));
  });

  test('the latest release, when no version is named', () {
    release('0.1.0');
    File(p.join(releases, 'latest')).writeAsStringSync('0.1.0\n');
    final r = install();
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(runInstalled(), startsWith('cloak 0.1.0'));
  });

  test('An Intel Mac', () {
    fakeUname('Darwin', 'x86_64');
    final r = install(['--version', '0.1.0']);
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('macOS x86_64'));
    expect(r.stderr, allOf(contains('macOS arm64'), contains('Linux x86_64'), contains('Linux aarch64')));
    expect(Directory(p.join(home, '.local')).existsSync(), isFalse, reason: 'nothing was installed');
  });

  test('a C library older than glibc 2.35', () {
    fakeUname('Linux', 'x86_64');
    shim('ldd', 'ldd (Ubuntu GLIBC 2.31-0ubuntu9.16) 2.31');
    final r = install(['--version', '0.1.0']);
    expect(r.exitCode, isNot(0));
    expect(r.stderr, allOf(contains('2.35'), contains('2.31')));
    expect(Directory(p.join(home, '.local')).existsSync(), isFalse);

    shim('ldd', 'musl libc (aarch64)');
    fakeUname('Linux', 'aarch64');
    final musl = install(['--version', '0.1.0']);
    expect(musl.exitCode, isNot(0));
    expect(musl.stderr, contains('musl'));
  });

  test('Upgrade', () {
    release('0.1.0');
    release('0.2.0');
    expect(install(['--version', '0.1.0']).exitCode, 0);
    final r = install(['--version', '0.2.0']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(runInstalled(), startsWith('cloak 0.2.0'));
    expect(Directory(p.join(share(), '0.1.0')).existsSync(), isTrue, reason: 'the old version stays until removed');
  });

  test('Uninstall', () {
    release('0.1.0');
    expect(install(['--version', '0.1.0']).exitCode, 0);
    final wallet = Directory(p.join(home, '.cloak'))..createSync();
    File(p.join(wallet.path, 'wallet.enc')).writeAsBytesSync([1, 2, 3]);
    File(p.join(wallet.path, 'notes.store')).writeAsStringSync('notes');
    final before = snapshot(wallet.path);
    final r = install(['--uninstall']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    expect(File(link()).existsSync() || Link(link()).existsSync(), isFalse);
    expect(Directory(share()).existsSync(), isFalse);
    expect(snapshot(wallet.path), before, reason: 'the wallet byte for byte as it was');
    expect(r.stdout, contains('the wallet in ${wallet.path} was not touched'));
  });

  // every way the download can be wrong, each against an installed 0.1.0
  // that must be left exactly as it was
  test('A corrupted download', () {
    release('0.1.0');
    expect(install(['--version', '0.1.0']).exitCode, 0);
    final installed = snapshot(p.join(home, '.local'));

    final dir = p.join(releases, 'download', 'v0.2.0');
    final asset = 'cloak-0.2.0-$here.$ext';
    final cases = <String, (void Function(), String)>{
      'a truncated bundle': (
        () => File(p.join(dir, asset)).writeAsBytesSync(File(p.join(dir, asset)).readAsBytesSync().sublist(0, 40)),
        'does not match SHA256SUMS',
      ),
      'flipped bytes': (
        () {
          final b = File(p.join(dir, asset)).readAsBytesSync();
          b[b.length ~/ 2] ^= 0xff;
          File(p.join(dir, asset)).writeAsBytesSync(b);
        },
        'does not match SHA256SUMS',
      ),
      'SHA256SUMS missing the line': (
        () => File(p.join(dir, 'SHA256SUMS')).writeAsStringSync(''),
        'has no line for $asset',
      ),
      'SHA256SUMS naming another file': (
        () => File(p.join(dir, 'SHA256SUMS')).writeAsStringSync(
            File(p.join(dir, 'SHA256SUMS')).readAsStringSync().replaceAll(asset, 'cloak-0.2.0-other.$ext')),
        'has no line for $asset',
      ),
      'SHA256SUMS malformed': (
        () => File(p.join(dir, 'SHA256SUMS')).writeAsStringSync('not a checksum $asset\n'),
        'has no line for $asset',
      ),
      'SHA256SUMS naming it twice': (
        () => File(p.join(dir, 'SHA256SUMS'))
            .writeAsStringSync(File(p.join(dir, 'SHA256SUMS')).readAsStringSync() * 2),
        'more than once',
      ),
      'the bundle missing from the release': (
        () => File(p.join(dir, asset)).deleteSync(),
        'could not download $asset',
      ),
      'SHA256SUMS missing from the release': (
        () => File(p.join(dir, 'SHA256SUMS')).deleteSync(),
        'could not download SHA256SUMS',
      ),
      'a bundle that does not unpack': (
        () {
          File(p.join(dir, asset)).writeAsStringSync('this is not a tar file or a disk image');
          File(p.join(dir, 'SHA256SUMS'))
              .writeAsStringSync('${sha256.convert(File(p.join(dir, asset)).readAsBytesSync())}  $asset\n');
        },
        Platform.isMacOS ? 'could not be opened' : 'could not be unpacked',
      ),
    };
    var counted = 0;
    for (final c in cases.entries) {
      Directory(dir).parent.listSync().where((d) => d.path.endsWith('v0.2.0')).forEach((d) => d.deleteSync(recursive: true));
      release('0.2.0');
      c.value.$1();
      final r = install(['--version', '0.2.0']);
      expect(r.exitCode, isNot(0), reason: c.key);
      expect(r.stderr, contains(c.value.$2), reason: '${c.key}: ${r.stderr}');
      expect(snapshot(p.join(home, '.local')), installed, reason: '${c.key}: the install as it was');
      expect(runInstalled(), startsWith('cloak 0.1.0'), reason: c.key);
      counted++;
    }
    printOnFailure('$counted cases');
    expect(counted, cases.length);
  });

  test('only HTTPS', () {
    final r = Process.runSync('sh', [p.join(Directory.current.path, 'install.sh'), '--version', '0.1.0'],
        environment: {'HOME': home, 'PATH': '/usr/bin:/bin', 'CLOAK_INSTALL_BASE': 'http://example.invalid'},
        includeParentEnvironment: false);
    expect(r.exitCode, isNot(0));
    expect(r.stderr, contains('only downloaded over HTTPS'));
  });
}

/// This machine's bundle name, as install.sh works it out.
String _platform() {
  final m = (Process.runSync('uname', ['-m']).stdout as String).trim();
  final arch = m == 'x86_64' || m == 'amd64' ? 'amd64' : 'arm64';
  return '${Platform.isMacOS ? 'macos' : 'linux'}-$arch';
}
