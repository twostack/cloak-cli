import 'dart:math';

import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart' show PoolWalletKeys;

import '../native/native_libraries.dart';
import '../wallet/config.dart';
import '../wallet/sealed_store.dart';
import '../wallet/wallet_dir.dart';

/// What a command may reach outside its own arguments.
///
/// One of these is built in `bin/cloak.dart` from the real process, and a test
/// builds one from doubles. Everything a command does to the world goes
/// through here: the two output streams, the environment, the clock, the
/// prompts, and the two ports libcloak asks a host for. That is what lets a
/// test run every command in-process against a fake pool, and what lets a test
/// say "this command started neither the chain nor the transport" by counting
/// calls rather than by hoping.
class World {
  final StringSink out, err;
  final Map<String, String> env;
  final DateTime Function() now;

  /// Reads a line from a terminal with echo off, or null when no terminal is
  /// attached. Only a passphrase is read this way.
  final Future<String?> Function(String prompt)? readSecret;

  /// Reads a line from a terminal, or null when no terminal is attached. Used
  /// for the one confirmation a deposit asks for.
  final Future<String?> Function(String prompt)? readLine;

  /// Where the chain and the pool come from. Built lazily, per command, and
  /// only for a command that needs them.
  final Ports ports;

  /// The cost a new wallet file is written under. Strong by default; a suite
  /// passes the fast one so that a hundred wallets do not cost a minute.
  final WalletKdf kdf;

  /// Randomness for everything that is not a key. Null means the platform's
  /// secure source, which is what a person always gets.
  final Random? rng;

  /// The suite's one stand-in for the seed. A fake pool's notes are minted to
  /// a fixture wallet whose keys no seed derives, so a suite that wants a
  /// wallet to spend them substitutes those pool keys for the seed's. The
  /// binary never sets it: a person's pool keys are always their seed's.
  final PoolWalletKeys Function(WalletKeys keys)? poolKeysForSuite;

  /// Where the two native libraries come from. The process's own by default;
  /// a test names a bundle of its own making.
  final NativeLibraries native;

  World({
    required this.out,
    required this.err,
    required this.env,
    required this.ports,
    DateTime Function()? now,
    this.readSecret,
    this.readLine,
    this.kdf = WalletKdf.strong,
    this.rng,
    this.poolKeysForSuite,
    NativeLibraries? native,
  })  : now = now ?? (() => DateTime.now().toUtc()),
        native = native ?? NativeLibraries.ofProcess(env);
}

/// The chain and the pool, as a command reaches them.
///
/// Each method starts something expensive, which is why they are methods and
/// not fields: `cloak --help` and `cloak balance` never call them, and a test
/// asserts that by counting.
abstract interface class Ports {
  /// The wallet's own header source, started over [dir] under [config].
  Future<HeaderSource> headers(WalletDir dir, CloakConfig config);

  /// The transport to the configured pool, as the identity kept in [dir].
  Future<Transport> transport(WalletDir dir, CloakConfig config);

  /// The transparent side: BEEF in, coins held, signing and broadcast. Its
  /// secrets are in [sealed], which only a session holding the wallet's seed
  /// can open. With [offline] nothing is dialled: the side is opened from
  /// what is stored, to read what it holds, and the chain is not synced.
  Future<TransparentSide> transparent(WalletDir dir, CloakConfig config, SealedStore sealed, {bool offline = false});

  /// Stops whatever was started. Called once, when the command returns.
  Future<void> close();
}

/// The transparent side of the wallet, as the deposit commands need it.
///
/// It is its own interface for the same reason libcloak's two ports are: the
/// commands above it name what they need and nothing wider, so a test can
/// stand in for it and a reader can see what the transparent side is asked.
/// Nothing here takes an address to look up: coins arrive as BEEF a payer
/// handed over, and leave in transactions this wallet built.
abstract interface class TransparentSide {
  /// Takes a BEEF payment another person handed over. It is validated against
  /// the wallet's own headers, and parked when its block is above the tip.
  Future<ReceiveOutcome> receive(List<int> beef);

  /// Satoshis held in coins this wallet can spend now.
  Future<int> spendable();

  /// A fresh transparent address of this wallet's own, never issued before.
  Future<String> freshAddress();

  /// A transaction paying [satoshis] to [lockingScript] out of this wallet's
  /// coins, change to a fresh address of its own, signed and **not**
  /// broadcast. Its coins are held for it until it is broadcast or given back
  /// with [release].
  Future<(BuiltTransparent?, Refusal?)> payTo(List<int> lockingScript, int satoshis);

  /// Gives back the coins held for [txid], which will not be broadcast.
  Future<void> release(String txid);

  /// Broadcasts [txHex]. It has already been recorded when this is called;
  /// a failure is a refusal carrying the broadcaster's reason. [fundedHere]
  /// is false for a transaction this side did not build, which is a deposit's
  /// refund: it spends the covenant, not this side's coins.
  Future<Refusal?> broadcast(String txHex, {bool fundedHere = true});

  /// Whether [txid], a transaction this wallet broadcast, is mined.
  Future<bool> mined(String txid);
}

/// A transparent transaction built and not yet broadcast.
class BuiltTransparent {
  final String txid, txHex;
  const BuiltTransparent(this.txid, this.txHex);
}

/// What came of a BEEF payment.
class ReceiveOutcome {
  /// The payment's txid, which the payer chose to show this wallet.
  final String txid;

  /// Satoshis it pays this wallet.
  final int satoshis;

  /// The block height it waits for, when its block is above the wallet's tip.
  final int? waitingFor;

  const ReceiveOutcome(this.txid, this.satoshis, {this.waitingFor});

  bool get parked => waitingFor != null;
}
