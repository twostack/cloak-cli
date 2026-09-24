import 'dart:convert';
import 'dart:io';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// The wallet directory: where it is, who may read it, making a wallet,
/// opening one, and the lock that keeps two writers apart.
void main() {
  late Harness h;
  setUp(() => h = Harness.make());
  tearDown(() => h.dispose());

  group('the directory', () {
    test('The directory in use is always visible', () async {
      final byArg = await h.run(['status', '--json']);
      expect(byArg.code, Exit.done, reason: '$byArg');
      var facts = jsonDecode(byArg.out) as Map<String, Object?>;
      expect(facts['wallet'], h.wallet);
      expect(facts['source'], '--wallet');

      h.env[WalletDir.envName] = '${h.root.path}/from-env';
      final byEnv = await h.run(['status'], walletFlag: false);
      expect(byEnv.out, contains('wallet: ${h.root.path}/from-env'));
      expect(byEnv.out, contains('named by: ${WalletDir.envName}'));

      h.env.remove(WalletDir.envName);
      final byDefault = await h.run(['status', '--json'], walletFlag: false);
      facts = jsonDecode(byDefault.out) as Map<String, Object?>;
      expect(facts['wallet'], '${h.root.path}/.cloak');
      expect(facts['source'], 'the default');

      // and the argument wins over the variable
      h.env[WalletDir.envName] = '${h.root.path}/from-env';
      final both = await h.run(['status', '--json']);
      expect((jsonDecode(both.out) as Map)['source'], '--wallet');
    });

    test('A world-readable wallet is reported', () async {
      expect((await h.init()).code, Exit.done);
      expect(FileStat.statSync(h.wallet).modeString(), 'rwx------', reason: 'made owner-only');
      Process.runSync('chmod', ['755', h.wallet]);
      final ran = await h.run(['status']);
      expect(ran.code, Exit.done, reason: 'a warning, not a refusal');
      expect(ran.err, contains('warning'));
      expect(ran.err, contains(h.wallet));
      expect(ran.err, contains('755'));
      expect(ran.out, contains('wallet: ${h.wallet}'), reason: 'the command still did its work');
    });
  });

  group('init', () {
    test('The seed is recorded before anything else exists', () async {
      final ran = await h.init();
      expect(ran.code, Exit.done, reason: '$ran');
      final lines = const LineSplitter().convert(ran.out);
      expect(lines, hasLength(1), reason: 'standard output carries the seed and nothing else');
      expect(lines.single, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(ran.err, contains('a new wallet is in'));
      for (final f in [h.dir.poolView, h.dir.noteStore, h.dir.journal, h.dir.state]) {
        expect(FileSystemEntity.typeSync(f), FileSystemEntityType.notFound, reason: '$f exists already');
      }
      expect(File(h.dir.walletFile).existsSync(), isTrue);
      expect(FileStat.statSync(h.dir.walletFile).modeString(), 'rw-------');
      expect(FileStat.statSync(h.dir.identity).modeString(), 'rw-------');
      expect(File(h.dir.walletFile).readAsStringSync(encoding: latin1), isNot(contains(lines.single)),
          reason: 'the seed is not on disk in the clear');
    });

    test('init refuses an occupied directory', () async {
      expect((await h.init()).code, Exit.done);
      final before = File(h.dir.walletFile).readAsBytesSync();
      final again = await h.init();
      expect(again.code, Exit.refused, reason: '$again');
      expect(again.err, contains(h.dir.walletFile));
      expect(again.out, isEmpty, reason: 'no second seed was printed');
      expect(File(h.dir.walletFile).readAsBytesSync(), before);
    });

    test('The seed printed is the seed the file holds', () async {
      final ran = await h.init();
      final stored = await WalletFile.open(path: h.dir.walletFile, passphrase: Harness.passphrase);
      final fromHex = WalletSeed.fromHex(ran.out.trim());
      expect(WalletKeys(seed: fromHex, birthday: 0).sk, WalletKeys(seed: stored.seed, birthday: 0).sk);
    });
  });

  group('the passphrase', () {
    test('Non-interactive use works without a terminal', () async {
      expect((await h.init()).code, Exit.done);
      h.terminal = null;
      final ran = await h.run(['unlock', '--json']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect((jsonDecode(ran.out) as Map)['opened'], isTrue);
    });

    test('A prompt, when there is a terminal and no variable', () async {
      expect((await h.init()).code, Exit.done);
      h.env.remove(passphraseEnv);
      final asked = <String>[];
      h.terminal = (p) {
        asked.add(p);
        return Harness.passphrase;
      };
      final ran = await h.run(['unlock']);
      expect(ran.code, Exit.done, reason: '$ran');
      expect(asked, ['wallet passphrase: ']);
    });

    test('A wrong passphrase is a named refusal', () async {
      expect((await h.init()).code, Exit.done);
      h.env[passphraseEnv] = 'not the passphrase';
      final ran = await h.run(['unlock']);
      expect(ran.code, Exit.refused);
      expect(ran.err, contains(h.dir.walletFile));
      expect(ran.err, contains('passphrase does not open'));
      expect(ran.err.toLowerCase(), isNot(contains('corrupt')));
    });
  });

  group('the lock', () {
    test('A second writer in the same process is refused naming the lock', () async {
      expect((await h.init()).code, Exit.done);
      final held = await WalletLock.take(h.dir.lock);
      try {
        final ran = await h.run(['address']);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('refused at "lock"'));
        expect(ran.err, contains(h.wallet));
        expect(ran.err, contains('process $pid'));
      } finally {
        await held.release();
      }
      expect((await h.run(['address'])).code, Exit.done, reason: 'released, so the next writer proceeds');
    });

    test('A second writer in another process is refused', () async {
      expect((await h.init()).code, Exit.done);
      // --verbosity=error: tstokenlib's build hook announces itself on stdout
      final child = await Process.start(Platform.resolvedExecutable, ['run', '--verbosity=error', 'test/support/hold_lock.dart', h.dir.lock]);
      final ready = await child.stdout.transform(utf8.decoder).first;
      expect(ready.trim(), 'held');
      try {
        final ran = await h.run(['address']);
        expect(ran.code, Exit.refused, reason: '$ran');
        expect(ran.err, contains('process ${child.pid}'));
      } finally {
        child.kill();
        await child.exitCode;
      }
      final after = await h.run(['address']);
      expect(after.code, Exit.done, reason: 'the operating system released it with the process: $after');
    });

    test('A read-only command needs no lock', () async {
      expect((await h.init()).code, Exit.done);
      final held = await WalletLock.take(h.dir.lock);
      try {
        for (final c in ['balance', 'notes', 'journal', 'status']) {
          final ran = await h.run([c]);
          expect(ran.code, Exit.done, reason: '$c: $ran');
        }
      } finally {
        await held.release();
      }
    });
  });
}
