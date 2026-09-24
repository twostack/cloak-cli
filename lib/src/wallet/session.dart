import 'dart:io';

import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../net/deadline_transport.dart';
import '../net/ricochet_wallet_transport.dart' show PoolMailbox;
import '../shell/call.dart';
import '../shell/passphrase.dart';
import '../shell/world.dart';
import 'config.dart';
import 'sealed_store.dart';
import 'state_file.dart';
import 'wallet_dir.dart';
import 'wallet_lock.dart';

/// A wallet, opened for one command.
///
/// This is where the four state files libcloak defines meet this program's
/// own, and the only place any of them is read or written. A command opens a
/// session, asks it for what it needs, and calls [save] once its work is
/// whole; nothing is written piecemeal, so a command that fails part way
/// leaves the files as they were.
///
/// The chain and the pool are reached through here too, lazily: a session
/// that is never asked for [headers] or [transport] starts neither, which is
/// how `cloak balance` makes no network call at all.
class Session {
  final Call call;
  final WalletDir dir;
  final CloakConfig config;
  final CloakState state;
  final WalletLock? lock;

  /// The passphrase and the keys, for a session opened with keys. They live
  /// for this process and are written nowhere.
  final String? _passphrase;
  final WalletKeys? _keys;
  int _issuedAtOpen;

  /// Time spent turning the passphrase into a key, which is the wallet
  /// file's own deliberate cost and is reported apart from this program's.
  Duration kdf = Duration.zero;

  /// The pool view, or null before the first sync.
  PoolView? view;
  NoteStore? _store;
  Journal? _journal;
  HeaderSource? _headers;
  Transport? _transport;
  Transport? _raw;
  TransparentSide? _transparent;
  SealedStore? _sealed;

  Session._(this.call, this.dir, this.config, this.state, this.lock, this._passphrase, this._keys)
      : _issuedAtOpen = _keys?.addressesIssued ?? 0;

  static Future<Session> open(Call call, {required bool write, required bool keys}) async {
    final dir = call.dir;
    if (!dir.holdsWallet) {
      throw Refusal('wallet', 'there is no wallet in ${dir.path} (named by ${dir.source.label}); run cloak init');
    }
    final warning = dir.permissionWarning();
    if (warning != null) call.world.err.writeln('cloak: warning: $warning');
    final lock = write ? await WalletLock.take(dir.lock) : null;
    try {
      final config = await CloakConfig.load(dir.config);
      final state = await CloakState.open(dir);
      String? passphrase;
      WalletKeys? walletKeys;
      if (keys) {
        passphrase = await Passphrase.obtain(call.world);
        final sw = Stopwatch()..start();
        final stored = await WalletFile.open(path: dir.walletFile, passphrase: passphrase);
        walletKeys = stored.keys;
        sw.stop();
        final s = Session._(call, dir, config, state, lock, passphrase, walletKeys)..kdf = sw.elapsed;
        await s._openPoolFiles();
        return s;
      }
      final s = Session._(call, dir, config, state, lock, passphrase, walletKeys);
      await s._openPoolFiles();
      return s;
    } catch (_) {
      await lock?.release();
      rethrow;
    }
  }

  /// The pool this wallet follows, or null before the first sync.
  PoolDescriptor? get pool => state.pool;

  /// The pool, or a refusal saying to sync first.
  PoolDescriptor get poolOrRefuse {
    final p = pool;
    if (p == null) {
      throw const Refusal('pool', 'this wallet has not read its pool\'s descriptor yet; run cloak sync');
    }
    return p;
  }

  PoolShape get shape => PoolShape.forPool(poolOrRefuse).$1!;

  /// Whether this session was opened with the wallet's keys.
  bool get hasKeys => _keys != null;

  WalletKeys get keys {
    final k = _keys;
    if (k == null) throw StateError('this session was opened without keys');
    return k;
  }

  /// The pool keys every spend, invoice, check and acknowledgement uses: the
  /// seed's, unless a suite stood a fixture's in for them.
  PoolWalletKeys get poolKeys => call.world.poolKeysForSuite?.call(keys) ?? keys.pool;

