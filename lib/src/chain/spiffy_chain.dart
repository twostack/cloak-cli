import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:isar/isar.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart';
import 'package:path/path.dart' as p;

import '../native/native_libraries.dart';
import '../shell/world.dart';
import '../wallet/config.dart';
import '../wallet/wallet_dir.dart';
import '../wallet/sealed_store.dart';
import 'spiffy_header_source.dart';
import 'spiffy_transparent.dart';

/// libspiffy, started for one command that needs the chain.
///
/// Its header store is kept under the wallet directory, in Isar, so headers
/// accepted on one run are there on the next. The store is anchored to the
/// configured network's genesis; a store built under another network is
/// refused naming both, before anything is started, and is never cleared: it
/// is public data, and a person may want it back when they switch again.
///
/// Starting it is the expensive thing this program does (Isar, an actor
/// system, peer connections), which is why only a command that asks a header
/// question starts it, and why it is stopped when the command returns.
class SpiffyChain {
  /// The file recording which network the header store was built under.
  static const networkFile = 'network';

  /// How long a command waits for the chain to stop growing before it asks
  /// its question, and how long it waits at most.
  static const settle = Duration(seconds: 3), maxWait = Duration(seconds: 60);

  /// How long a chain that has not moved at all is watched before it is
  /// taken to be at its tip.
  static const quiet = Duration(milliseconds: 750);

  final HeaderSource headers;
  final LibSpiffyActorSystem _system;
  final ArcServiceConfig arcConfig;

  /// Whether the transparent side's secrets were given at the start, which is
  /// the only time libspiffy takes them.
  final bool sealed;

  SpiffyTransparentSide? _transparent;

  SpiffyChain._(this.headers, this._system, this.arcConfig, this.sealed);

  /// The transparent side, opened on first use.
  Future<TransparentSide> transparent() async {
    if (!sealed) {
      throw StateError('the chain was started without the transparent side\'s sealed store; a command that needs '
          'the transparent side asks for it before it asks the chain anything');
    }
    return _transparent ??= await SpiffyTransparentSide.open(_system, ArcService.fromConfig(arcConfig));
  }

  static ArcServiceConfig arcFor(CloakConfig config, Map<String, String> env) {
    final key = env['CLOAK_ARC_API_KEY'];
    final url = config.arcUrl;
    if (url != null) return ArcServiceConfig(baseUrl: url, apiKey: key);
    return config.network == CloakNetwork.mainnet
        ? ArcServiceConfig.taalMainnet(apiKey: key)
        : ArcServiceConfig.taalTestnet(apiKey: key);
  }

  static Future<SpiffyChain> start(WalletDir dir, CloakConfig config,
      {StringSink? progress,
      SealedStore? sealed,
      Map<String, String> env = const {},
      NativeLibraries? native}) async {
    await checkNetwork(dir, config);
    await _startIsar(native ?? NativeLibraries.ofProcess(env));
    await Directory(dir.chain).create(recursive: true);
    final isar = await _open(dir.chain);
    final system = LibSpiffyActorSystem();
    final arc = arcFor(config, env);
    try {
      await system.initialize(
        isar: isar,
        dataDirectory: dir.chain,
        networkType: config.network.spiffyName,
        // regtest has no default peers, so with none named there is nothing
        // to connect to, and libspiffy refuses to start P2P with no one to
        // talk to; the transparent side and ARC need no peer
        enableP2P: config.peers.isNotEmpty || config.network != CloakNetwork.regtest,
        peerAddresses: config.peers.isEmpty ? null : config.peers,
        secureStorage: sealed,
        arcConfig: arc,
      );
    } on StateError catch (e) {
      if (e.message.contains('not anchored to')) {
        throw Refusal(
            'network', 'the header store in ${dir.chain} does not belong to ${config.network.name}: ${e.message}');
      }
      throw Refusal('chain', 'the chain could not be started: ${e.message}');
    }
    await File(p.join(dir.chain, networkFile)).writeAsString(config.network.name);
    final chain = system.headerChain;
    await _waitForSettle(chain, progress);
    return SpiffyChain._(SpiffyHeaderSource(chain), system, arc, sealed != null);
  }

  /// Starts Isar before libspiffy can: Isar starts once per process, so the
  /// `download: true` libspiffy and eventador ask for later has no effect.
  ///
  /// A released build names the bundle's library and never downloads; a
  /// missing file is refused before Isar is touched, so Isar's own fallback,
  /// a download written beside the program, is never reached. A development
  /// build lets Isar find or download its own, as it always has.
  static Future<void> _startIsar(NativeLibraries native) async {
    final path = native.isarPath;
    if (path != null) {
      native.checkIsar();
      try {
        await Isar.initializeIsarCore(libraries: {Abi.current(): path});
      } catch (e) {
        throw native.isarUnusable(e);
      }
      return;
    }
    try {
      await Isar.initializeIsarCore(download: true);
    } catch (e) {
      final text = '$e';
      if (!text.contains('already')) {
        throw Refusal('chain',
            'the header store is kept in Isar, whose native library is downloaded on first use, and it could not '
            'be loaded or downloaded ($text); this has nothing to do with the wallet, and commands that need no '
            'chain still work');
      }
    }
  }

  /// Refuses a header store built under another network than [config]'s,
  /// naming both, and changes nothing.
  static Future<void> checkNetwork(WalletDir dir, CloakConfig config) async {
    final f = File(p.join(dir.chain, networkFile));
    if (!await f.exists()) return;
    final found = (await f.readAsString()).trim();
    if (found != config.network.name) {
      throw Refusal('network',
          'the config names ${config.network.name} and the header store in ${dir.chain} was built for $found; it '
          'is left as it is. Set the network back, or move the header store aside to build a new one');
    }
  }

  /// Waits for the chain to stop growing, saying where it stands while it
  /// grows, so a command catching up does not look like one that has hung.
  ///
  /// A store already at the tip does not grow, and a command over it answers
  /// at once: the wait is only as long as headers keep arriving.
  static Future<void> _waitForSettle(BlockHeaderChain chain, StringSink? progress) async {
    final start = DateTime.now();
    var last = chain.bestHeight, still = DateTime.now();
    var moved = false;
    while (DateTime.now().difference(start) < maxWait) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final h = chain.bestHeight;
      if (h != last) {
        progress?.writeln('cloak: chain: at height $h');
        last = h;
        still = DateTime.now();
        moved = true;
      } else if (DateTime.now().difference(still) >= (moved ? settle : quiet)) {
        return;
      }
    }
    progress?.writeln('cloak: chain: still catching up at height $last; answering from what it holds');
  }

  /// Stops libspiffy, and leaves its database open.
  ///
  /// libspiffy's shutdown returns with work still in flight: an actor that
  /// recovers after a command's last answer reads the database afterwards.
  /// Closing it under that work fails the work, and has crashed the process
  /// inside Isar's native library. A database is released when the process
  /// ends, which for the binary is right after this; a process that runs
  /// many commands, as the suite does, opens each database once and reuses
  /// it.
  Future<void> stop() => _system.shutdown();

  static final Map<String, Isar> _opened = {};

  /// Isar names an open database by its file's name, which is the same in
  /// every wallet, so one wallet's is closed before another's is opened.
  static Future<Isar> _open(String directory) async {
    final open = _opened[directory];
    if (open != null && open.isOpen) return open;
    for (final other in _opened.values.where((x) => x.isOpen).toList()) {
      await other.close();
    }
    _opened.clear();
    return _opened[directory] = await Isar.open(LibSpiffySchemas.allSchemas, directory: directory, name: 'headers');
  }
}
