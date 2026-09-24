import 'dart:io';
import 'dart:isolate';

import 'package:cloak_cli/src/chain/bip39_english.dart';
import 'package:dartsv/dartsv.dart';
import 'package:test/test.dart';

/// The wordlist the binary carries, against the one dartsv reads from its
/// package: the same 2,048 words in the same order, so a mnemonic drawn with
/// it is one dartsv, and libspiffy after it, reads the same way.
void main() {
  test('the carried wordlist is dartsv\'s, word for word', () async {
    final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartsv/src/bip39/wordlists/english.txt'));
    final theirs = File.fromUri(uri!).readAsLinesSync().map((w) => w.trim()).where((w) => w.isNotEmpty).toList();
    final ours = bip39English.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    expect(ours, hasLength(2048));
    expect(ours, theirs);
  });

  test('a mnemonic drawn with it validates under dartsv', () async {
    final words = bip39English.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join('\n');
    final m = await Mnemonic().generateMnemonic2((_, __) async => words);
    expect(m.split(' '), hasLength(12));
    expect(await Mnemonic().validateMnemonic(m), isTrue);
  });
}
