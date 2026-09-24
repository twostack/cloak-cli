import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart' show RicochetWalletTransport;
import 'package:dart_libp2p/config/config.dart' as p2p_config;
import 'package:dart_libp2p/core/crypto/ed25519.dart' as crypto_ed25519;
import 'package:dart_libp2p/core/crypto/keys.dart';
import 'package:dart_libp2p/core/multiaddr.dart';
import 'package:dart_libp2p/core/network/conn.dart';
import 'package:dart_libp2p/core/network/context.dart' as core_context;
import 'package:dart_libp2p/core/network/stream.dart';
import 'package:dart_libp2p/core/network/transport_conn.dart';
import 'package:dart_libp2p/core/peer/addr_info.dart';
import 'package:dart_libp2p/core/peer/peer_id.dart';
import 'package:dart_libp2p/p2p/host/basic/basic_host.dart';
import 'package:dart_libp2p/p2p/multiaddr/protocol.dart';
import 'package:dart_libp2p/p2p/security/noise/noise_protocol.dart';
import 'package:dart_libp2p/p2p/transport/connection_manager.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/multiplexer.dart';
import 'package:dart_libp2p/p2p/transport/multiplexing/yamux/session.dart';
import 'package:dart_libp2p/p2p/transport/udx_transport.dart';
import 'package:ricochet/protocol/maa/access_handler.dart';
import 'package:ricochet/protocol/msa/submission_handler.dart';
import 'package:ricochet/ricochet.dart';

/// A message taken from the coordinator's submissions folder.
class Submission {
  final String id, sender;
  final Uint8List payload;
  const Submission(this.id, this.sender, this.payload);
}

/// The coordinator's end of ricochet, for the localnet tests that need
/// something to stand where the coordinator stands: its feed, its
/// submissions folder, and its replies to a wallet.
///
/// Written here, against ricochet's protocol and the folder names the wallet
/// uses, rather than borrowed from pool-coordinator: the coordinator is an
/// application of its own, and this package does not depend on it. What
/// crosses the wire is the same: payloads sealed to the recipient and bound to
/// the folder and message id, submissions consumed by marking them delivered
/// and then deleting them.
class CoordinatorEnd {
  final BasicHost host;
  final SFClient client;
  final PeerId serverId;
  final PayloadEncryptor encryptor;

  CoordinatorEnd._(this.host, this.client, this.serverId, this.encryptor);

  String get peerId => host.id.toBase58();

  /// Connects to [server], a multiaddr ending in `/p2p/<peer id>`, as the
  /// identity of [seed].
  static Future<CoordinatorEnd> connect({required Uint8List seed, required String server}) async {
    final serverMa = MultiAddr(server);
    final serverId = PeerId.fromString(serverMa.valueForProtocol(Protocols.p2p.name)!);
    final addr = serverMa.decapsulate(Protocols.p2p.name)!;
    final keyPair = await crypto_ed25519.generateEd25519KeyPairFromSeed(seed);
    final host = await _createHost(keyPair);
    await host.start();
    await host.peerStore.addrBook.addAddr(serverId, addr, const Duration(hours: 24));
    Object? last;
    for (int attempt = 0; attempt < 5; attempt++) {
      try {
        await host.connect(AddrInfo(serverId, [addr]), context: core_context.Context()).timeout(const Duration(seconds: 10));
        last = null;
        break;
      } catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    if (last != null) {
      await host.close();
      throw StateError('the coordinator end could not reach $server: $last');
    }
    host.connManager.protect(serverId, 'coordinator-end');
    final encryptor = PayloadEncryptor.fromEd25519Seed(seed);
    final client = SFClient(
        host: host,
        config: SFClientConfig(preferredServers: [SFServerPreference(serverId: serverId, priority: 10)]),
        encryptor: encryptor);
    client.registerServerAddress(serverId, addr);
    await client.start();
    return CoordinatorEnd._(host, client, serverId, encryptor);
  }

  static Future<BasicHost> _createHost(KeyPair keyPair) async {
    final connMgr = ConnectionManager(idleTimeout: const Duration(seconds: 60));
    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connMgr),
      p2p_config.Libp2p.transport(UDXTransport(connManager: connMgr)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.muxer('/yamux/1.0.0', (Conn secureConn, bool isClient) {
        if (secureConn is! TransportConn) throw ArgumentError('yamux expects a TransportConn');
        return YamuxSession(secureConn, MultiplexerConfig(maxStreams: 256), isClient, null);
      }),
      p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/0/udx')]),
    ];
    return await p2p_config.Libp2p.new_(options) as BasicHost;
  }

