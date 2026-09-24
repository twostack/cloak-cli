import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dactor/dactor.dart' show Message;
import 'package:dartsv/dartsv.dart' hide Message;
import 'package:libcloak/libcloak.dart';
import 'package:libspiffy/coordinator.dart';
import 'package:libspiffy/libspiffy.dart';

import '../shell/world.dart';
import 'bip39_english.dart';

/// Locks an output to a script this program built, for libspiffy's payment
/// flow: the deposit covenant tstokenlib writes.
///
/// libspiffy funds, signs and makes change for a payment whose outputs a
/// plugin describes, so this is how a deposit covenant is paid for out of
/// the wallet's coins without this program choosing coins or signing. It
/// identifies nothing: the covenant is not a coin this wallet spends through
/// libspiffy, so libspiffy is not told it is one.
class CovenantOutputPlugin extends ScriptPlugin {
  static const id = 'cloak_covenant';

  @override
  String get pluginId => id;
  @override
  String get displayName => 'cloak deposit covenant';
  @override
  List<String> get scriptTypes => const ['covenant'];
  @override
  String? identifyScript(SVScript script) => null;
  @override
  Map<String, dynamic>? extractMetadata(SVScript script) => null;
  @override
  LockingScriptBuilder? createLockBuilder(PluginOutputSpec spec) =>
      DefaultLockBuilder.fromScript(SVScript.fromHex(spec.params['script'] as String));
  @override
  UnlockingScriptBuilder? createUnlockBuilder(PluginUnlockSpec spec) => null;
}

/// The transparent side, over libspiffy's coordinator.
///
/// One libspiffy wallet, named [walletId], whose mnemonic this program draws
/// at random and libspiffy keeps, in the sealed store this program gives it. Every call is a
/// command to libspiffy's coordinator and the event it answers with; a
/// failure it reports comes back as a refusal carrying its own words.
class SpiffyTransparentSide implements TransparentSide {
  static const walletId = 'cloak';
  static const answerWithin = Duration(seconds: 60);

  final LibSpiffyActorSystem system;
  final ArcService arc;
  final Random _r = Random.secure();

  SpiffyTransparentSide._(this.system, this.arc);

  /// The wallet in [system], made on first use.
  ///
  /// Whether it exists is libspiffy's to say, and only its answer to making
  /// it says so: a balance query about a wallet it has never heard of answers
  /// zero, as for an empty one. So it is asked to make the wallet every time,
  /// and "already exists" is the answer for every run after the first.
  static Future<SpiffyTransparentSide> open(LibSpiffyActorSystem system, ArcService arc) async {
    if (!PluginRegistry().isRegistered(CovenantOutputPlugin.id)) PluginRegistry().register(CovenantOutputPlugin());
    final side = SpiffyTransparentSide._(system, arc);
    WalletCreatedEvent made;
    try {
      // libspiffy makes no mnemonic of its own; one drawn here is kept by
      // libspiffy on the first run and discarded on every later one
      final r = Random.secure();
      final mnemonic = await Mnemonic().generateMnemonic2(
          (_, __) async => bip39English.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join('\n'),
          randomBytes: (n) => Uint8List.fromList(List.generate(n, (_) => r.nextInt(256))));
      made = await side._ask<WalletCreatedEvent>(
          CreateWalletCommand(walletId: walletId, name: 'cloak transparent side', mnemonic: mnemonic),
          (e) => e.walletId == walletId);
    } on Refusal catch (e) {
      if (_already(e.reason)) return side;
      rethrow;
    }
    if (!made.success && !_already(made.error)) {
      throw Refusal('transparent side', 'libspiffy did not make the wallet: ${made.error}');
    }
    return side;
  }

  static bool _already(String? error) => error != null && error.contains('already exists');

  String _id(String what) => '$what-${_r.nextInt(1 << 32).toRadixString(16)}';

  /// Tells the coordinator [message] and waits for the first event of type
  /// [T] that [match] accepts, or an [ErrorEvent] about this wallet.
  Future<T> _ask<T extends CoordinatorEvent>(Message message, bool Function(T e) match) async {
    final events = system.coordinatorEvents;
    if (events == null) throw const Refusal('transparent side', 'libspiffy is not running');
    final answer = Completer<T>();
    final sub = events.listen((e) {
      if (answer.isCompleted) return;
      if (e is T && match(e)) {
        answer.complete(e);
      } else if (e is ErrorEvent && (e.walletId == null || e.walletId == walletId)) {
        answer.completeError(Refusal('transparent side', '${e.source}: ${e.message}'));
      }
    });
    try {
      system.coordinator.tell(message);
      return await answer.future.timeout(answerWithin,
          onTimeout: () => throw Refusal('transparent side', 'libspiffy did not answer within ${answerWithin.inSeconds} s'));
    } finally {
      await sub.cancel();
    }
  }

