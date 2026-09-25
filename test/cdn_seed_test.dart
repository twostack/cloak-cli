import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:crypto/crypto.dart';
import 'package:libcloak/libcloak.dart' show Refusal;
import 'package:libspiffy/libspiffy.dart' show CdnSyncPhase;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:spiffynode/spiffy_node.dart' show BlockHeader;
import 'package:test/test.dart';

import 'support/isar_core.dart';
import 'support/regtest_headers.dart';

/// An empty header store is seeded from a CDN, and a CDN that cannot be used
/// is said so, with its reason, rather than left to look like a slow peer
/// sync.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('cloak-cdn'));
  tearDown(() => root.deleteSync(recursive: true));

  WalletDir wallet() {
    final dir = WalletDir(p.join(root.path, 'w'), DirSource.argument);
    Directory(dir.chain).createSync(recursive: true);
    return dir;
  }

  group('chain.cdn in config.yaml', () {
    Future<CloakConfig> load(String network, [String? cdn]) async {
      final f = File(p.join(root.path, 'config.yaml'))
        ..writeAsStringSync('version: 1\nnetwork: $network\nchain:\n${cdn == null ? '' : '  cdn: $cdn\n'}');
      return CloakConfig.load(f.path);
    }

    test('mainnet and testnet seed from the built-in CDN; regtest from none', () async {
      expect((await load('mainnet')).cdnUrl, CloakConfig.defaultCdn);
      expect((await load('testnet')).cdnUrl, CloakConfig.defaultCdn);
      expect((await load('regtest')).cdnUrl, isNull);
    });

    test('another https CDN, or none', () async {
      expect((await load('testnet', 'https://headers.example.org')).cdnUrl, 'https://headers.example.org');
      expect((await load('testnet', 'none')).cdnUrl, isNull);
    });

    test('a plaintext or malformed CDN is refused at load', () async {
      for (final bad in ['http://headers.example.org', 'headers.example.org', 'https://']) {
        await expectLater(
            load('testnet', bad),
            throwsA(isA<Refusal>()
                .having((r) => r.step, 'step', 'config')
                .having((r) => r.reason, 'reason', allOf(contains(bad), contains('https')))),
            reason: bad);
      }
    });

    test('the file cloak init writes says the CDN, and reads back the same', () async {
      for (final c in [
        CloakConfig(network: CloakNetwork.testnet),
        CloakConfig(network: CloakNetwork.mainnet, cdn: CloakConfig.noCdn),
        CloakConfig(network: CloakNetwork.regtest),
      ]) {
        final f = File(p.join(root.path, 'config.yaml'))..writeAsStringSync(c.toYaml());
        expect(f.readAsStringSync(), contains('  cdn: ${c.cdn}\n'));
        expect((await CloakConfig.load(f.path)).cdnUrl, c.cdnUrl);
      }
    });
  });

  group('what a seed says', () {
    const url = 'https://headers.example.org';

    test('a fallback is said with its reason, whatever the verbosity, and the store is not marked', () async {
      final dir = wallet();
      final out = StringBuffer();
      final seed = CdnSeed(url, out)
        ..onProgress(0, 0, CdnSyncPhase.fetchingManifest)
        ..onLog(LogRecord(Level.WARNING, 'CDN header sync failed: Exception: Failed to fetch manifest: HTTP 404',
            'CdnHeaderSyncService'))
        ..onProgress(0, 0, CdnSyncPhase.fallbackToP2P);
      seed.sayFallback();
      await seed.finish(dir, 0);
      expect('$out', contains('the header CDN at $url could not be used (Failed to fetch manifest: HTTP 404)'));
      expect('$out', contains('headers come from peers instead'));
      expect('$out', contains('chain.cdn: none'));
      expect(CdnSeed.urlFor(dir, CloakConfig(network: CloakNetwork.testnet, cdn: url)), url,
          reason: 'the next start tries again');
    });

    test('a fallback whose reason was not logged is still said', () async {
      final out = StringBuffer();
      final seed = CdnSeed(url, out)
        ..onLog(LogRecord(Level.WARNING, 'something else entirely', 'CdnHeaderSyncService'))
        ..onLog(LogRecord(Level.WARNING, 'CDN header sync failed: from another logger', 'Elsewhere'))
        ..onProgress(0, 0, CdnSyncPhase.fallbackToP2P);
      seed.sayFallback();
      expect('$out', contains('the header CDN at $url could not be used; headers come from peers'));
    });

    test('progress is said per chunk imported, and when all are in', () {
      final out = StringBuffer();
      CdnSeed(url, out)
        ..onProgress(0, 0, CdnSyncPhase.fetchingManifest)
        ..onProgress(0, 1719437, CdnSyncPhase.downloadingChunks)
        ..onProgress(0, 1719437, CdnSyncPhase.validatingChunks)
        ..onProgress(400000, 1719437, CdnSyncPhase.importingHeaders)
        ..onProgress(1719437, 1719437, CdnSyncPhase.complete);
      expect(const LineSplitter().convert('$out'), [
        'cloak: chain: asking $url for headers',
        'cloak: chain: headers from $url: 400,000 of 1,719,437',
        'cloak: chain: headers from $url: 1,719,437 of 1,719,437'
      ]);
    });

    test('a seed marks the store, and a marked store is not seeded again', () async {
      final dir = wallet();
      final config = CloakConfig(network: CloakNetwork.testnet, cdn: url);
      expect(CdnSeed.urlFor(dir, config), url);
      await (CdnSeed(url, null)..onProgress(0, 0, CdnSyncPhase.fetchingManifest)).finish(dir, 30);
      expect(File(p.join(dir.chain, CdnSeed.markFile)).readAsStringSync(), '$url\n30\n');
      expect(CdnSeed.urlFor(dir, config), isNull);
    });

    test('a start that never asked the CDN marks nothing', () async {
      final dir = wallet();
      await CdnSeed(url, null).finish(dir, 0);
      expect(File(p.join(dir.chain, CdnSeed.markFile)).existsSync(), isFalse);
    });
  });

  group('through libspiffy, from a CDN on this machine', () {
    late _Cdn cdn;
    HttpOverrides? previous;
    setUpAll(() async {
      await startIsar();
      cdn = await _Cdn.start(RegtestHeaders.mine(30), chunk: 12);
      previous = HttpOverrides.current;
      HttpOverrides.global = _TrustThisMachine();
    });
    tearDownAll(() async {
      HttpOverrides.global = previous;
      await cdn.close();
    });
    setUp(() => cdn.reset());

    CloakConfig config() => CloakConfig(network: CloakNetwork.regtest, cdn: cdn.url);

    test('An empty store is seeded, said as it goes, and not asked again', () async {
      final dir = wallet();
      final out = StringBuffer();
      final chain = await SpiffyChain.start(dir, config(), progress: out);
      expect((await chain.headers.tip()).height, 30, reason: '$out');
      await chain.stop();
      expect('$out', contains('cloak: chain: headers from ${cdn.url}: 30 of 30'));
      expect('$out', isNot(contains('could not be used')));
      expect(cdn.requests, ['manifest.json', 'chunk0.bin', 'chunk1.bin', 'chunk2.bin']);

      cdn.reset();
      final again = await SpiffyChain.start(dir, config(), progress: out);
      expect((await again.headers.tip()).height, 30);
      await again.stop();
      expect(cdn.requests, isEmpty, reason: 'a seeded store makes no request to the CDN');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('A CDN that failed is said even when the start then fails for its peers', () async {
      final dir = wallet();
      final out = StringBuffer();
      cdn.fault = _Fault.noManifest;
      // a peer nobody listens on, so the start refuses after the CDN failed
      final withPeer = CloakConfig(network: CloakNetwork.regtest, cdn: cdn.url, peers: const ['127.0.0.1:1']);
      await expectLater(SpiffyChain.start(dir, withPeer, progress: out),
          throwsA(isA<Refusal>().having((r) => r.step, 'step', 'chain')));
      expect('$out', contains('the header CDN at ${cdn.url} could not be used (Failed to fetch manifest: HTTP 404)'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    for (final (what, fault, reason) in [
      ('a CDN with no manifest', _Fault.noManifest, 'Failed to fetch manifest: HTTP 404'),
      ('a chunk that is not what the manifest says', _Fault.damagedChunk, 'Chunk integrity check failed'),
    ]) {
      test('$what is said, and tried again on the next start', () async {
        final dir = wallet();
        final out = StringBuffer();
        cdn.fault = fault;
        final chain = await SpiffyChain.start(dir, config(), progress: out);
        await chain.stop();
        expect('$out', contains('the header CDN at ${cdn.url} could not be used ('));
        expect('$out', contains(reason));
        expect(File(p.join(dir.chain, CdnSeed.markFile)).existsSync(), isFalse);

        cdn.reset();
        final again = await SpiffyChain.start(dir, config(), progress: out);
        expect((await again.headers.tip()).height, 30, reason: '$out');
        await again.stop();
        expect(File(p.join(dir.chain, CdnSeed.markFile)).existsSync(), isTrue);
      }, timeout: const Timeout(Duration(minutes: 2)));
    }
  }, skip: _openssl() ? null : 'needs openssl to make the test CDN\'s certificate');
}

enum _Fault { none, noManifest, damagedChunk }

/// A header CDN laid out as libspiffy reads one, over https with a
/// certificate made for the run.
class _Cdn {
  final HttpServer _server;
  final Directory _certs;
  final List<Uint8List> _chunks;
  final String _manifest;
  final List<String> requests = [];
  _Fault fault = _Fault.none;

  _Cdn._(this._server, this._certs, this._chunks, this._manifest);

  String get url => 'https://localhost:${_server.port}';

  void reset() {
    requests.clear();
    fault = _Fault.none;
  }

  static Future<_Cdn> start(List<BlockHeader> headers, {required int chunk}) async {
    final certs = Directory.systemTemp.createTempSync('cloak-cdn-cert');
    final r = Process.runSync('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', //
      '-keyout', p.join(certs.path, 'key.pem'), '-out', p.join(certs.path, 'cert.pem'),
    ]);
    if (r.exitCode != 0) throw StateError('openssl: ${r.stderr}');
    final context = SecurityContext()
      ..useCertificateChain(p.join(certs.path, 'cert.pem'))
      ..usePrivateKey(p.join(certs.path, 'key.pem'));

    final chunks = <Uint8List>[], entries = <Map<String, Object>>[];
    for (int i = 0; i < headers.length; i += chunk) {
      final part = headers.sublist(i, i + chunk > headers.length ? headers.length : i + chunk);
      final bytes = Uint8List.fromList([for (final h in part) ...h.serialize()]);
      entries.add({
        'filename': 'chunk${chunks.length}.bin',
        'startHeight': i + 1,
        'endHeight': i + part.length,
        'headerCount': part.length,
        'sha256': '${sha256.convert(bytes)}',
        'sizeBytes': bytes.length,
      });
      chunks.add(bytes);
    }
    final manifest = jsonEncode({
      'version': 1,
      'network': 'regtest',
      'generatedAt': '2026-09-25T00:00:00Z',
      'totalHeaders': headers.length,
      'chunkSize': chunk,
      'headerSizeBytes': 80,
      'chunks': entries,
    });
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    final cdn = _Cdn._(server, certs, chunks, manifest);
    server.listen(cdn._serve);
    return cdn;
  }

  void _serve(HttpRequest q) {
    final name = q.uri.pathSegments.last;
    requests.add(name);
    final res = q.response;
    if (q.uri.pathSegments.first != 'regtest') {
      res.statusCode = HttpStatus.notFound;
    } else if (name == 'manifest.json') {
      if (fault == _Fault.noManifest) {
        res.statusCode = HttpStatus.notFound;
      } else {
        res.write(_manifest);
      }
    } else {
      final i = int.tryParse(name.replaceAll(RegExp(r'\D'), ''));
      if (i == null || i >= _chunks.length) {
        res.statusCode = HttpStatus.notFound;
      } else {
        final bytes = Uint8List.fromList(_chunks[i]);
        if (fault == _Fault.damagedChunk) bytes[40] ^= 1;
        res.add(bytes);
      }
    }
    res.close();
  }

  Future<void> close() async {
    await _server.close(force: true);
    _certs.deleteSync(recursive: true);
  }
}

/// Takes the test CDN's certificate, and only on this machine.
class _TrustThisMachine extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..badCertificateCallback = (cert, host, port) => host == 'localhost';
}

bool _openssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}
