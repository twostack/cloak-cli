import 'dart:convert';
import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// The binary's shape: which commands exist, what the exit codes mean, what
/// a refusal looks like, and what help costs.
void main() {
  late Harness h;
  setUp(() => h = Harness.make());
  tearDown(() => h.dispose());

  const seventeen = [
    'init', 'unlock', 'address', 'status', 'sync', 'invoice', 'pay', 'proof', 'check', 'ack', //
    'balance', 'notes', 'journal', 'receive', 'deposit', 'refund', 'withdraw',
  ];

  test('The seventeen subcommands, and no others', () async {
    final ran = await h.run(['--help'], walletFlag: false);
    for (final c in seventeen) {
      expect(ran.out, contains('  $c'), reason: '$c is listed');
    }
    expect(ran.out, contains('invoice new'));
    expect(ran.out, contains('invoice show'));
  });

  test('The README lists every command, and only commands that exist', () async {
    final readme = File('README.md').readAsStringSync();
    final listed = {for (final m in RegExp(r'^\| `cloak ([a-z]+(?: [a-z]+)?)`', multiLine: true).allMatches(readme)) m.group(1)!};
    final help = (await h.run(['--help'], walletFlag: false)).out;
    final real = {for (final m in RegExp(r'^  ([a-z]+(?: [a-z]+)?)\s{2,}', multiLine: true).allMatches(help)) m.group(1)!};
    expect(listed, real, reason: 'the README\'s table is the program\'s table');
    expect(listed, hasLength(18), reason: 'seventeen commands, invoice counted as its two verbs');
  });

  test('a command with verbs lists them under --help', () async {
    final ran = await h.run(['invoice', '--help'], walletFlag: false);
    expect(ran.code, Exit.done, reason: '$ran');
    expect(ran.out, contains('invoice new'));
    expect(ran.out, contains('invoice show'));
    final bare = await h.run(['invoice'], walletFlag: false);
    expect(bare.code, Exit.usage);
    expect(bare.err, contains('needs one of new, show, and was given none'));
  });

  test('A developer\'s binary', () async {
    final ran = await h.run(['--version'], walletFlag: false);
    expect(ran.code, Exit.done, reason: '$ran');
    expect(ran.out, 'cloak ${CloakVersion.program} development build\n');
    final json = await h.run(['--json', '--version'], walletFlag: false);
    expect(jsonDecode(json.out), {'version': CloakVersion.program, 'build': 'development'});
    expect(h.ports.touchedNetwork, isFalse);
    expect(Directory(h.wallet).existsSync(), isFalse, reason: 'no wallet was read');
  });

  test('An unknown subcommand', () async {
    final ran = await h.run(['frobnicate']);
    expect(ran.code, Exit.usage, reason: '$ran');
    expect(ran.err, contains('frobnicate is not a command'));
    for (final c in seventeen) {
      expect(ran.err, contains(c));
    }
    expect(ran.out, isEmpty);
    expect(h.ports.touchedNetwork, isFalse);
    expect(h.ports.closes, 0, reason: 'nothing was started, so nothing is stopped');
    expect(Directory(h.wallet).existsSync(), isFalse, reason: 'the wallet was not read or made');
  });

  test('Help costs nothing', () async {
    for (final args in [<String>[], ['--help'], ['-h']]) {
      final ran = await h.run(args);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(ran.out, contains('usage: cloak'));
      expect(ran.err, isEmpty);
    }
    expect(h.ports.touchedNetwork, isFalse);
    expect(Directory(h.wallet).existsSync(), isFalse, reason: 'the wallet file was not opened');
  });

  test('A command\'s own help names its options and runs nothing', () async {
    final ran = await h.run(['pay', '--help']);
    expect(ran.code, Exit.done);
    expect(ran.out, contains('cloak pay'));
    final verb = await h.run(['invoice', 'new', '--help']);
    expect(verb.code, Exit.done);
    expect(verb.out, contains('--amount'));
    expect(h.ports.touchedNetwork, isFalse);
  });

  test('A malformed command is exit 2 and a refusal is exit 1', () async {
    final bad = await h.run(['balance', '--no-such-option']);
    expect(bad.code, Exit.usage, reason: '$bad');
    final noVerb = await h.run(['invoice']);
    expect(noVerb.code, Exit.usage, reason: '$noVerb');
    final refused = await h.run(['unlock']);
    expect(refused.code, Exit.refused, reason: '$refused');
    expect(refused.err, contains('refused at "wallet"'));
    expect(refused.err, isNot(contains('#0')), reason: 'no stack trace');
  });

  test('No user-facing string in this package is a bare "invalid", "error" or "failed"', () {
    final bare = RegExp(r'''(['"])\s*(invalid|error|failed|Invalid|Error|Failed)[.!]?\s*\1''');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (bare.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(offenders, isEmpty);
  });

  test('A passphrase is never an argument', () async {
    for (final arg in ['--passphrase=hunter2', '--passphrase', '--password=x', '-p']) {
      final ran = await h.run(['unlock', arg, 'hunter2']);
      expect(ran.code, Exit.usage, reason: '$arg: $ran');
      expect(ran.err, contains('never given as an argument'));
      expect(ran.err, contains('every process on this machine can read'));
      expect(ran.err, isNot(contains('hunter2')), reason: 'the refusal does not repeat it');
    }
  });

  test('Non-interactive use reads the named variable; with neither, a named refusal', () async {
    expect((await h.init()).code, Exit.done);
    final ok = await h.run(['unlock']);
    expect(ok.code, Exit.done, reason: '$ok');
    h.env.remove(passphraseEnv);
    final none = await h.run(['unlock']);
    expect(none.code, Exit.refused);
    expect(none.err, contains('no terminal is attached'));
    expect(none.err, contains(passphraseEnv));
  });

  test('what a library prints never reaches the answer', () async {
    final h = Harness.make(ports: _Chatty());
    addTearDown(h.dispose);
    expect((await h.init()).code, Exit.done);
    final ran = await h.run(['status', '--json']);
    expect(ran.code, Exit.done, reason: '$ran');
    expect(() => jsonDecode(ran.out), returnsNormally, reason: 'stdout is one JSON object: ${ran.out}');
    expect(ran.out, isNot(contains('[LibSpiffy]')));
    expect(ran.err, isNot(contains('[LibSpiffy]')), reason: 'and it is not logged without -v');
    final loud = await h.run(['-v', 'status', '--json']);
    expect(() => jsonDecode(loud.out), returnsNormally);
    expect(loud.err, contains('[print] [LibSpiffy] P2P network: regtest'));
  });

  group('the bounded reader', () {
    test('An oversized invoice file', () async {
      final path = '${h.root.path}/big.invoice';
      File(path).writeAsBytesSync(List.filled(Invoice.maxInvoice + 1, 1));
      await expectLater(
          BoundedFile.read(path, MessageKind.invoice),
          throwsA(isA<Refusal>()
              .having((r) => r.step, 'step', 'size')
              .having((r) => r.reason, 'reason', contains('${Invoice.maxInvoice}'))
              .having((r) => r.reason, 'reason', contains('${Invoice.maxInvoice + 1}'))
              .having((r) => r.reason, 'reason', contains('invoice'))));
    });

    test('A file declaring a terabyte is refused without a buffer of its size', () async {
      // a sparse file: its size is what the file system says, and nothing is
      // allocated to say it. A reader that read before checking would try to
      // allocate a terabyte and die; this one refuses in a millisecond.
      final path = '${h.root.path}/sparse.proof';
      final raf = File(path).openSync(mode: FileMode.write)..truncateSync(1 << 40);
      raf.closeSync();
      final sw = Stopwatch()..start();
      await expectLater(BoundedFile.read(path, MessageKind.paymentProof),
          throwsA(isA<Refusal>().having((r) => r.reason, 'reason', contains('${1 << 40}'))));
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(ProcessInfo.currentRss, lessThan(1 << 32), reason: 'nothing near the declared size was allocated');
    });
  });
}

/// Ports whose closing prints, as libspiffy prints when it starts and stops.
class _Chatty extends CountingPorts {
  @override
  Future<void> close() async {
    print('[LibSpiffy] P2P network: regtest → regtest');
    await super.close();
  }
}
