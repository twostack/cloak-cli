import 'dart:io';

import 'package:args/args.dart';
import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';

import '../net/identity.dart';
import '../shell/call.dart';
import '../shell/report.dart';
import '../shell/passphrase.dart';
import '../version.dart';
import '../wallet/config.dart';
import '../wallet/state_file.dart';
import '../wallet/wallet_dir.dart';

void initOptions(ArgParser p) => p
  ..addOption('network', allowed: ['regtest', 'testnet', 'mainnet'], defaultsTo: 'testnet', help: 'the chain')
  ..addOption('server', valueHelp: 'multiaddr', help: 'the ricochet server, ending in /p2p/<peer id>')
  ..addOption('pool', valueHelp: 'peer id', help: 'the coordinator whose feed is the pool\'s');

/// `cloak init`: a new seed, under a passphrase, written once.
///
/// The seed is the only thing printed on standard output, so `cloak init >
/// seed.txt` records it with nothing beside it; everything else goes to
/// standard error. Nothing else exists yet when it is printed: no pool view,
/// no note store, no journal. A person who loses the seed at this moment has
/// lost nothing, and a person who records it has recorded the whole of what
/// the wallet will ever be derived from.
Future<void> runInit(Call call) async {
  final dir = call.dir;
  if (dir.holdsWallet) {
    throw Refusal('wallet',
        'there is already a wallet file at ${dir.walletFile}, and init never overwrites one: a wallet file holding '
        'notes is money');
  }
  final network = CloakNetwork.parse(call.option('network')!)!;
  // a wallet made by an installation that cannot derive its addresses would
  // be a seed printed for nothing
  call.world.native.checkKernels();
  final passphrase = await Passphrase.obtain(call.world, confirm: true);
  await dir.create();

  final seed = WalletSeed.generate();
  final keys = WalletKeys(seed: seed, birthday: 0);
  final notice = await WalletFile.create(path: dir.walletFile, passphrase: passphrase, keys: keys, kdf: call.world.kdf);

  final config = CloakConfig(network: network, server: call.option('server'), coordinator: call.option('pool'));
  await _writeOwnerOnly(dir.config, config.toYaml());
  await TransportIdentity.create(dir, rng: call.world.rng);

  call.reportToErr = true;
  call.world.out.writeln(hex.encode(seed.bytes));
  call.report
    ..add('wallet', dir.path, 'a new wallet is in ${dir.path}')
    ..add('network', network.name, 'network: ${network.name}')
    ..add('pool', config.hasPool, config.hasPool ? 'pool: ${config.coordinator}' : 'pool: not named yet; set it in ${dir.config}')
    ..say('the line on standard output is the seed. Record it where the passphrase is not.')
    ..say(notice.notice)
    ..say('the seed alone is not yet enough to restore this wallet: back up the whole directory, the note store most of all.');
}

Future<void> _writeOwnerOnly(String path, String text) async {
  final f = File(path);
  await f.writeAsString('', flush: true);
  await WalletDir.ownerOnly(path);
  await f.writeAsString(text, flush: true);
}

/// `cloak unlock`: does the passphrase open the wallet, and what does it hold.
///
/// It keeps nothing: the seed is decrypted, the keys are derived, the answer
/// is printed, and the process ends. There is no session, no agent and no
/// cache, because a wallet unlocked beyond the life of a process is a wallet
/// unlocked for whoever gets to the machine next.
Future<void> runUnlock(Call call) async {
  final s = await call.open(keys: true);
  final k = s.keys;
  call.report
    ..add('opened', true, 'the passphrase opens ${s.dir.walletFile}')
    ..add('derivation', WalletKeys.derivation, 'derivation: ${WalletKeys.derivation}')
    ..add('birthday', k.birthday, 'birthday: round ${k.birthday}')
    ..add('addressesIssued', k.addressesIssued, 'addresses issued: ${k.addressesIssued}');
}

void addressOptions(ArgParser p) =>
    p.addFlag('transparent', negatable: false, help: 'a transparent address, for receiving BSV over BEEF');

/// `cloak address`: a fresh address, never issued before.
///
/// A pool address by default, which is what an invoice carries; a person
/// wanting to be paid should normally issue an invoice instead, because an
/// invoice names the amount and expiry and is signed. With `--transparent`, a
/// fresh transparent address for a payer sending BSV over BEEF.
Future<void> runAddress(Call call) async {
  if (call.flag('transparent')) {
    final s = await call.open(write: true, keys: true);
    final a = await (await s.transparent()).freshAddress();
    call.report.add('address', a, a);
    return;
  }
  final s = await call.open(write: true, keys: true);
  final index = s.keys.addressesIssued;
  final address = await s.nextAddress();
  await s.save(view: false, store: false);
  call.report
    ..add('index', index, 'address $index of this wallet:')
    ..add('address', hex.encode(address.bytes), hex.encode(address.bytes));
}