  /// Runs [fn] on a fresh stream to the server, closed after, so a thousand
  /// calls never exhaust the session's streams.
  Future<T> _stream<T>(String protocol, Future<T> Function(P2PStream s) fn) async {
    final stream = await host.newStream(serverId, [protocol], core_context.Context());
    try {
      return await fn(stream).timeout(const Duration(seconds: 30));
    } finally {
      if (!stream.isClosed) {
        try {
          await stream.close();
        } catch (_) {}
      }
    }
  }

  /// Creates the rounds feed, unless it exists.
  Future<void> ensureFeed() async {
    final path = RicochetWalletTransport.feedPath;
    if (await client.getFeed(ownerPeerId: host.id, path: path) != null) return;
    final r = await client.createFeed(path: path, title: 'pool rounds', description: 'a stand-in coordinator\'s feed');
    if (r == null) throw StateError('the ricochet server did not create the feed');
  }

  /// How many entries the feed holds.
  Future<int> feedLength() async =>
      (await client.getFeed(ownerPeerId: host.id, path: RicochetWalletTransport.feedPath))?.currentSequence ?? 0;

  /// Appends [bytes] to the feed, and returns its sequence number.
  Future<int> announce(Uint8List bytes) async {
    final r = await client.appendFeedEntry(path: RicochetWalletTransport.feedPath, content: bytes, entryType: 'pool');
    if (r == null) throw StateError('the feed append failed');
    return r.sequence;
  }

  /// What waits in the submissions folder, each payload opened when it was
  /// sealed to this identity and handed over as it is otherwise.
  Future<List<Submission>> drain() async {
    final response = await _stream(AccessHandler.protocolId,
        (s) => AccessHandler.retrieveMessages(s, host.id, folderPath: RicochetWalletTransport.submissionsFolder, maxMessages: 100));
    final out = <Submission>[];
    for (final m in response.messages) {
      var payload = m.payload;
      if (m.flags.isEncrypted) {
        try {
          payload = (await openIfEncrypted(m, encryptor)).payload;
        } on PayloadDecryptException {
          // not sealed to this identity: handed over as it is
        }
      }
      out.add(Submission(m.messageId, m.senderPeerId.toBase58(), payload));
    }
    return out;
  }

  /// Consumes [ids]: marked delivered, then deleted, since the server keeps a
  /// persistent message after it is marked.
  Future<void> delivered(List<String> ids) async {
    if (ids.isEmpty) return;
    final folder = RicochetWalletTransport.submissionsFolder;
    final ack = await _stream(AccessHandler.protocolId, (s) => AccessHandler.markDelivered(s, ids, folderPath: folder));
    if (!ack.success) throw StateError('mark delivered: ${ack.errorMessage}');
    final gone = await _stream(AccessHandler.protocolId, (s) => AccessHandler.deleteMessages(s, ids));
    if (!gone.success) throw StateError('delete: ${gone.errorMessage}');
  }

  /// Sends [bytes] to [peerId]'s replies folder, sealed to it.
  Future<void> reply(String peerId, Uint8List bytes) async {
    final to = PeerId.fromString(peerId);
    final folder = RicochetWalletTransport.repliesFolder;
    final messageId = _uuid();
    final sealed = await encryptor.encryptBound(
        bytes, PayloadBinding.forMessage(recipientPeerId: to, folderPath: folder, messageId: messageId), to);
    final ack = await _stream(
        SubmissionHandler.protocolId,
        (s) => SubmissionHandler.submitMessage(s, to, sealed,
            folderPath: folder, persistent: true, messageId: messageId, flags: SFMessageFlags.none.withFlag(SFMessageFlags.encrypted)));
    if (!ack.success) throw StateError('reply to $peerId: ${ack.errorMessage}');
  }

  Future<void> close() async {
    try {
      await client.stop();
    } catch (_) {}
    try {
      await host.close();
    } catch (_) {}
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