  /// The next address this wallet has not issued, advancing the counter the
  /// wallet file keeps. One invoice, one address.
  Future<NoteAddress> nextAddress() async {
    final index = keys.addressesIssued;
    final a = await keys.nextAddress();
    if (call.world.poolKeysForSuite == null) return a;
    return NoteAddress.at(poolKeys.ivk, index, kem: keys.kem);
  }

  /// This wallet's address key for diversifier [d]: what a note paid to one of
  /// its addresses commits under.
  List<int> pkdFor(List<int> d) => PoolHash.pkdFromIvk(poolKeys.ivk, d);

  PoolView get viewOrRefuse {
    final v = view;
    if (v == null) throw const Refusal('pool view', 'this wallet holds no pool view yet; run cloak sync');
    return v;
  }

  NoteStore get store => _store ??= NoteStore(shape);

  Future<Journal> journal() async {
    final j = _journal;
    if (j != null) return j;
    final (opened, why) = await Journal.open(dir.journal);
    if (opened == null) throw why!;
    return _journal = opened;
  }

  /// Appends [entry] to the journal. A journal that cannot be written is a
  /// refusal: a payment whose record is lost is worse than one not made.
  Future<void> record(JournalEntry entry) async {
    final (_, why) = await (await journal()).add(entry);
    if (why != null) throw why;
  }

  Future<void> _openPoolFiles() async {
    final p = pool;
    if (p == null) return;
    final (shape, why) = PoolShape.forPool(p);
    if (shape == null) throw why!;
    if (File(dir.poolView).existsSync()) view = await PoolViewFile.open(dir.poolView, shape: shape);
    if (File(dir.noteStore).existsSync()) _store = await NoteStoreFile.open(dir.noteStore, shape: shape);
  }

  /// The wallet's own header source, started on first use.
  Future<HeaderSource> headers() async => _headers ??= await call.world.ports.headers(dir, config);

  /// The transparent side, started on first use with its sealed secrets.
  ///
  /// It needs the wallet's keys, because its secrets are sealed by the seed;
  /// and it must be asked for before anything asks the chain, because
  /// libspiffy takes its secret storage only when it starts.
  Future<TransparentSide> transparent() async {
    final t = _transparent;
    if (t != null) return t;
    return _transparent = await call.world.ports.transparent(dir, config, await sealed());
  }

  /// The transparent side's sealed secrets, opened with the wallet's seed.
  Future<SealedStore> sealed() async => _sealed ??= await SealedStore.open(dir, keys.seed);

  /// A header checker at this wallet's confirmation depth.
  Future<HeaderChecker> headerChecker() async => HeaderChecker(await headers(), confirmations: config.confirmations);

  /// The transport to the pool, opened on first use.
  Future<Transport> transport() async {
    if (!config.hasPool) {
      throw Refusal('config', 'this wallet names no pool; set pool.server and pool.coordinator in ${dir.config}');
    }
    final t = _transport;
    if (t != null) return t;
    _raw = await call.world.ports.transport(dir, config);
    return _transport = DeadlineTransport(_raw!, config.timeout);
  }

  /// The pool mailbox behind the transport, for replies an earlier run gave up
  /// on and notices nobody asked for; null for a transport that has none.
  Future<PoolMailbox?> mailbox() async {
    await transport();
    final r = _raw;
    return r is PoolMailbox ? r as PoolMailbox : null;
  }

  /// Writes every state file this session changed, each temp-then-rename.
  ///
  /// The wallet file is rewritten only when an address was issued, because
  /// rewriting it re-encrypts the seed and there is no reason to touch the one
  /// file that holds it more often than the address counter demands.
  Future<void> save({bool view = true, bool store = true}) async {
    if (lock == null) throw StateError('a session opened for reading does not save');
    final v = this.view;
    if (view && v != null) await PoolViewFile.save(dir.poolView, v);
    final s = _store;
    if (store && s != null) await NoteStoreFile.save(dir.noteStore, s);
    await state.save(dir);
    final k = _keys;
    if (k != null && k.addressesIssued != _issuedAtOpen) {
      final sw = Stopwatch()..start();
      await WalletFile.save(path: dir.walletFile, passphrase: _passphrase!, keys: k, kdf: call.world.kdf);
      kdf += sw.elapsed;
      _issuedAtOpen = k.addressesIssued;
    }
  }

  Future<void> close() async {
    await lock?.release();
  }
}
