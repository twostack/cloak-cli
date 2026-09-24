import 'dart:io';

import 'package:libcloak/libcloak.dart';
import 'package:path/path.dart' as p;

/// Which of the three places named the wallet directory.
enum DirSource {
  argument('--wallet'),
  environment(WalletDir.envName),
  defaultPath('the default');

  final String label;
  const DirSource(this.label);
}

/// One wallet, as one directory.
///
/// Everything a wallet is lives here and nowhere else: the config, the
/// encrypted seed, the pool view, the note store, the journal, this program's
/// own state, the transport identity and the header store. So a wallet is
/// backed up by copying a directory, and a person can always see which one a
/// command used, because `cloak status` prints it and where the name came
/// from.
class WalletDir {
  /// The variable that names a wallet directory when `--wallet` does not.
  static const envName = 'CLOAK_WALLET';

  /// Under the home directory when neither names one.
  static const defaultName = '.cloak';

  final String path;
  final DirSource source;

  const WalletDir(this.path, this.source);

  /// The directory [argument] names, else [env]'s, else the default under the
  /// home directory, in that order.
  static WalletDir resolve({String? argument, required Map<String, String> env}) {
    if (argument != null && argument.isNotEmpty) return WalletDir(p.absolute(argument), DirSource.argument);
    final fromEnv = env[envName];
    if (fromEnv != null && fromEnv.isNotEmpty) return WalletDir(p.absolute(fromEnv), DirSource.environment);
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null || home.isEmpty) {
      throw const Refusal('wallet directory',
          'neither --wallet nor $envName names a wallet directory, and there is no HOME to put the default in');
    }
    return WalletDir(p.join(home, defaultName), DirSource.defaultPath);
  }

  String get config => p.join(path, 'config.yaml');
  String get walletFile => p.join(path, 'wallet.enc');
  String get poolView => p.join(path, 'pool.view');
  String get noteStore => p.join(path, 'notes.store');
  String get journal => p.join(path, 'journal');
  String get state => p.join(path, 'state.json');
  String get identity => p.join(path, 'identity.seed');
  String get chain => p.join(path, 'chain');
  String get lock => p.join(path, 'cloak.lock');

  bool get exists => Directory(path).existsSync();
  bool get holdsWallet => File(walletFile).existsSync();

  /// Makes the directory owner-only, creating it if it is not there.
  ///
  /// It is created and narrowed before anything is written into it, so the
  /// seed never sits in a directory somebody else can list.
  Future<void> create() async {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
    await ownerOnly(path, directory: true);
  }

  /// Narrows [target] to its owner. A failure is a refusal, because the thing
  /// being protected is about to be written.
  static Future<void> ownerOnly(String target, {bool directory = false}) async {
    if (Platform.isWindows) return;
    final r = await Process.run('chmod', [directory ? '700' : '600', target]);
    if (r.exitCode != 0) {
      throw Refusal('permissions', 'could not make $target owner-only: ${'${r.stderr}'.trim()}');
    }
  }

  /// A warning naming the path and its mode when the directory is readable,
  /// writable or searchable by anyone but its owner, else null.
  ///
  /// A warning and not a refusal: refusing would leave a person unable to
  /// reach their own money over a permission bit, and the fix is one chmod
  /// they can make themselves.
  String? permissionWarning() {
    if (Platform.isWindows) return null;
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    final mode = stat.mode & 0x1ff;
    if (mode & 0x3f == 0) return null;
    final octal = mode.toRadixString(8).padLeft(3, '0');
    return 'the wallet directory $path is mode $octal, which lets other users of this machine read it; '
        'run: chmod 700 $path';
  }

  @override
  String toString() => path;
}