  Future<BalanceResponse> _balance() {
    final q = _id('balance');
    return _ask<BalanceResponse>(GetBalanceQuery(walletId: walletId, queryId: q), (e) => e.queryId == q);
  }

  @override
  Future<int> spendable() async => (await _balance()).confirmedBalance.toInt();

  /// libspiffy issues a receiving address only with an invoice, and refuses
  /// an invoice for nothing, so this asks for one satoshi. The invoice is
  /// never handed to anyone; the address is what is kept, and a payment to it
  /// of any amount is the wallet's.
  @override
  Future<String> freshAddress() async {
    final made = await _ask<InvoiceCreatedEvent>(
        CreateInvoiceCommand(walletId: walletId, amount: BigInt.one, numberOfAddresses: 1, description: 'cloak'),
        (e) => e.walletId == walletId);
    if (!made.success || made.addresses.isEmpty) {
      throw Refusal('transparent side', 'libspiffy issued no address: ${made.error}');
    }
    return made.addresses.single;
  }

  @override
  Future<ReceiveOutcome> receive(List<int> beef) async {
    final got = await _ask<BEEFValidationResultEvent>(
        ValidateBEEFCommand(walletId: walletId, beefHex: hex.encode(beef)), (e) => e.walletId == walletId);
    if (!got.valid && !got.awaitingHeader) {
      throw Refusal('BEEF', got.error ?? 'libspiffy refused the payment and gave no reason');
    }
    var sats = 0;
    for (final u in got.spendableUTXOs ?? const <Map<String, dynamic>>[]) {
      final v = u['satoshis'] ?? u['value'] ?? u['amount'];
      sats += v is int ? v : int.tryParse('$v') ?? 0;
    }
    return ReceiveOutcome(got.txid ?? '', sats, waitingFor: got.awaitingHeader ? -1 : null);
  }

  @override
  Future<(BuiltTransparent?, Refusal?)> payTo(List<int> lockingScript, int satoshis) async {
    final invoice = _id('covenant');
    final ready = await _ask<PaymentReadyEvent>(
        PayInvoiceCommand(
            walletId: walletId,
            invoiceId: invoice,
            addresses: const [],
            amount: BigInt.zero,
            outputs: [
              PluginOutputSpec(
                  pluginId: CovenantOutputPlugin.id,
                  pluginScriptType: 'covenant',
                  params: {'script': hex.encode(lockingScript)},
                  amount: BigInt.from(satoshis)),
            ]),
        (e) => e.invoiceId == invoice);
    if (!ready.success) return (null, Refusal('funding', ready.error ?? 'libspiffy could not fund it'));
    final beef = BEEF.parse(Uint8List.fromList(ready.beefBytes));
    final txHex = hex.encode(beef.txs.last);
    return (BuiltTransparent(ready.txid, txHex), null);
  }

  @override
  Future<void> release(String txid) async {
    await _ask<DeferredPaymentCancelledEvent>(
        CancelDeferredPaymentCommand(walletId: walletId, txid: txid, reason: 'not broadcast'), (e) => e.txid == txid);
  }

  @override
  Future<Refusal?> broadcast(String txHex, {bool fundedHere = true}) async {
    if (!fundedHere) {
      try {
        final r = await arc.submitTransaction(txHex);
        final status = r.status.name;
        if (status.contains('REJECTED') || status.contains('rejected')) {
          return Refusal('broadcast', 'ARC rejected it: ${r.message ?? status}');
        }
        return null;
      } catch (e) {
        return Refusal('broadcast', 'ARC did not take it: $e');
      }
    }
    final txid = Transaction.fromHex(txHex).id;
    final sent = await _ask<DeferredPaymentBroadcastEvent>(
        BroadcastDeferredPaymentCommand(walletId: walletId, txid: txid), (e) => e.txid == txid);
    if (sent.success) return null;
    return Refusal('broadcast', sent.error ?? 'the network did not take it (${sent.networkStatus})');
  }

  @override
  Future<bool> mined(String txid) async {
    final s = await _ask<DeferredPaymentStatusEvent>(
        CheckDeferredPaymentStatusCommand(walletId: walletId, txid: txid), (e) => e.txid == txid);
    return s.success && s.confirmed;
  }
}
