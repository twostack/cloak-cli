import 'dart:io';

import 'package:args/args.dart';
import 'package:convert/convert.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart' show PoolHash;

import '../shell/call.dart';
import '../wallet/sealed_store.dart';
import '../wallet/session.dart';
import '../wallet/state_file.dart';

/// How an asset is named to a person: BSV by name, anything else by its
/// lanes.
String assetName(List<int> asset) =>
    PoolHash.isBsv(asset) ? 'BSV' : [for (final l in asset) l.toRadixString(16).padLeft(8, '0')].join();

/// The round balances are read against when no network is asked: the last
/// round this wallet folded. A balance never asks the pool for its tip,
/// because a balance is a question about what the wallet holds and the wallet
/// can answer it alone.
int _tip(Session s) => s.view?.round ?? 0;

/// `cloak balance`: three lines per asset, never added up, and the BSV held
/// on the transparent side, waiting to be deposited.
///
/// Spendable, reserved and stale are kept apart because a single total hides
/// the two things that stop a payment: money already in flight, and money the
/// view has fallen too far behind to anchor. It reads the note store, the
/// pool view and the wallet state and nothing else: no passphrase, no chain,
/// no pool. The transparent amount is the one recorded when a command last
/// opened that side, which every command that moves its coins does.
///
/// A wallet whose transparent side exists and has no amount recorded, one
/// that received before amounts were recorded, is read once: the side is
/// opened from its store, offline, which asks for the passphrase, and the
/// amount is recorded for every balance after it.
Future<void> runBalance(Call call) async {
  if (call.dir.holdsWallet &&
      (await CloakState.open(call.dir)).transparentSats == null &&
      File(SealedStore.pathIn(call.dir)).existsSync()) {
    final w = await call.open(write: true, keys: true);
    await w.transparent(offline: true);
    await w.save(view: false, store: false);
    await w.close();
  }
  final s = await call.open();
  final r = call.report;
  final sats = s.state.transparentSats;
  r.quiet('transparent', sats);
  if (sats != null && sats > 0) {
    r.say('transparent: $sats satoshis of BSV, not yet in the pool; cloak deposit moves it in');
  }
  final view = s.view;
  if (s.pool == null || view == null) {
    r
      ..add('assets', const [], 'nothing held in the pool: this wallet has not synced with its pool yet')
      ..quiet('round', 0);
    return;
  }
  final lines = s.store.balances(view: view, tip: _tip(s));
  r.add('round', view.round, 'as of round ${view.round}, checked to round ${view.checkedTo}');
  r.quiet('checkedTo', view.checkedTo);
  final assets = <Map<String, Object?>>[];
  for (final b in lines) {
    assets.add({
      'asset': assetName(b.asset),
      'spendable': b.spendable,
      'reserved': b.reserved,
      'stale': b.stale,
      'largestSpendable': b.largestSpendable,
      'notes': b.spendableNotes.length + b.reservedNotes.length + b.staleNotes.length,
    });
    r
      ..say('${assetName(b.asset)}:')
      ..say('  spendable  ${b.spendable} (largest single note ${b.largestSpendable})')
      ..say('  reserved   ${b.reserved}')
      ..say('  stale      ${b.stale}${b.whyStale == null ? '' : ': ${b.whyStale!.step}'}');
  }
  if (lines.isEmpty) r.say('nothing held');
  r.quiet('assets', assets);
}

/// `cloak notes`: every note held, with its leaf, round, value and state.
Future<void> runNotes(Call call) async {
  final s = await call.open();
  final r = call.report;
  final view = s.view;
  if (s.pool == null || view == null) {
    r.add('notes', const [], 'no notes: this wallet has not synced with its pool yet');
    return;
  }
  final out = <Map<String, Object?>>[];
  for (final n in s.store.notes) {
    final (canSpend, why) = n.isProven ? Balance.anchorable(n, view: view, tip: _tip(s)) : (false, null);
    out.add({
      'leaf': n.position,
      'round': n.round,
      'value': n.value,
      'asset': assetName(n.asset),
      'state': n.state.name,
      'spendable': canSpend,
      if (why != null) 'why': why.step,
    });
    r.say('leaf ${n.position}  round ${n.round}  ${n.value} ${assetName(n.asset)}  ${n.state.name}'
        '${n.isProven && !canSpend ? '  stale: ${why?.step}' : ''}');
  }
  if (out.isEmpty) r.say('no notes');
  r.quiet('notes', out);
}

void journalOptions(ArgParser p) =>
    p.addOption('invoice', valueHelp: 'id', help: 'only the entries of one invoice, by its id in hex');

/// `cloak journal`: the record, whole or for one invoice.
///
/// An entry file that does not read is reported by name beside the rest,
/// never skipped and never repaired: the one thing a record of what you paid
/// must not do is quietly lose a line, and the one thing a reader of it must
/// not do is rewrite what it could not read.
Future<void> runJournal(Call call) async {
  final s = await call.open();
  final j = await s.journal();
  final id = call.option('invoice');
  final JournalRead read;
  if (id == null) {
    read = await j.read();
  } else {
    final List<int> bytes;
    try {
      bytes = hex.decode(id);
    } on FormatException {
      throw UsageError('--invoice is an invoice id in hex, not "$id"');
    }
    if (bytes.length != Invoice.idLength) {
      throw UsageError('--invoice is ${Invoice.idLength} bytes of hex, and "$id" is ${bytes.length}');
    }
    read = await j.thread(bytes);
  }
  final r = call.report;
  final entries = <Map<String, Object?>>[];
  for (final e in read.entries) {
    entries.add({
      'sequence': e.sequence,
      'kind': e.kind.name,
      'clock': e.at.toIso8601String(),
      'invoice': hex.encode(e.invoiceId),
      'outcome': e.outcome,
      'reason': e.reason,
      'amount': e.amount,
      'round': e.round,
      'leaf': e.position,
      'note': e.note,
    });
    r.say('#${e.sequence} [clock ${e.at.toIso8601String()}] ${e.kind.name}'
        '${e.outcome.isEmpty ? '' : ' (${e.outcome})'} invoice ${hex.encode(e.invoiceId)}'
        '${e.reason.isEmpty ? '' : ' at "${e.reason}"'}: ${e.note}');
  }
  final refused = <Map<String, Object?>>[];
  for (final why in read.refused) {
    refused.add({'step': why.step, 'reason': why.reason});
    r.say('refused at "${why.step}": ${why.reason}');
  }
  if (entries.isEmpty && refused.isEmpty) r.say('the journal is empty');
  r
    ..quiet('entries', entries)
    ..quiet('refused', refused);
}
