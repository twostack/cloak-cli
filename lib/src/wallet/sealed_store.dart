import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart' show SecureStorage;

import 'wallet_dir.dart';

/// The transparent side's secrets, sealed in the wallet directory.
///
/// libspiffy keeps a wallet's mnemonic in whatever secure storage its host
/// gives it, and a deposit's refund needs a key only this wallet holds. Both
/// live here: one file, one AEAD box, written temp-then-rename and
/// owner-only, like the wallet file beside it.
///
/// The box's key is expanded from the wallet seed under a domain of its own,
/// and that is all the seed has to do with anything in here. The transparent
/// keys are generated at random and **sealed** by the seed, not derived from
/// it: a person who learns a transparent address learns nothing about a pool
/// address, and the reverse. What the seal does mean is that the seed and
/// this file together open it, which is one more reason the directory, and
/// not the seed alone, is the backup.
class SealedStore extends SecureStorage {
  static const version = 1;
  static const domain = 'cloak/sealed-store/$version';
  static const nonceLength = 24, macLength = 16;
  static const maxFile = 1024 * 1024;

  static final _cipher = Xchacha20.poly1305Aead();

  final String path;
  final SecretKey _key;
  final Map<String, String> _entries;

  SealedStore._(this.path, this._key, this._entries);

  static String pathIn(WalletDir dir) => '${dir.path}${Platform.pathSeparator}keys.enc';

  /// The store in [dir], opened with [seed]; an empty one when there is none.
  static Future<SealedStore> open(WalletDir dir, WalletSeed seed) async {
    final path = pathIn(dir);
    final key = SecretKey(seed.expand(domain, 32));
    final f = File(path);
    if (!await f.exists()) return SealedStore._(path, key, {});
    final length = await f.length();
    if (length > maxFile) throw Refusal('size', 'a sealed key store is at most $maxFile bytes and $path is $length');
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty || bytes[0] != version) {
      throw Refusal('version',
          'this build writes sealed key store version $version and $path is version ${bytes.isEmpty ? 'nothing' : bytes[0]}');
    }
    if (bytes.length < 1 + nonceLength + macLength) throw Refusal('size', '$path is too short to be a sealed key store');
    final nonce = bytes.sublist(1, 1 + nonceLength);
    final body = bytes.sublist(1 + nonceLength);
    final List<int> plain;
    try {
      plain = await _cipher.decrypt(
          SecretBox(body.sublist(0, body.length - macLength),
              nonce: nonce, mac: Mac(body.sublist(body.length - macLength))),
          secretKey: key,
          aad: [version]);
    } on SecretBoxAuthenticationError {
      throw Refusal('sealed key store', 'the wallet seed does not open $path; it belongs to another wallet');
    }
    final map = (jsonDecode(utf8.decode(plain)) as Map<String, dynamic>).cast<String, String>();
    return SealedStore._(path, key, map);
  }

  Future<void> _save() async {
    final r = Random.secure();
    final nonce = List.generate(nonceLength, (_) => r.nextInt(256));
    final box = await _cipher.encrypt(utf8.encode(jsonEncode(_entries)), secretKey: _key, nonce: nonce, aad: [version]);
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(const [], flush: true);
    await WalletDir.ownerOnly(tmp.path);
    await tmp.writeAsBytes([version, ...nonce, ...box.cipherText, ...box.mac.bytes], flush: true);
    await tmp.rename(path);
  }

  @override
  Future<String?> getString(String key) async => _entries[key];

  @override
  Future<void> setString(String key, String value) async {
    _entries[key] = value;
    await _save();
  }

  @override
  Future<bool> containsKey(String key) async => _entries.containsKey(key);

  @override
  Future<void> delete(String key) async {
    if (_entries.remove(key) != null) await _save();
  }

  @override
  Future<void> deleteAll() async {
    _entries.clear();
    await _save();
  }

  @override
  Future<Map<String, String>> getAll() async => Map.of(_entries);

  @override
  String toString() => 'SealedStore($path, ${_entries.length} entries, not printed)';
}
