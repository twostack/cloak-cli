import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

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
import 'package:libcloak/libcloak.dart';
import 'package:logging/logging.dart';
import 'package:ricochet/protocol/maa/access_frame.dart';
import 'package:ricochet/protocol/maa/access_handler.dart';
import 'package:ricochet/protocol/msa/submission_handler.dart';
import 'package:ricochet/ricochet.dart' hide FeedEntry;
import 'package:tstokenlib/tstokenlib.dart' show PoolMessage;

/// Reads one length-prefixed frame, refusing its declared length against
/// [max] before a byte of the body is read.
///
/// Ricochet's own reader takes a four-byte length and reads whatever it says,
/// so a server that declares four gigabytes gets four gigabytes allocated.
/// This one reads the four bytes, compares, and either reads the body or
/// throws naming both sizes, having allocated nothing of the declared size.
class BoundedFrames {
  static Future<Uint8List> read(Future<Uint8List> Function(int n) readSome, int max, {required String what}) async {
    final length = ByteData.sublistView(await _exact(readSome, 4)).getUint32(0);
    if (length > max) {
      throw FrameTooLong(what, length, max);
    }
    return _exact(readSome, length);
  }

  static Future<Uint8List> _exact(Future<Uint8List> Function(int n) readSome, int length) async {
    final out = BytesBuilder(copy: false);
    while (out.length < length) {
      final chunk = await readSome(length - out.length);
      if (chunk.isEmpty) throw StateError('the stream closed after ${out.length} of $length bytes');
      out.add(chunk);
    }
    return out.takeBytes();
  }

  static Uint8List frame(Uint8List body) {
    final out = Uint8List(4 + body.length);
    ByteData.sublistView(out).setUint32(0, body.length);
    out.setRange(4, out.length, body);
    return out;
  }
}

/// The two things a wallet reads from its mailbox that libcloak's transport
/// port does not: replies an earlier run gave up waiting for, and the notices
/// the coordinator sends unasked. Both are frames, handed over undecoded; the
/// command that asked for them decodes them.
abstract interface class PoolMailbox {
  /// Every reply waiting in this identity's replies folder, taken out of it.
  Future<List<List<int>>> drainReplies();

  /// Every notice waiting in this identity's notices folder, taken out of it.
  Future<List<List<int>>> readNotices();
}

/// A frame whose declared length was over the bound for its kind.
class FrameTooLong implements Exception {
  final String what;
  final int declared, max;
  const FrameTooLong(this.what, this.declared, this.max);
  @override
  String toString() => '$what declares $declared bytes and the most this wallet reads is $max; it was discarded unread';
}

/// libcloak's transport over ricochet: the wallet's half of the pipe the
/// coordinator's side already speaks, built on the ricochet client alone.
///
/// A frame is sealed to the coordinator and stored in its submissions folder;
/// replies come back to this identity's replies folder; the feed is read by
/// sequence under the coordinator's peer id. The only libp2p connection is to
/// the one configured ricochet server.
///
/// Nothing here knows what a frame means. libcloak's client decodes every one
/// as hostile input and matches a reply to its submission **by id**, which is
/// why this hands back whichever reply arrived first and keeps the rest.
///
/// Two details are kept from the implementation this replaces, because both
/// were learned the expensive way. Replies are buffered, because the folder
/// marks what it hands over as delivered and a reply not kept is a reply
/// nobody sees again. And ricochet numbers a feed from one, while libcloak
/// asks from zero before it has read anything.
///
/// And one is new. Once a frame has been stored, a reply that does not come is
/// never reported as a transport failure: libcloak counts a failure as "never
/// sent" and would release the note. This waits instead, and libcloak's own
/// deadline turns the wait into "no answer", which leaves the note reserved.
class RicochetWalletTransport implements Transport, PoolMailbox {
  static const submissionsFolder = 'pool/submissions';
  static const repliesFolder = 'pool/replies';