/// `cloak status`: which directory, which files, which formats, what is
/// pending.
///
/// It reads and never writes, and it needs no passphrase, so it is the
/// command to run first when something looks wrong. It opens every state file
/// the way a command would, so a file written by a newer build is refused
/// here, naming both versions, rather than discovered half way through a
/// payment.
Future<void> runStatus(Call call) async {
  final dir = call.dir;
  final r = call.report
    ..add('version', CloakVersion.program, 'cloak ${CloakVersion.program}')
    ..add('formats', CloakVersion.formats,
        'formats: ${CloakVersion.formats.entries.map((e) => '${e.key} ${e.value}').join(', ')}')
    ..add('wallet', dir.path, 'wallet: ${dir.path}')
    ..add('source', dir.source.label, 'named by: ${dir.source.label}');
  _nativeLibraries(call);
  if (!dir.holdsWallet) {
    r.add('exists', false, 'there is no wallet here; cloak init makes one');
    return;
  }
  r.quiet('exists', true);

  final s = await call.open();
  final files = <Map<String, Object?>>[];
  void file(String name, String path, {required bool encrypted, String? why}) {
    final t = FileSystemEntity.typeSync(path);
    if (t == FileSystemEntityType.notFound) return;
    final size = t == FileSystemEntityType.directory
        ? Directory(path).listSync().whereType<File>().fold<int>(0, (a, f) => a + f.lengthSync())
        : File(path).lengthSync();
    files.add({'name': name, 'path': path, 'bytes': size, 'encrypted': encrypted});
    r.say('  $name  $size bytes  ${encrypted ? 'encrypted' : 'NOT encrypted'}${why == null ? '' : ' ($why)'}');
  }

  r.say('files:');
  file('wallet file', dir.walletFile, encrypted: true, why: 'the seed, under the passphrase');
  file('note store', dir.noteStore,
      encrypted: false, why: 'each note\'s opening and randomness; protect this file beyond its permissions');
  file('pool view', dir.poolView, encrypted: false, why: 'which leaves are this wallet\'s');
  file('journal', dir.journal, encrypted: false, why: 'what was issued, paid, proved and acknowledged');
  file('wallet state', dir.state, encrypted: false, why: 'the pool\'s descriptor, invoices and payments in flight');
  file('transport identity', dir.identity, encrypted: false, why: 'the key this wallet talks to the pool as');
  file('chain database', dir.chain,
      encrypted: false,
      why: 'public block headers, and the transparent wallet\'s coins and transactions, which are not public');
  r.quiet('files', files);

  final pool = s.pool;
  if (pool == null) {
    r.add('pool', null, 'pool: not read yet; cloak sync reads its descriptor');
  } else {
    r.add('pool', {'tokenId': hex.encode(pool.tokenId), 'leavesPerRound': pool.leavesPerRound},
        'pool: ${shortHex(pool.tokenId)}, ${pool.leavesPerRound} leaves a round');
  }
  final v = s.view;
  if (v != null) {
    r.add('view', {'round': v.round, 'checkedTo': v.checkedTo, 'notes': v.notes.length},
        'pool view: folded to round ${v.round}, checked to round ${v.checkedTo}, following ${v.notes.length} notes');
  }
  _pending(s.state, r);
}

/// Where each native library would be loaded from and whether a file is
/// there, found without loading either, so an installation missing one can
/// still say which.
void _nativeLibraries(Call call) {
  final libs = call.world.native.describe();
  call.report.quiet('nativeLibraries', libs);
  call.report.say('native libraries:');
  for (final l in libs) {
    final path = l['path'] as String?;
    final state = path == null
        ? l['found']
        : l['present'] == true
            ? path
            : 'MISSING: no ${l['file']} at $path';
    call.report.say('  ${l['name']}  $state');
  }
}

void _pending(CloakState state, Report r) {
  final deposits = [for (final d in state.deposits) if (d.status != 'taken' && d.status != 'refunded') d];
  r.quiet('deposits', [for (final d in deposits) d.toJson()..remove('note')]);
  for (final d in deposits) {
    r.say('deposit ${d.covenantTxid}: ${d.status}, ${d.satoshis} satoshis, for round ${d.intoRound}, '
        'refundable from block ${d.refundAfter}');
  }
  final unsent = [for (final t in state.transparent) if (!t.broadcast) t];
  r.quiet('unbroadcast', [for (final t in unsent) {'kind': t.kind, 'txid': t.txid}]);
  for (final t in unsent) {
    r.say('${t.kind} ${t.txid}: recorded and not broadcast; cloak ${t.kind == 'withdrawal' ? 'withdraw' : t.kind} '
        '--broadcast ${t.txid} sends it without rebuilding it');
  }
  final open = [for (final p in state.payments) if (p.outcome == 'accepted' || p.outcome == 'unanswered') p];
  r.quiet('payments', [
    for (final p in open) {'invoice': hex.encode(p.invoiceId), 'outcome': p.outcome, 'round': p.round}
  ]);
  for (final p in open) {
    r.say('payment for invoice ${hex.encode(p.invoiceId)}: ${p.outcome}'
        '${p.round == null ? '' : ' into round ${p.round}'}');
  }
}
