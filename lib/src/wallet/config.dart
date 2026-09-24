import 'dart:io';

import 'package:libcloak/libcloak.dart';
import 'package:yaml/yaml.dart';

/// The networks a wallet can be made for.
enum CloakNetwork {
  regtest('regtest'),
  testnet('testnet'),
  mainnet('mainnet');

  final String name;
  const CloakNetwork(this.name);

  static CloakNetwork? parse(String s) {
    for (final n in values) {
      if (n.name == s) return n;
    }
    return switch (s) { 'test' => testnet, 'main' => mainnet, _ => null };
  }

  /// The number libspiffy's actor system is started with.
  String get spiffyName => switch (this) { regtest => 'regtest', testnet => 'test', mainnet => 'main' };
}

/// The wallet's settings, from `config.yaml` in the wallet directory.
///
/// It holds nothing secret, on purpose: a passphrase, an RPC password or an
/// API key in a config file is a secret in a file nobody thinks of as holding
/// one, so those come from the environment or a prompt and never from here.
/// That also means this file can be shown, copied into a bug report, and
/// diffed between machines.
class CloakConfig {
  static const fileVersion = 1;

  final CloakNetwork network;

  /// The ricochet server, as a multiaddr ending in `/p2p/<peer id>`.
  final String? server;

  /// The coordinator's peer id, whose feed is the pool's.
  final String? coordinator;

  /// How long a reply from the pool is waited for.
  final Duration timeout;

  /// Peers the header chain syncs from, as `host:port`. Empty means the
  /// network's own seeds.
  final List<String> peers;

  /// Blocks deep before a payment proof counts, the block itself counting as
  /// one.
  final int confirmations;

  /// Blocks past the next round's expected height that a deposit's refund is
  /// set to, so a coordinator does not skip it for opening too soon.
  final int refundMargin;

  /// The fewest blocks past the chain's tip a deposit's refund may open at.
  /// A coordinator skips a deposit whose refund opens sooner, because a refund
  /// mined before the round would invalidate the round.
  final int refundMinimum;

  /// The ARC endpoint a transparent transaction is broadcast to, or null for
  /// the network's default.
  final String? arcUrl;

  const CloakConfig({
    required this.network,
    this.server,
    this.coordinator,
    this.timeout = const Duration(seconds: 30),
    this.peers = const [],
    int? confirmations,
    this.refundMargin = 144,
    this.refundMinimum = 100,
    this.arcUrl,
  }) : confirmations = confirmations ?? (network == CloakNetwork.regtest ? 1 : 6);

  /// Whether the pool has been named. A wallet can exist before it has.
  bool get hasPool => server != null && coordinator != null;

  static Future<CloakConfig> load(String path) async {
    final f = File(path);
    if (!await f.exists()) throw Refusal('config', 'there is no config at $path; run cloak init');
    final text = await f.readAsString();
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw Refusal('config', '$path is not YAML: ${e.message}');
    }
    if (doc is! YamlMap) throw Refusal('config', '$path holds no settings');
    final version = doc['version'];
    if (version != fileVersion) {
      throw Refusal('config', 'this build writes config version $fileVersion and $path is version $version');
    }
    final netName = '${doc['network']}';
    final network = CloakNetwork.parse(netName);
    if (network == null) {
      throw Refusal('config', '$path names network "$netName", and a wallet is for regtest, testnet or mainnet');
    }
    final pool = doc['pool'];
    final chain = doc['chain'];
    final arc = doc['arc'];
    String? str(Object? m, String k) => m is YamlMap && m[k] != null ? '${m[k]}' : null;
    int? num(Object? m, String k) {
      if (m is! YamlMap || m[k] == null) return null;
      final v = m[k];
      if (v is int && v > 0) return v;
      throw Refusal('config', '$path gives $k as $v, and it is a whole number above zero');
    }

    final peers = chain is YamlMap && chain['peers'] is YamlList
        ? [for (final x in chain['peers'] as YamlList) '$x']
        : const <String>[];
    return CloakConfig(
      network: network,
      server: str(pool, 'server'),
      coordinator: str(pool, 'coordinator'),
      timeout: Duration(seconds: num(pool, 'timeout_seconds') ?? 30),
      peers: peers,
      confirmations: num(chain, 'confirmations'),
      refundMargin: num(doc['deposit'], 'refund_margin') ?? 144,
      refundMinimum: num(doc['deposit'], 'refund_minimum') ?? 100,
      arcUrl: str(arc, 'url'),
    );
  }

  /// The file this config is, with a comment per setting.
  String toYaml() {
    final b = StringBuffer()
      ..writeln('# A cloak wallet\'s settings. Nothing here is secret: the passphrase comes from a prompt')
      ..writeln('# or CLOAK_PASSPHRASE, never from this file.')
      ..writeln('version: $fileVersion')
      ..writeln('network: ${network.name}')
      ..writeln('pool:')
      ..writeln('  # the ricochet server, as a multiaddr ending in /p2p/<peer id>')
      ..writeln('  server: ${server ?? '~'}')
      ..writeln('  # the coordinator\'s peer id; its feed is the pool\'s')
      ..writeln('  coordinator: ${coordinator ?? '~'}')
      ..writeln('  timeout_seconds: ${timeout.inSeconds}')
      ..writeln('chain:')
      ..writeln('  # blocks deep before a payment counts, the block itself counting as one')
      ..writeln('  confirmations: $confirmations');
    if (peers.isEmpty) {
      b.writeln('  peers: []');
    } else {
      b.writeln('  peers:');
      for (final x in peers) {
        b.writeln('    - $x');
      }
    }
    b
      ..writeln('deposit:')
      ..writeln('  # blocks beyond the next round that a deposit\'s refund opens at')
      ..writeln('  refund_margin: $refundMargin')
      ..writeln('  # the fewest blocks past the tip a refund may open at; a coordinator skips a sooner one')
      ..writeln('  refund_minimum: $refundMinimum')
      ..writeln('arc:')
      ..writeln('  url: ${arcUrl ?? '~'}');
    return b.toString();
  }
}