  /// Where the coordinator puts what nobody asked for: the mined-round notice,
  /// and the `expired` word on a transfer it accepted and later dropped.
  /// Kept apart from [repliesFolder], which holds only answers, because a
  /// transport that hands back whatever arrived next would otherwise hand a
  /// notice to whichever call was waiting.
  static const noticesFolder = 'pool/notices';
  static const feedPath = 'pool/rounds';

  /// A reply is at most the largest pool message, and a sealed message with
  /// its envelope is that plus room for the envelope.
  static const envelope = 64 * 1024;
  static const maxReplyFrame = PoolMessage.maxCatchUp + envelope;

  /// A feed entry is a descriptor or an announcement, each at most
  /// [PoolMessage.maxOther]; in the feed's JSON it is base64, a third larger.
  static const maxFeedEntry = PoolMessage.maxOther;
  static int maxFeedFrame(int entries) => entries * (maxFeedEntry * 2 + 512) + envelope;

  static final Logger _log = Logger('cloak.transport');

  final BasicHost host;
  final PeerId server, coordinator;
  final PayloadEncryptor encryptor;
  final Duration timeout;
  final Zone _zone;
  SFClient? _client;

  /// Replies drained from the folder that no call has taken yet. Each is an
  /// answer to a request that stopped waiting, which only [drainReplies]
  /// hands over: a request is answered only by what arrives after it went.
  final List<Uint8List> _spare = [];

  /// What was discarded and why, for a person who asks.
  final List<String> discarded = [];

  RicochetWalletTransport._(this.host, this.server, this.coordinator, this.encryptor, this.timeout, this._zone);

  /// Connects to [server], a multiaddr ending in `/p2p/<peer id>`, as the
  /// identity [seed], to talk to the pool whose coordinator is [coordinator].
  static Future<RicochetWalletTransport> connect({
    required Uint8List seed,
    required String server,
    required String coordinator,
    required Duration timeout,
    int attempts = 3,
  }) async {
    final ma = MultiAddr(server);
    final serverPeer = ma.valueForProtocol(Protocols.p2p.name);
    if (serverPeer == null) {
      throw Refusal('config', 'pool.server is $server, and a ricochet server is named by an address ending in /p2p/<peer id>');
    }
    final serverId = PeerId.fromString(serverPeer);
    final PeerId coordinatorId;
    try {
      coordinatorId = PeerId.fromString(coordinator);
    } catch (_) {
      throw Refusal('config', 'pool.coordinator is "$coordinator", which is not a peer id');
    }
    final addr = ma.decapsulate(Protocols.p2p.name)!;

    // the transport stack throws on futures nobody awaits when a connection
    // dies mid-dial; in this zone those are logged, not fatal
    late final Zone zone;
    final ready = Completer<void>();
    runZonedGuarded(() {
      zone = Zone.current;
      ready.complete();
    }, (e, st) => _log.fine('stray error in the transport stack: $e'));
    await ready.future;

    final keyPair = await crypto_ed25519.generateEd25519KeyPairFromSeed(seed);
    final host = await zone.run(() => _createHost(keyPair));
    await zone.run(() => host.start());
    await host.peerStore.addrBook.addAddr(serverId, addr, const Duration(hours: 1));
    Object? last;
    for (int i = 1; i <= attempts; i++) {
      try {
        await zone.run(() => host.connect(AddrInfo(serverId, [addr]), context: core_context.Context()).timeout(timeout));
        last = null;
        break;
      } catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (last != null) {
      await host.close();
      throw TransportFailure('connect', 'could not reach the ricochet server at $server: $last');
    }
    host.connManager.protect(serverId, 'cloak-pool-server');
    return RicochetWalletTransport._(
        host, serverId, coordinatorId, PayloadEncryptor.fromEd25519Seed(seed), timeout, zone);
  }

  static Future<BasicHost> _createHost(KeyPair keyPair) async {
    final connMgr = ConnectionManager(idleTimeout: const Duration(seconds: 60));
    final yamux = MultiplexerConfig(
      keepAliveInterval: const Duration(seconds: 60),
      maxStreamWindowSize: 1024 * 1024,
      initialStreamWindowSize: 256 * 1024,
      streamWriteTimeout: const Duration(seconds: 30),
      maxStreams: 256,
    );
    final options = <p2p_config.Option>[
      p2p_config.Libp2p.identity(keyPair),
      p2p_config.Libp2p.connManager(connMgr),
      p2p_config.Libp2p.transport(UDXTransport(connManager: connMgr)),
      p2p_config.Libp2p.security(await NoiseSecurity.create(keyPair)),
      p2p_config.Libp2p.muxer('/yamux/1.0.0', (Conn secureConn, bool isClient) {
        if (secureConn is! TransportConn) throw ArgumentError('yamux expects a TransportConn');
        return YamuxSession(secureConn, yamux, isClient, null);
      }),
      p2p_config.Libp2p.listenAddrs([MultiAddr('/ip4/0.0.0.0/udp/0/udx')]),
    ];
    return await p2p_config.Libp2p.new_(options) as BasicHost;
  }

  /// This wallet's identity on the transport.
  String get peerId => host.id.toBase58();

  Future<T> _guarded<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _zone.run(() => f().then(c.complete, onError: (Object e, StackTrace st) => c.completeError(e, st)));
    return c.future;
  }

