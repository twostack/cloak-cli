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

  /// The header CDN a mainnet or testnet wallet is seeded from unless its
  /// config names another.
  static const defaultCdn = 'https://headers.overnode.net';

  /// The service `cloak receive --txid` asks for a transaction's BEEF unless
  /// the config names another. It serves mainnet and testnet from one address.
  static const defaultBeefService = 'https://beef.xn--nda.network';

  /// What `chain.cdn` says to seed from no CDN. A regtest chain is local and
  /// has none.
  static const noCdn = 'none';

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

  /// Where a header store is seeded from before peers are asked, as an https
  /// URL, or [noCdn]. Peers drop a connection after about 200,000 headers, so
  /// an empty store is filled from the CDN and only the headers past the
  /// CDN's tip come from peers.
  final String cdn;

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

  /// Where `cloak receive --txid` asks for a transaction's BEEF.
  final String beefUrl;

  const CloakConfig({
    required this.network,
    this.server,
    this.coordinator,
    this.timeout = const Duration(seconds: 30),
    this.peers = const [],
    String? cdn,
    int? confirmations,
    this.refundMargin = 144,
    this.refundMinimum = 100,
    this.arcUrl,
    this.beefUrl = defaultBeefService,
  })  : cdn = cdn ?? (network == CloakNetwork.regtest ? noCdn : defaultCdn),
        confirmations = confirmations ?? (network == CloakNetwork.regtest ? 1 : 6);

  /// Whether the pool has been named. A wallet can exist before it has.
  bool get hasPool => server != null && coordinator != null;

  /// An https URL, or a plain http one on this machine, which is how a test
  /// stands a service up.
  static bool _secureOrLocal(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return true;
    return uri.scheme == 'http' && (uri.host == '127.0.0.1' || uri.host == 'localhost' || uri.host == '::1');
  }

  /// The CDN to seed headers from, or null for none.
  String? get cdnUrl => cdn == noCdn ? null : cdn;

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
    final cdn = str(chain, 'cdn');
    if (cdn != null && cdn != noCdn) {
      final uri = Uri.tryParse(cdn);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw Refusal('config',
            '$path gives chain.cdn as $cdn, and it is an https URL or $noCdn: headers from a plaintext CDN '
            'are chosen by whoever is on the path');
      }
    }
    final beefUrl = str(doc['beef'], 'url');
    if (beefUrl != null && !_secureOrLocal(beefUrl)) {
      throw Refusal('config',
          '$path gives beef.url as $beefUrl, and it is an https URL: what comes back is checked, but whoever is on '
          'the path of a plaintext one learns which transaction you asked about');
    }
    return CloakConfig(
      network: network,
      server: str(pool, 'server'),
      coordinator: str(pool, 'coordinator'),
      timeout: Duration(seconds: num(pool, 'timeout_seconds') ?? 30),
      peers: peers,
      cdn: cdn,
      confirmations: num(chain, 'confirmations'),
      refundMargin: num(doc['deposit'], 'refund_margin') ?? 144,
      refundMinimum: num(doc['deposit'], 'refund_minimum') ?? 100,
      arcUrl: str(arc, 'url'),
      beefUrl: beefUrl ?? defaultBeefService,
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
      ..writeln('  confirmations: $confirmations')
      ..writeln('  # where an empty header store is filled from before peers are asked; https, or $noCdn')
      ..writeln('  cdn: $cdn');
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
      ..writeln('  url: ${arcUrl ?? '~'}')
      ..writeln('beef:')
      ..writeln('  # asked for a transaction\'s BEEF by cloak receive --txid, and only then')
      ..writeln('  url: $beefUrl');
    return b.toString();
  }
}
