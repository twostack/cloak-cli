import 'dart:io';
import 'dart:math';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart' show PoolWalletKeys;

/// Ports that start nothing and count every call.
///
/// A test hands it the fakes a command should reach, and asserts afterwards
/// on what was reached. Leaving a port null makes any use of it fail loudly,
/// which is how "balance touches no network" is a test rather than a hope.
class CountingPorts implements Ports {
  HeaderSource? headerSource;
  Transport? transportPort;
  TransparentSide? transparentSide;

  int headerStarts = 0, transportOpens = 0, transparentStarts = 0, closes = 0;

  CountingPorts({this.headerSource, this.transportPort, this.transparentSide});

  @override
  Future<HeaderSource> headers(WalletDir dir, CloakConfig config) async {
    headerStarts++;
    final h = headerSource;
    if (h == null) throw const HeaderSourceFailure('start', 'this test gave the command no header source');
    return h;
  }

  @override
  Future<Transport> transport(WalletDir dir, CloakConfig config) async {
    transportOpens++;
    final t = transportPort;
    if (t == null) throw const TransportFailure('open', 'this test gave the command no transport');
    return t;
  }

  @override
  Future<TransparentSide> transparent(WalletDir dir, CloakConfig config, SealedStore sealed) async {
    transparentStarts++;
    final t = transparentSide;
    if (t == null) throw const HeaderSourceFailure('start', 'this test gave the command no transparent side');
    return t;
  }

  @override
  Future<void> close() async => closes++;

  bool get touchedNetwork => headerStarts + transportOpens + transparentStarts > 0;
}

/// What a command printed and returned.
class Ran {
  final int code;
  final String out, err;
  const Ran(this.code, this.out, this.err);

  @override
  String toString() => 'exit $code\n--- stdout\n$out--- stderr\n$err';
}

/// One wallet directory and the world a command runs in against it.
class Harness {
  static const passphrase = 'correct horse battery staple, for a suite';

  final Directory root;
  final CountingPorts ports;
  final Map<String, String> env;
  DateTime now;
  final Random rng;

  /// What a terminal would answer, when a test attaches one.
  String? Function(String prompt)? terminal;

  /// The fixture's pool keys, stood in for the seed's; see
  /// [World.poolKeysForSuite].
  final PoolWalletKeys? poolKeys;

  Harness._(this.root, this.ports, this.env, this.now, this.rng, this.poolKeys);

  static int _made = 0;

  /// A fresh wallet directory. Each harness draws from its own seeded
  /// generator, so two wallets in one test never mint the same invoice id.
  static Harness make({CountingPorts? ports, DateTime? now, int? seed, PoolWalletKeys? poolKeys}) {
    final root = Directory.systemTemp.createTempSync('cloak-test');
    return Harness._(root, ports ?? CountingPorts(), {'HOME': root.path, passphraseEnv: passphrase},
        now ?? DateTime.utc(2026, 9, 24, 12), Random(seed ?? ++_made), poolKeys);
  }

  /// A wallet made by `cloak init` naming a pool, as a suite's fake one.
  Future<Ran> initWithPool() => init(['--server', '/ip4/127.0.0.1/udp/1/udx/p2p/fake', '--pool', 'coordinator']);

  String get wallet => '${root.path}/wallet';
  WalletDir get dir => WalletDir(wallet, DirSource.argument);

  World world(StringBuffer out, StringBuffer err) => World(
        out: out,
        err: err,
        env: env,
        ports: ports,
        now: () => now,
        readSecret: terminal == null ? null : (p) async => terminal!(p),
        readLine: terminal == null ? null : (p) async => terminal!(p),
        kdf: WalletKdf.fast,
        rng: rng,
        poolKeysForSuite: poolKeys == null ? null : (_) => poolKeys!,
      );

  /// Runs `cloak --wallet <this wallet> [args]`.
  Future<Ran> run(List<String> args, {bool walletFlag = true}) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runCloak([if (walletFlag) ...['--wallet', wallet], ...args], world(out, err));
    return Ran(code, '$out', '$err');
  }

  /// A wallet made by `cloak init`, with [extra] arguments.
  Future<Ran> init([List<String> extra = const []]) => run(['init', '--network', 'regtest', ...extra]);

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

const passphraseEnv = 'CLOAK_PASSPHRASE';