  Future<T> _stream<T>(String protocol, Future<T> Function(P2PStream s) fn) async {
    final stream = await host.newStream(server, [protocol], core_context.Context()).timeout(timeout);
    try {
      return await fn(stream).timeout(timeout * 2);
    } finally {
      if (!stream.isClosed) {
        try {
          await stream.close();
        } catch (_) {}
      }
    }
  }

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) =>
      _guarded(() => _request(Uint8List.fromList(frame), timeout));

  Future<List<int>> _request(Uint8List frame, Duration timeout) async {
    // a reply kept from before is no answer to this frame, and handing it
    // back in place of sending would drop the frame unsent
    final earlier = _spare.length;
    // the caller stops waiting at twice its timeout from now; a reply drained
    // after that is kept for drainReplies, not handed to a call nobody awaits
    const margin = Duration(milliseconds: 500);
    final deadline = DateTime.now().add(timeout * 2 - (timeout < margin ? timeout ~/ 2 : margin));
    await _submit(frame);
    // stored: from here a missing reply is a wait, never a failure
    while (DateTime.now().isBefore(deadline)) {
      await _drainInto(_spare);
      if (_spare.length > earlier && DateTime.now().isBefore(deadline)) return _spare.removeAt(earlier);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return Completer<List<int>>().future;
  }

  Future<void> _submit(Uint8List frame) async {
    final messageId = _uuid();
    final sealed = await encryptor.encryptBound(
        frame,
        PayloadBinding.forMessage(recipientPeerId: coordinator, folderPath: submissionsFolder, messageId: messageId),
        coordinator);
    final StoreAck ack;
    try {
      ack = await _stream(
          SubmissionHandler.protocolId,
          (s) => SubmissionHandler.submitMessage(s, coordinator, sealed,
              folderPath: submissionsFolder,
              persistent: true,
              messageId: messageId,
              flags: SFMessageFlags.none.withFlag(SFMessageFlags.encrypted)));
    } catch (e) {
      throw TransportFailure('request', 'the frame was not stored: $e');
    }
    if (!ack.success) throw TransportFailure('request', 'the server did not store the frame: ${ack.errorMessage}');
  }

  @override
  Future<List<List<int>>> drainReplies() => _guarded(() async {
        final out = <Uint8List>[..._spare];
        _spare.clear();
        var last = -1;
        while (out.length != last) {
          last = out.length;
          await _drainInto(out);
        }
        return out;
      });

  @override
  Future<List<List<int>>> readNotices() => _guarded(() async {
        final out = <Uint8List>[];
        var last = -1;
        while (out.length != last) {
          last = out.length;
          await _drainInto(out, folder: noticesFolder);
        }
        return out;
      });

  Future<void> _drainInto(List<Uint8List> into, {String folder = repliesFolder}) async {
    final RetrieveMessagesResponse response;
    try {
      response = await _stream(AccessHandler.protocolId, (s) async {
        await s.write(BoundedFrames.frame(AccessFrame.encodeRetrieveRequest(
            RetrieveMessagesRequest(peerId: host.id, folderPath: folder, maxMessages: 1))));
        return AccessFrame.decodeRetrieveResponse(
            await BoundedFrames.read(s.read, maxReplyFrame, what: 'a reply from the pool'));
      });
    } on FrameTooLong catch (e) {
      discarded.add('$e');
      _log.warning('$e');
      return;
    } catch (e) {
      _log.fine('reading replies: $e');
      return;
    }
    final ids = <String>[];
    for (final m in response.messages) {
      ids.add(m.messageId);
      var payload = m.payload;
      if (m.flags.isEncrypted) {
        try {
          payload = (await openIfEncrypted(m, encryptor)).payload;
        } on PayloadDecryptException {
          discarded.add('a reply not sealed to this wallet, from ${m.senderPeerId.toBase58()}');
          continue;
        }
      }
      if (m.senderPeerId != coordinator) {
        discarded.add('a reply from ${m.senderPeerId.toBase58()}, which is not the coordinator');
        continue;
      }
      into.add(payload);
    }
    if (ids.isNotEmpty) {
      try {
        await _stream(AccessHandler.protocolId, (s) => AccessHandler.markDelivered(s, ids, folderPath: folder));
        await _stream(AccessHandler.protocolId, (s) => AccessHandler.deleteMessages(s, ids));
      } catch (e) {
        _log.fine('marking replies delivered: $e');
      }
    }
  }

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) => _guarded(() => _readFeed(from, max));

  Future<List<FeedEntry>> _readFeed(int from, int max) async {
    final FeedFrameResponse response;
    try {
      response = await _stream(FeedHandler.protocolId, (s) async {
        await s.write(BoundedFrames.frame(FeedFrame.encodeRequest(
            operation: 'GET',
            ownerPeerId: coordinator,
            path: feedPath,
            // ricochet numbers a feed from 1; libcloak asks from 0 first
            fromSequence: from < 1 ? 1 : from,
            limit: max)));
        return FeedFrame.decodeResponse(await BoundedFrames.read(s.read, maxFeedFrame(max), what: 'a feed read'));
      });
    } on FrameTooLong catch (e) {
      discarded.add('$e');
      throw TransportFailure('readFeed', '$e');
    } catch (e) {
      throw TransportFailure('readFeed', '$e');
    }
    if (!response.isSuccess) {
      // a feed that does not exist yet is an empty one
      if (response.status == 404) return const [];
      throw TransportFailure('readFeed', 'the server answered ${response.status}');
    }
    final body = jsonDecode(utf8.decode(response.body ?? const [])) as Map<String, dynamic>;
    final out = <FeedEntry>[];
    for (final e in (body['entries'] as List<dynamic>? ?? const [])) {
      final entry = e as Map<String, dynamic>;
      final seq = entry['seq'] as int;
      final text = entry['content'] as String? ?? '';
      // bounded before it is decoded: base64 is four characters for three
      // bytes, so the length is known without allocating the bytes
      final declared = text.length * 3 ~/ 4;
      if (declared > maxFeedEntry) {
        discarded.add('feed entry $seq declares about $declared bytes and a pool message on the feed is at most '
            '$maxFeedEntry; discarded unread');
        out.add(FeedEntry(seq, const []));
        continue;
      }
      out.add(FeedEntry(seq, base64Decode(text)));
    }
    return out;
  }

  static String _uuid() {
    final r = Random.secure();
    final b = List.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  Future<void> close() => _guarded(() async {
        try {
          await _client?.stop();
        } catch (_) {}
        try {
          await host.close();
        } catch (_) {}
      });
}
