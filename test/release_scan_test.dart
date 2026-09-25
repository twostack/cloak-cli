import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/release/scan_secrets.dart';

/// The secret scan a bundle passes before it is published.
void main() {
  late Directory bundle;
  setUp(() {
    bundle = Directory.systemTemp.createTempSync('cloak-scan');
    File(p.join(bundle.path, 'bin', 'cloak')).createSync(recursive: true);
    File(p.join(bundle.path, 'bin', 'cloak')).writeAsBytesSync([0xcf, 0xfa, 0xed, 0xfe, ...List.filled(64, 0x33)]);
    File(p.join(bundle.path, 'README.md')).writeAsStringSync('# cloak\n\nA wallet.\n');
    File(p.join(bundle.path, 'LICENSE')).writeAsStringSync('MIT License\n');
  });
  tearDown(() => bundle.deleteSync(recursive: true));

  test('A bundle holds no one\'s secrets: a clean one passes', () {
    expect(scan(bundle), isEmpty);
  });

  test('a planted wallet file is found', () {
    File(p.join(bundle.path, 'lib', 'wallet.enc')).createSync(recursive: true);
    expect(scan(bundle), [contains('lib/wallet.enc is named like a wallet file')]);
  });

  test('a private key in WIF form is found, and base58 that is not one is not', () {
    final rng = Random(24);
    final key = [0xef, ...List.generate(32, (_) => rng.nextInt(256)), 0x01];
    final wif = _base58([...key, ...sha256.convert(sha256.convert(key).bytes).bytes.sublist(0, 4)]);
    expect(isWif(wif), isTrue);
    File(p.join(bundle.path, 'bin', 'cloak')).writeAsStringSync('code 5KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK code',
        mode: FileMode.append);
    expect(scan(bundle), isEmpty, reason: 'fifty-one base58 letters with no checksum are not a key');
    File(p.join(bundle.path, 'bin', 'cloak')).writeAsStringSync(' $wif ', mode: FileMode.append);
    expect(scan(bundle), [contains('bin/cloak holds a private key in WIF form')]);
  });

  test('hex: any 64 digits in a text file, and varied ones in a binary', () {
    final key = List.generate(64, (i) => '0123456789abcdef'[(i * 7 + 3) % 16]).join();
    File(p.join(bundle.path, 'bin', 'cloak')).writeAsStringSync('${'3' * 43}${'4' * 21}', mode: FileMode.append);
    expect(scan(bundle), isEmpty, reason: 'a run of two digits is a constant, not a key');
    File(p.join(bundle.path, 'bin', 'cloak')).writeAsStringSync(' ${reviewedHex.first} ', mode: FileMode.append);
    expect(scan(bundle), isEmpty, reason: 'a reviewed constant');
    File(p.join(bundle.path, 'bin', 'cloak')).writeAsStringSync(' $key ', mode: FileMode.append);
    expect(scan(bundle), [contains('bin/cloak holds 64 hex digits')]);
    expect(scan(bundle, published: {key}), isEmpty, reason: 'written in a published package, so public');
    File(p.join(bundle.path, 'README.md')).writeAsStringSync('seed: $key\n', mode: FileMode.append);
    expect(scan(bundle, published: {key}), [contains('README.md holds 64 hex digits')],
        reason: 'a text file has no business holding one, published or not');
  });

  test('a certificate is public, and passes', () {
    // the Linux Dart runtime embeds its root certificates in every program
    File(p.join(bundle.path, 'bin', 'cloak'))
        .writeAsStringSync('-----BEGIN CERTIFICATE-----\nMIIB...\n-----END CERTIFICATE-----\n', mode: FileMode.append);
    expect(scan(bundle), isEmpty);
  });

  test('a private key and the signing secrets\' own values are found', () {
    File(p.join(bundle.path, 'LICENSE')).writeAsStringSync('-----BEGIN ENCRYPTED PRIVATE KEY-----\n', mode: FileMode.append);
    File(p.join(bundle.path, 'README.md')).writeAsStringSync('hunter2-not-a-real-password\n', mode: FileMode.append);
    File(p.join(bundle.path, 'developer-id.p12')).createSync();
    final finds = scan(bundle, literals: {'CERTIFICATE_PASSWORD': 'hunter2-not-a-real-password'});
    expect(finds, containsAll([
      contains('LICENSE holds a private key in PEM form'),
      contains('README.md holds the value of CERTIFICATE_PASSWORD'),
      contains('developer-id.p12 is named like'),
    ]));
  });
}

String _base58(List<int> bytes) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var n = bytes.fold(BigInt.zero, (a, b) => (a << 8) + BigInt.from(b));
  final out = StringBuffer();
  while (n > BigInt.zero) {
    out.write(alphabet[(n % BigInt.from(58)).toInt()]);
    n = n ~/ BigInt.from(58);
  }
  return out.toString().split('').reversed.join();
}
