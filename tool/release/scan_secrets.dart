import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Searches an unpacked bundle for anything that is someone's secret, and
/// fails naming each find.
///
///     dart run tool/release/scan_secrets.dart <bundle directory> [--literal-env NAME]...
///
/// Run from the repository root after `dart pub get`, so the packages the
/// program was compiled from are there to be read.
///
/// What it looks for:
///
/// - a wallet's files by name (`wallet.enc`, `notes.store`, `identity.seed`
///   and the rest a wallet directory holds), and key or certificate files;
/// - PEM blocks and PKCS#12 files, the forms a signing certificate travels in;
/// - private keys in WIF form, found by their checksum, so a run of base58
///   letters that happens to be in a binary is not mistaken for one;
/// - private keys in hex: any run of 64 hex digits in a text file, and in a
///   binary any such run of more than a few distinct digits that is neither
///   written in the published source of a package the program is compiled
///   from (a curve's parameters, a genesis hash: public by being published)
///   nor on the reviewed list below;
/// - the value of each environment variable named with `--literal-env`, which
///   is how the workflow checks for its own signing secrets without ever
///   putting them on a command line.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/release/scan_secrets.dart <bundle directory> [--literal-env NAME]...');
    exit(2);
  }
  final literals = <String, String>{};
  for (var i = 1; i < args.length; i++) {
    if (args[i] == '--literal-env' && i + 1 < args.length) {
      final name = args[++i];
      final value = Platform.environment[name];
      if (value != null && value.isNotEmpty) literals[name] = value;
    }
  }
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) {
    stderr.writeln('scan-secrets: no .dart_tool/package_config.json here; run it from the repository root after dart pub get');
    exit(2);
  }
  final published = publishedHex(jsonDecode(config.readAsStringSync()) as Map<String, dynamic>,
      Directory.current.uri.resolve('.dart_tool/'));
  final finds = scan(Directory(args.first), literals: literals, published: published);
  if (finds.isEmpty) {
    stdout.writeln('scan-secrets: ${args.first} holds no one\'s secrets');
    return;
  }
  for (final f in finds) {
    stderr.writeln('scan-secrets: $f');
  }
  exit(1);
}

/// File names a wallet directory holds, and those keys and certificates are
/// kept in.
const secretNames = {
  'wallet.enc', 'keys.enc', 'identity.seed', 'notes.store', 'pool.view', 'state.json', 'journal', 'cloak.lock', //
  'config.yaml', '.env',
};
const secretExtensions = {'.p12', '.pfx', '.pem', '.key', '.cer', '.p8', '.keychain', '.keychain-db', '.mobileprovision'};

/// 64-digit hex runs found in a released native library and reviewed: each is
/// a constant of the library it is in, the same in every build, and not a key.
/// The native libraries' sources are not Dart packages, so what they hold is
/// listed here rather than read.
const reviewedHex = {
  // libisar: a constant of Isar's database engine
  '7a10d70b0b57e5ae8ac30e0728c9f1f7b6b3d51d69ef544f87ae054578c81daf',
};

/// Every 64-digit hex run written in the `lib/` of a package in [config], read
/// from [configDir]. What a package publishes is public, so a binary compiled
/// from it holding the same digits leaks nothing.
Set<String> publishedHex(Map<String, dynamic> config, Uri configDir) {
  final found = <String>{};
  for (final p in (config['packages'] as List).cast<Map<String, dynamic>>()) {
    // a root is written without its trailing slash, which resolving against
    // would drop the package's own directory from
    final root = configDir.resolve(p['rootUri'] as String);
    final lib = Directory.fromUri(Uri.parse(root.toString().endsWith('/') ? '$root' : '$root/')
        .resolve(p['packageUri'] as String? ?? 'lib/'));
    if (!lib.existsSync()) continue;
    for (final f in lib.listSync(recursive: true).whereType<File>()) {
      found.addAll(_hex64.allMatches(latin1.decode(f.readAsBytesSync())).map((m) => m[0]!.toLowerCase()));
    }
  }
  return found;
}

final _hex64 = RegExp(r'(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])');
final _base58 = RegExp(r'(?<![1-9A-HJ-NP-Za-km-z])[5KLc9][1-9A-HJ-NP-Za-km-z]{50,51}(?![1-9A-HJ-NP-Za-km-z])');
final _pem = RegExp(r'-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)-----');
const _textFiles = {'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES'};

/// Each find in [bundle], as a sentence naming the file.
List<String> scan(Directory bundle, {Map<String, String> literals = const {}, Set<String> published = const {}}) {
  final finds = <String>[];
  for (final entity in bundle.listSync(recursive: true, followLinks: false)) {
    final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    final rel = entity.path.substring(bundle.path.length).replaceFirst(RegExp(r'^/'), '');
    if (secretNames.contains(name) || secretExtensions.any(name.endsWith)) {
      finds.add('$rel is named like a wallet file, a key or a certificate');
    }
    if (entity is! File) continue;
    final bytes = entity.readAsBytesSync();
    // latin1 keeps every byte as one character, so offsets and runs are the
    // file's own and a binary decodes without error
    final text = latin1.decode(bytes);
    if (bytes.length > 4 && bytes[0] == 0x30 && bytes[1] == 0x82 && name.contains('.')) {
      finds.add('$rel looks like a PKCS#12 or DER key file');
    }
    if (_pem.hasMatch(text)) finds.add('$rel holds a PEM block: ${_pem.firstMatch(text)![0]}');
    for (final m in _base58.allMatches(text)) {
      if (isWif(m[0]!)) finds.add('$rel holds a private key in WIF form, at byte ${m.start}');
    }
    final isText = _textFiles.contains(name);
    for (final m in _hex64.allMatches(text)) {
      final hex = m[0]!.toLowerCase();
      if (!isText && (reviewedHex.contains(hex) || published.contains(hex))) continue;
      if (isText || hex.split('').toSet().length > 8) {
        finds.add('$rel holds 64 hex digits that may be a private key, at byte ${m.start}: ${hex.substring(0, 8)}...');
      }
    }
    for (final e in literals.entries) {
      if (text.contains(e.value)) finds.add('$rel holds the value of ${e.key}');
    }
  }
  return finds;
}

const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Whether [s] is a private key in wallet import format: base58, a mainnet or
/// testnet prefix, 32 bytes of key with or without the compression flag, and a
/// checksum that matches.
bool isWif(String s) {
  var n = BigInt.zero;
  for (final c in s.split('')) {
    final d = _alphabet.indexOf(c);
    if (d < 0) return false;
    n = n * BigInt.from(58) + BigInt.from(d);
  }
  final bytes = <int>[];
  while (n > BigInt.zero) {
    bytes.insert(0, (n & BigInt.from(255)).toInt());
    n = n >> 8;
  }
  if (bytes.length != 37 && bytes.length != 38) return false;
  if (bytes[0] != 0x80 && bytes[0] != 0xef) return false;
  if (bytes.length == 38 && bytes[33] != 0x01) return false;
  final body = bytes.sublist(0, bytes.length - 4);
  final check = sha256.convert(sha256.convert(body).bytes).bytes.sublist(0, 4);
  for (var i = 0; i < 4; i++) {
    if (check[i] != bytes[bytes.length - 4 + i]) return false;
  }
  return true;
}
