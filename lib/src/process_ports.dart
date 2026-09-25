import 'package:libcloak/libcloak.dart';

import 'chain/spiffy_chain.dart';
import 'net/identity.dart';
import 'net/ricochet_wallet_transport.dart';
import 'shell/world.dart';
import 'wallet/config.dart';
import 'wallet/sealed_store.dart';
import 'wallet/wallet_dir.dart';

/// The real chain and the real pool, started on first use and stopped once.
///
/// Nothing is constructed until a command asks, which is what keeps `cloak
/// --help` and `cloak balance` from paying for Isar, an actor system, a peer
/// connection or a libp2p host.
class ProcessPorts implements Ports {
  final StringSink? progress;
  final Map<String, String> env;

  SpiffyChain? _chain;
  RicochetWalletTransport? _transport;

  ProcessPorts({this.progress, this.env = const {}});

  Future<SpiffyChain> _started(WalletDir dir, CloakConfig config, {SealedStore? sealed, bool offline = false}) async =>
      _chain ??= await SpiffyChain.start(dir, config, progress: progress, sealed: sealed, env: env, offline: offline);

  @override
  Future<HeaderSource> headers(WalletDir dir, CloakConfig config) async => (await _started(dir, config)).headers;

  @override
  Future<TransparentSide> transparent(WalletDir dir, CloakConfig config, SealedStore sealed,
          {bool offline = false}) async =>
      (await _started(dir, config, sealed: sealed, offline: offline)).transparent();

  @override
  Future<Transport> transport(WalletDir dir, CloakConfig config) async {
    final t = _transport;
    if (t != null) return t;
    final seed = await TransportIdentity.read(dir);
    return _transport = await RicochetWalletTransport.connect(
        seed: seed, server: config.server!, coordinator: config.coordinator!, timeout: config.timeout);
  }

  @override
  Future<void> close() async {
    final t = _transport;
    _transport = null;
    if (t != null) await t.close();
    final c = _chain;
    _chain = null;
    if (c != null) await c.stop();
  }
}
