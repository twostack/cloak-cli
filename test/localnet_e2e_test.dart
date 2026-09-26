@Tags(['localnet', 'e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloak_cli/cloak_cli.dart';
import 'package:convert/convert.dart';
import 'package:dartsv/dartsv.dart';
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/libspiffy.dart' show BEEF, BUMP, NodeRpcDataSource;
import 'package:test/test.dart';

import 'support/harness.dart' show Ran, passphraseEnv;
import 'support/ricochet_server.dart';

/// The whole of it on localnet: a pool issued and run by the real
/// coordinator over a real ricochet server, and cloak wallets that reach it
/// only by their own command lines, with the real ports: libspiffy's header
/// chain and transparent wallet against the regtest node and ARC, and the
/// ricochet transport.
///
/// One wallet takes coins in from the node as a BEEF, deposits them, and a
/// round takes the deposit in; it pays another wallet out of the deposited
/// note, and the payee checks the proof against its own headers and
/// acknowledges; it withdraws to an address of the node's. A third wallet
/// deposits and never submits, and takes the deposit back at its refund
/// height.
///
/// The coordinator is the real one, run as its own program from a checkout of
/// pool-coordinator (`../pool-coordinator`, or wherever POOL_COORDINATOR
/// says), built here with `dart build cli`: two applications that meet only
/// over the protocol, as they do in the world, and neither a dependency of the
/// other.
///
/// Off unless the localnet harness is up and the run is asked for:
///
///   POOL_LOCALNET=1 POOL_E2E=1 dart test -t e2e test/localnet_e2e_test.dart
///
/// It stands up a coordinator and a miner and proves three rounds, which in
/// the default pack would skew every measured bound in it, so it is asked
/// for on its own, as libcloak's is.
void main() async {
  final env = Platform.environment;
  final skip = env['POOL_LOCALNET'] == null
      ? 'needs ../localnet up; set POOL_LOCALNET=1'
      : env['POOL_E2E'] == null
          ? 'runs a coordinator and a miner, so it is asked for on its own; set POOL_E2E=1'
          : await _localnetProblem() ?? await RicochetTestServer.available() ?? _coordinatorProblem();

  group('cloak on localnet, against the real coordinator', () {
    late RicochetTestServer ricochet;
    late Directory root;
    late Timer miner;
    late Process server;
    final serverOutput = StringBuffer();
    var stopping = false;
    final timings = <String, int>{};
    final serverPassphrase = 'cloak e2e coordinator passphrase';

    late _Wallet depositor, payee, refunder;

    setUpAll(() async {
      ricochet = (await RicochetTestServer.start())!;
      if (!await _findArc()) fail('ARC stopped answering once ricochet started');
      root = Directory.systemTemp.createTempSync('cloak-e2e');
      await _Wallet.build(root);
      // localnet's autominer mines every ten minutes; this mines every four
      // seconds, slow enough that a command's chain settles between blocks
      miner = Timer.periodic(const Duration(seconds: 4), (_) => _mine().catchError((_) => ''));

      // ---- the pool: issued from nothing, then run
      final configPath = '${root.path}/pool/config.yaml';
      Directory('${root.path}/pool').createSync();
      File(configPath).writeAsStringSync('''
plan: test
network: test
chain:
  kind: node
  rpc_url: $_rpcUrl
  rpc_user: bitcoin
ricochet:
  server: ${ricochet.address}
  identity_file: identity.seed
wallet:
  file: wallet.enc
store:
  directory: store
round:
  fee_rate: 1
  fee_floor: 135
  deadline_seconds: 20
  padding_stock: 3
  deposit_margin: 100
server:
  poll_ms: 200
  status_file: status.json
  mined_poll_ms: 200
  funding_timeout_seconds: 600
''');
      // the coordinator's two secrets come from its environment, as in the world
      final coordinator = await _buildCoordinator(root);
      final coordinatorEnv = {'POOL_WALLET_PASSPHRASE': serverPassphrase, 'POOL_RPC_PASSWORD': 'bitcoin'};
      final sw = Stopwatch()..start();
      final create = await Process.start(coordinator, ['--config', configPath, 'create'],
          workingDirectory: '${root.path}/pool', environment: coordinatorEnv);
      String? peerId;
      final createOutput = StringBuffer();
      create.stderr.transform(utf8.decoder).listen(createOutput.write);
      await for (final line in create.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
        createOutput.writeln(line);
        // it asks to be funded, and says under which peer id it published
        // "fund <address> with one payment of at least <n> satoshis" since
        // coordinator 0.1.2; "with at least" before it
        final fund = RegExp(r'fund (\S+) with (?:one payment of )?at least (\d+) satoshis').firstMatch(line);
        if (fund != null) unawaited(_rpc('sendtoaddress', [fund.group(1)!, (int.parse(fund.group(2)!) + 100000) / 1e8]));
        peerId ??= RegExp(r'under peer id (\w+)').firstMatch(line)?.group(1);
      }
      if (await create.exitCode != 0 || peerId == null) fail('the coordinator did not create the pool:\n$createOutput');
      timings['pool created ms'] = sw.elapsedMilliseconds;

      server = await Process.start(coordinator, ['--config', configPath, 'run'],
          workingDirectory: '${root.path}/pool', environment: coordinatorEnv);
      // its output goes to a file in the run's directory, to read while it
      // runs and after (CLOAK_E2E_KEEP=1 keeps the directory)
      final serverLog = File('${root.path}/pool/coordinator.log').openWrite();
      server.stdout.listen((b) {
        serverLog.add(b);
        serverOutput.write(utf8.decode(b, allowMalformed: true));
      });
      server.stderr.listen((b) {
        serverLog.add(b);
        serverOutput.write(utf8.decode(b, allowMalformed: true));
      });
      unawaited(server.exitCode.then((code) {
        if (!stopping) print('  the coordinator stopped by itself, with $code:\n$serverOutput');
      }));

      // ---- the wallets, each following the pool
      depositor = await _Wallet.make(root, 'depositor', ricochet.address, peerId);
      payee = await _Wallet.make(root, 'payee', ricochet.address, peerId);
      refunder = await _Wallet.make(root, 'refunder', ricochet.address, peerId);
    });

    tearDownAll(() async {
      miner.cancel();
      stopping = true;
      server.kill(ProcessSignal.sigterm);
      await server.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
        server.kill(ProcessSignal.sigkill);
        return -9;
      });
      await ricochet.dispose();
      print('  timings: ${timings.entries.map((e) => '${e.key} ${e.value}').join(', ')}');
      if (env['CLOAK_E2E_KEEP'] == null) root.deleteSync(recursive: true);
    });

    test('The transparent side takes coins in, and a round takes the deposit in', () async {
      // the first sync reads the descriptor and stands at the genesis
      await depositor.ok(['sync', '--from-genesis']);

      // ---- coins from the node, handed over as a BEEF (task 7.1 against the real libspiffy)
      final address = jsonDecode((await depositor.ok(['address', '--transparent', '--json'])).out)['address'] as String;
      final funding = await _rpc('sendtoaddress', [address, 0.001]) as String;
      await _untilMined(funding);
      final beef = '${depositor.root.path}/funding.hex';
      File(beef).writeAsStringSync(hex.encode(await _minedBeef(funding)));
      final received = await depositor.until(['receive', beef, '--json'],
          (r) => r.code == Exit.done && jsonDecode(r.out)['waitingFor'] == null, what: 'the funding is taken in');
      expect(jsonDecode(received.out)['satoshis'], 100000, reason: '$received');

      // ---- the deposit: built, funded by libspiffy, handed to the coordinator,
      // which broadcasts the covenant and takes it in with no block between
      final heightBefore = await _rpc('getblockcount') as int;
      final sw = Stopwatch()..start();
      final dep = jsonDecode((await depositor.ok(['deposit', '--amount', '5000', '--yes', '--json'])).out) as Map;
      timings['deposit ms'] = sw.elapsedMilliseconds;
      timings['deposit answer ms'] = dep['answerMs'] as int;
      final covenant = dep['covenant'] as String;
      expect(dep['amount'], 5000);
      expect(dep['status'], 'accepted', reason: 'one command: handed over and taken in');
      final covenantMined = (await _rpc('getrawtransaction', [covenant, 1]) as Map)['confirmations'];
      if (await _rpc('getblockcount') as int == heightBefore) {
        expect(covenantMined, anyOf(isNull, 0), reason: 'accepted before any block mined it');
      }

      // ---- the next syncs submit it and, once round 1 is mined, take its note on
      final sw1 = Stopwatch()..start();
      await depositor.until(['sync'], (r) => depositor.deposit(covenant)['status'] == 'taken',
          what: 'the deposit is a note', within: const Duration(minutes: 10));
      timings['deposit to note ms'] = sw1.elapsedMilliseconds;
      final balance = jsonDecode((await depositor.ok(['balance', '--json'])).out) as Map;
      expect(((balance['assets'] as List).single as Map)['spendable'], 5000);
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('A payment out of the deposited note, proved out of the round the coordinator built', () async {
      await payee.ok(['sync', '--from-genesis']);
      final invoice = '${payee.root.path}/invoice';
      await payee.ok(['invoice', 'new', '--amount', '1200', '--expires', '1d', '--memo', 'a crate of oranges', '--out', invoice]);
      final id = hex.encode(Invoice.decode(File(invoice).readAsBytesSync()).id);
      File(invoice).copySync('${depositor.root.path}/invoice');

      final sw = Stopwatch()..start();
      final paid = jsonDecode((await depositor.ok(['pay', '${depositor.root.path}/invoice', '--json'])).out) as Map;
      timings['pay ms'] = sw.elapsedMilliseconds;
      expect(paid['outcome'], 'accepted', reason: '$paid');

      // round 2 is mined and read; the proof comes out of it
      await depositor.until(['sync'], (r) => depositor.payment(id)['outcome'] == 'mined',
          what: 'the payment is mined', within: const Duration(minutes: 10));
      await depositor.ok(['proof', '--invoice', id, '--out', '${depositor.root.path}/proof']);

      // the payee checks it against its own headers, and acknowledges
      File('${depositor.root.path}/proof').copySync('${payee.root.path}/proof');
      await payee.ok(['sync']);
      final checked = jsonDecode((await payee.until(['check', '${payee.root.path}/proof', '--json'],
              (r) => r.code == Exit.done, what: 'the payee\'s chain holds the block'))
          .out) as Map;
      expect(checked['value'], 1200);
      expect(checked['round'], greaterThanOrEqualTo(2));
      await payee.ok(['ack', '${payee.root.path}/proof', '--out', '${payee.root.path}/ack']);
      File('${payee.root.path}/ack').copySync('${depositor.root.path}/ack');
      await depositor.ok(['ack', '--check', '${depositor.root.path}/ack', '--invoice', id]);

      final payeeBalance = jsonDecode((await payee.ok(['balance', '--json'])).out) as Map;
      expect(((payeeBalance['assets'] as List).single as Map)['spendable'], 1200);
      final change = jsonDecode((await depositor.ok(['balance', '--json'])).out) as Map;
      expect(((change['assets'] as List).single as Map)['spendable'], 3800, reason: 'the change is taken on');
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('A withdrawal out of the change, paid to an address of the node\'s', () async {
      final to = await _rpc('getnewaddress') as String;
      final w = jsonDecode((await depositor.ok(['withdraw', '--amount', '1000', '--to', to, '--yes', '--json'])).out) as Map;
      expect(w['outcome'], 'accepted', reason: '$w');
      final round = w['round'] as int?;
      await depositor.until(['sync'], (r) => depositor.withdrawals.every((x) => x['outcome'] == 'mined'),
          what: 'the withdrawal is mined', within: const Duration(minutes: 10));

      // the round transaction pays the address the amount
      final announced = await _roundTxPaying(to, 1000);
      expect(announced, isNotNull, reason: 'a mined round pays $to 1000 satoshis (round $round)');
      final left = jsonDecode((await depositor.ok(['balance', '--json'])).out) as Map;
      expect(((left['assets'] as List).single as Map)['spendable'], 2800);
    }, timeout: const Timeout(Duration(minutes: 20)));

    test('A deposit no round takes in, refunded at its height', () async {
      await refunder.ok(['sync', '--from-genesis']);
      final address = jsonDecode((await refunder.ok(['address', '--transparent', '--json'])).out)['address'] as String;
      final funding = await _rpc('sendtoaddress', [address, 0.001]) as String;
      await _untilMined(funding);
      final beef = '${refunder.root.path}/funding.hex';
      File(beef).writeAsStringSync(hex.encode(await _minedBeef(funding)));
      await refunder.until(['receive', beef, '--json'],
          (r) => r.code == Exit.done && jsonDecode(r.out)['waitingFor'] == null, what: 'the funding is taken in');

      // a pool that never answers: the ricochet server's own mailbox. The
      // deposit is left submitting, and the person puts the covenant on the
      // chain by hand, so no round takes it in
      final config = File('${refunder.path}/config.yaml');
      final real = config.readAsStringSync();
      final nobody = ricochet.address.split('/p2p/').last;
      config.writeAsStringSync(real.replaceFirst(RegExp(r'  coordinator: \S+'), '  coordinator: $nobody'));
      final dep = jsonDecode((await refunder.ok(['deposit', '--amount', '4000', '--yes', '--json'])).out) as Map;
      final covenant = dep['covenant'] as String;
      final refundAfter = dep['refundAfter'] as int;
      expect(dep['status'], 'submitting', reason: 'no answer is not a refusal');
      config.writeAsStringSync(real);
      await refunder.ok(['deposit', '--broadcast', covenant]);
      await _untilMined(covenant);

      // never submitted: no sync runs. Too early is refused, naming the height
      final early = await refunder.run(['refund', '--deposit', covenant]);
      expect(early.code, Exit.refused, reason: '$early');
      expect(early.err, contains('$refundAfter'));

      // the chain passes the refund height
      final tip = await _rpc('getblockcount') as int;
      if (tip < refundAfter) await _rpc('generatetoaddress', [refundAfter - tip, await _rpc('getnewaddress')]);
      final refunded = await refunder.until(['refund', '--deposit', covenant, '--json'], (r) => r.code == Exit.done,
          what: 'the refund is taken');
      final refund = jsonDecode(refunded.out)['refund'] as String;
      await _untilMined(refund);
      final tx = Transaction.fromHex(await _rpc('getrawtransaction', [refund, 0]) as String);
      expect(tx.inputs.single.prevTxnId, covenant, reason: 'the refund spends the covenant');
      expect(tx.outputs.single.satoshis.toInt(), inInclusiveRange(4000 - 1000, 4000),
          reason: 'the deposit comes back, less the refund\'s fee');
      expect(refunder.deposit(covenant)['status'], 'refunded');
    }, timeout: const Timeout(Duration(minutes: 20)));
  }, skip: skip);
}

/// One cloak wallet, run through its command lines by the compiled binary,
/// one process a command, as a person runs it.
class _Wallet {
  static const passphrase = 'cloak e2e wallet passphrase';

  /// The compiled `bin/cloak.dart`, built once for the run, or a released
  /// bundle's program when CLOAK_E2E_BINARY names one, which is how the release
  /// checklist runs this suite against what it is about to publish.
  static late String binary;

  final String name;
  final Directory root;
  _Wallet(this.name, this.root);

  String get path => '${root.path}/w';

  static Future<void> build(Directory under) async {
    final given = Platform.environment['CLOAK_E2E_BINARY'];
    if (given != null) {
      binary = File(given).absolute.path;
      return;
    }
    // dart build cli, since tstokenlib's build hook puts its kernels in the
    // bundle; the program finds them there as an installed one does
    final r = await Process.run('dart', ['build', 'cli', '--target', 'bin/cloak.dart', '-o', '${under.path}/cli']);
    if (r.exitCode != 0) fail('cloak did not build: ${r.stdout}${r.stderr}');
    binary = '${under.path}/cli/bundle/bin/cloak';
  }

  static Future<_Wallet> make(Directory under, String name, String server, String coordinator) async {
    final w = _Wallet(name, Directory('${under.path}/$name')..createSync());
    await w.ok(['init', '--network', 'regtest', '--server', server, '--pool', coordinator]);
    final config = File('${w.path}/config.yaml');
    config.writeAsStringSync(config
        .readAsStringSync()
        .replaceFirst('timeout_seconds: 30', 'timeout_seconds: 20')
        .replaceFirst('  peers: []', '  peers:\n    - 127.0.0.1:18333')
        .replaceFirst('  url: ~', '  url: $_arcUrl'));
    return w;
  }

  Future<Ran> run(List<String> args) async {
    final r = await Process.run(binary, ['--wallet', path, ...args],
        workingDirectory: root.path,
        environment: {'HOME': root.path, passphraseEnv: passphrase},
        stdoutEncoding: utf8,
        stderrEncoding: utf8);
    return Ran(r.exitCode, r.stdout as String, r.stderr as String);
  }

  Future<Ran> ok(List<String> args) async {
    final sw = Stopwatch()..start();
    final ran = await run(args);
    print('  $name: cloak ${args.first} (${sw.elapsedMilliseconds} ms)');
    expect(ran.code, Exit.done, reason: '$name: cloak ${args.join(' ')}: $ran');
    return ran;
  }

  /// Runs [args] until [done] holds of what came back, as a person runs a
  /// command again later.
  Future<Ran> until(List<String> args, bool Function(Ran) done,
      {required String what, Duration within = const Duration(minutes: 3)}) async {
    final deadline = DateTime.now().add(within);
    while (true) {
      final ran = await run(args);
      if (done(ran)) {
        print('  $name: cloak ${args.first}: $what');
        return ran;
      }
      if (DateTime.now().isAfter(deadline)) fail('$name: $what did not happen within $within; last: $ran');
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Map<String, Object?> get _state => jsonDecode(File('$path/state.json').readAsStringSync()) as Map<String, Object?>;

  Map<String, Object?> deposit(String covenant) =>
      ((_state['deposits'] as List).cast<Map<String, Object?>>()).firstWhere((d) => d['covenant'] == covenant);

  Map<String, Object?> payment(String invoiceId) => ((_state['payments'] as List).cast<Map<String, Object?>>())
      .firstWhere((p) => hex.encode(Invoice.decode(hex.decode(p['invoice'] as String)).id) == invoiceId);

  List<Map<String, Object?>> get withdrawals => (_state['withdrawals'] as List).cast<Map<String, Object?>>();
}

// ---------------------------------------------------------------------------
// the regtest node and ARC, as ../localnet runs them; the credentials are the
// harness's published ones and never a real node's

const _rpcUrl = 'http://localhost:18332';
/// ARC's address. Docker publishes it on every loopback address, and the
/// ricochet server this run starts takes 127.0.0.1:9090 for its operator
/// surface a moment after it is up, IPv4 only, so ARC is looked for on the
/// IPv6 loopback first.
var _arcUrl = _arcUrls.first;
const _arcUrls = ['http://[::1]:9090/v1', 'http://127.0.0.1:9090/v1'];
final _http = HttpClient();

Future<dynamic> _rpc(String method, [List<dynamic> params = const []]) async {
  final req = await _http.postUrl(Uri.parse(_rpcUrl));
  req.headers.set('Authorization', 'Basic ${base64.encode(utf8.encode('bitcoin:bitcoin'))}');
  req.headers.contentType = ContentType.json;
  req.persistentConnection = false;
  req.write(jsonEncode({'jsonrpc': '1.0', 'id': method, 'method': method, 'params': params}));
  final res = await req.close();
  final json = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
  if (json['error'] != null) throw StateError('$method: ${json['error']}');
  return json['result'];
}

Future<String> _mine() async => ((await _rpc('generatetoaddress', [1, await _rpc('getnewaddress')])) as List).single as String;

Future<void> _untilMined(String txid) async {
  final deadline = DateTime.now().add(const Duration(minutes: 3));
  while (true) {
    try {
      final info = await _rpc('getrawtransaction', [txid, 1]) as Map<String, dynamic>;
      if (info['blockhash'] != null) return;
    } on StateError {
      // not seen yet
    }
    if (DateTime.now().isAfter(deadline)) fail('$txid was not mined');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// A mined transaction as a BEEF carrying its merkle proof, from the node.
Future<List<int>> _minedBeef(String txid) async {
  final source = NodeRpcDataSource(rpcUrl: _rpcUrl, rpcUser: 'bitcoin', rpcPassword: 'bitcoin');
  final proof = await source.getMerkleProof(txid);
  final raw = await source.getRawTransaction(txid);
  final bump = BUMP.fromTscProof(blockHeight: proof.blockHeight, txid: txid, index: proof.index, nodes: proof.nodes);
  return BEEF.create(bumps: [bump], txs: [Uint8List.fromList(hex.decode(raw))], hasMerkle: [true], bumpIndex: [0])
      .serialize();
}

/// The txid of a transaction in the last 200 blocks paying [address]
/// exactly [sats], or null.
Future<String?> _roundTxPaying(String address, int sats) async {
  final tip = await _rpc('getblockcount') as int;
  for (int h = tip; h > max(0, tip - 200); h--) {
    final block = await _rpc('getblock', [await _rpc('getblockhash', [h]), 2]) as Map<String, dynamic>;
    for (final tx in (block['tx'] as List).cast<Map<String, dynamic>>()) {
      for (final o in (tx['vout'] as List).cast<Map<String, dynamic>>()) {
        final spk = o['scriptPubKey'] as Map<String, dynamic>;
        final addrs = (spk['addresses'] as List?)?.cast<String>() ?? const [];
        if (addrs.contains(address) && ((o['value'] as num) * 1e8).round() == sats) return tx['txid'] as String;
      }
    }
  }
  return null;
}

/// Why localnet cannot run this, or null when it can.
String _kernelsName() => Platform.isMacOS ? 'libstark_kernels.dylib' : 'libstark_kernels.so';

/// The pool-coordinator checkout the coordinator is built from.
String get _coordinatorCheckout =>
    Platform.environment['POOL_COORDINATOR'] ?? File('../pool-coordinator').absolute.path;

/// Why the coordinator cannot be built here, or null when it can.
String? _coordinatorProblem() => File('$_coordinatorCheckout/bin/pool_coordinator.dart').existsSync()
    ? null
    : 'needs a pool-coordinator checkout at $_coordinatorCheckout, or POOL_COORDINATOR naming one';

/// The coordinator, built from its checkout into [under] as a person would
/// build it, and the path of its program.
Future<String> _buildCoordinator(Directory under) async {
  final r = await Process.run('dart', ['build', 'cli', '--target', 'bin/pool_coordinator.dart', '-o', '${under.path}/coordinator'],
      workingDirectory: _coordinatorCheckout);
  if (r.exitCode != 0) fail('the coordinator did not build: ${r.stdout}${r.stderr}');
  // tstokenlib's build hook puts the kernels in the coordinator's bundle, as
  // in cloak's; without them the coordinator refuses to start
  final kernels = File('${under.path}/coordinator/bundle/lib/${_kernelsName()}');
  if (!kernels.existsSync()) {
    fail('the coordinator built from $_coordinatorCheckout bundles no kernels library: its lock pins a tstokenlib '
        'from before the build hook (2.1.0); run dart pub upgrade tstokenlib there');
  }
  return '${under.path}/coordinator/bundle/bin/pool_coordinator';
}

Future<String?> _localnetProblem() async {
  try {
    final chain = await _rpc('getblockchaininfo') as Map<String, dynamic>;
    if (chain['chain'] != 'regtest') return 'the node runs ${chain['chain']}';
    if (!await _findArc()) return 'ARC answers on none of ${_arcUrls.join(', ')}';
    if (((await _rpc('getbalance')) as num) < 2) await _rpc('generatetoaddress', [101, await _rpc('getnewaddress')]);
    return null;
  } catch (e) {
    return 'localnet is not reachable: $e';
  }
}

/// Points [_arcUrl] at the first address that answers as a healthy ARC.
Future<bool> _findArc() async {
  for (final url in _arcUrls) {
    try {
      final res = await _http.getUrl(Uri.parse('$url/health')).then((r) => r.close()).timeout(const Duration(seconds: 3));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 200 && (jsonDecode(body) as Map)['healthy'] == true) {
        _arcUrl = url;
        return true;
      }
    } catch (_) {
      // not ARC, or not there
    }
  }
  return false;
}
