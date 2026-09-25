import 'package:args/args.dart';
import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../net/timed_transport.dart';
import '../shell/call.dart';
import '../shell/report.dart';
import '../wallet/state_file.dart';
import 'deposit_commands.dart' show submitWaitingDeposits;
import 'settling.dart';
import '../wallet/session.dart';

void syncOptions(ArgParser p) => p.addFlag('from-genesis',
    negatable: false,
    help: 'for a wallet with no stored view: fold the pool\'s whole feed from its first round, rather than '
        'catching up from a head proof and a frontier');

/// `cloak sync`: the pool view, brought to the pool's tip and checked.
///
/// The pool is a server here and never an authority. Everything it says is
/// folded as arithmetic and then checked, once, against the commitment root
/// of a round this wallet proved off the chain with its own headers. A fold
/// that does not check out is not saved: the stored view stays at the round it
/// was last checked to. A fold that could not be checked, because the pool
/// would not prove its head, is saved and said to be unchecked, and nothing
/// will spend from it until it is.
///
/// Nothing is written until the run is whole, so a sync killed part way leaves
/// the view where it was, and running it again reaches the same bytes an
/// uninterrupted run would have. A sync with nothing new to fold writes
/// nothing at all.
Future<void> runSync(Call call) async {
  // what this run has to settle decides whether it needs the keys: a deposit
  // waiting for its covenant needs the transparent side's secrets, and a
  // mined round of this wallet's needs the nullifier key to mark a note spent
  final peek = call.dir.holdsWallet ? await CloakState.open(call.dir) : CloakState();
  final waiting = peek.deposits.any((d) => d.status == 'broadcast');
  final s = await call.open(write: true, keys: waiting || needsKeys(peek));
  if (waiting) await s.transparent();
  final stateBefore = s.state.encode();
  final storeBefore = s.pool == null ? null : s.store.encode();

  // answers an earlier run gave up on, before anything is sent, or this run's
  // requests would take them as their own; and the notices, whose dropped
  // transfers free notes before anything is chosen
  if (s.config.hasPool) await settleStaleReplies(s);
  final notices = s.pool == null ? <int, PoolRoundMined>{} : await drainNotices(s);

  final timed = TimedTransport(await s.transport());
  final tap = FeedTap(timed);
  final limit = FeedLimit(tap);
  final whole = Stopwatch()..start();

  final (client, whyOpen) = await CoordinatorClient.open(limit, timeout: s.config.timeout);
  if (client == null) throw whyOpen!;
  final firstDescriptor = s.pool == null;
  _samePool(s, client.pool);

  final stored = s.view?.encode();
  final view = stored == null ? await _firstView(call, s, client) : PoolView.decode(stored, shape: client.shape);
  final startRound = s.view?.round ?? 0;

  // fold the feed: the same bytes every follower reads, one block root a
  // round, standing at each round something of this wallet's waits on long
  // enough to keep the pool's frontier there
  final awaited = awaitedRounds(s.state);
  void keep() {
    final cp = view.checkpoint;
    if (cp != null && awaited.contains(view.round)) s.state.checkpoints[view.round] = cp.encode();
  }

  keep();
  Refusal? stopped;
  for (final target in [...(awaited.where((r) => r > view.round).toList()..sort()), null]) {
    limit.upTo = target;
    final progress = await client.follow(view);
    if (progress.disagreement != null) {
      throw Refusal('announcement',
          'the pool contradicted itself about round ${progress.disagreement!.round}: ${progress.disagreement!.what}; '
          'nothing was saved');
    }
    keep();
    if (progress.stopped != null) {
      stopped = progress.stopped;
      break;
    }
  }
  limit.upTo = null;

  final checker = PaymentChecker(pool: client.pool, headers: await s.headerChecker());
  if (stopped != null) {
    if (stopped.step != 'round' || _announcedFrom(stopped) <= view.round) {
      throw Refusal(stopped.step, '${stopped.reason}; the pool view was left at round $startRound');
    }
    // the feed no longer reaches this view's next round: catch up by the
    // pool's published runs, which folds every round and so brings a held
    // note's path forward with it
    await _bringForward(s, client, view, checker, startRound);
  } else {
    try {
      await _check(s, client, view, checker, startRound, changed: () => _changed(view, stored, firstDescriptor));
    } on Refusal {
      _say(call.report, view, folded: view.round - startRound, from: startRound, whole: whole, timed: timed);
      rethrow;
    }
  }
  _live(s, tap, view);
  s.view = view;
  if (s.hasKeys) await settleRounds(call, s, notices);
  final moved = _changed(view, stored, firstDescriptor) ||
      s.state.encode() != stateBefore ||
      (storeBefore != null && !_eq(s.store.encode(), storeBefore));
  if (moved) await s.save();
  _say(call.report, view, folded: view.round - startRound, from: startRound, whole: whole, timed: timed);
  if (waiting) await submitWaitingDeposits(call, s);
}

/// Records the announcement of the round the view now stands at, whose
/// transaction's PP3 a deposit names. True when it moved.
///
/// Before round 1 there is no announcement: the live round is the genesis,
/// and its PP3 is the issuance's, the transaction the descriptor this wallet
/// pinned names. A new pool's first deposit names it.
bool _live(Session s, FeedTap tap, PoolView view) {
  if (view.round == 0) {
    final issuance = s.poolOrRefuse.issuance;
    if (s.state.liveRound == 0 && _eq(s.state.liveRoundTxId ?? const [], issuance)) return false;
    s.state
      ..liveRound = 0
      ..liveRoundTxId = issuance;
    return true;
  }
  for (final e in tap.entries.reversed) {
    try {
      final m = PoolMessage.decode(e.bytes);
      if (m is PoolAnnouncement && m.round == view.round) {
        if (s.state.liveRound == m.round && _eq(s.state.liveRoundTxId ?? const [], m.roundTxId)) return false;
        s.state
          ..liveRound = m.round
          ..liveRoundTxId = m.roundTxId;
        return true;
      }
    } catch (_) {
      // an entry the client already refused or passed over
    }
  }
  return false;
}

bool _changed(PoolView view, List<int>? stored, bool firstDescriptor) =>
    firstDescriptor || stored == null || !_eq(view.encode(), stored);

/// Checks the fold against a round proved off the chain.
///
/// A check that fails saves nothing. A head the pool will not prove leaves a
/// checked view as it is and an unchecked fold saved but unchecked, since the
/// rounds folded are still rounds the next check will not have to fold again.
/// A head ahead of the fold is caught up to by the pool's published runs.
Future<void> _check(Session s, CoordinatorClient client, PoolView view, PaymentChecker checker, int startRound,
    {required bool Function() changed}) async {
  final (head, whyHead) = await client.headProof(checker);
  if (head == null) {
    if (!_unproved.contains(whyHead!.step)) {
      throw Refusal(whyHead.step, '${whyHead.reason}; the pool view was not saved');
    }
    if (view.checkedTo == view.round) {
      s.call.report.say('the pool did not prove its head (${whyHead.step}), so this is as current as its feed says');
      return;
    }
    final saved = changed();
    if (saved) await _save(s, view);
    throw Refusal('head proof',
        'folded to round ${view.round}${saved ? ' and saved' : ''}, checked to round ${view.checkedTo}: the pool did '
        'not prove its head (${whyHead.reason}), so the fold is not checked and nothing will spend from it until a '
        'round proved off the chain agrees with it');
  }
  if (head.round > view.round) {
    await _bringForward(s, client, view, checker, startRound);
    return;
  }
  if (head.round < view.round) {
    final saved = changed();
    if (saved) await _save(s, view);
    throw Refusal('head proof',
        'folded to round ${view.round}${saved ? ' and saved' : ''}; the pool proved round ${head.round}, behind the '
        'rounds it announced, so the fold is not checked yet');
  }
  final whyCheck = view.check(head.round, head.cmRoot);
  if (whyCheck != null) throw Refusal(whyCheck.step, '${whyCheck.reason}; the pool view was left where it was');
}

/// The steps a head proof comes back refused at when the pool could not, or
/// would not yet, prove its head: silence, and three of the protocol's four
/// refusal names. Each leaves a fold unchecked rather than refused.
const _unproved = {'transport', 'notServed', 'notYet', 'unavailable'};

/// The descriptor the pool's feed begins with must be the one this wallet's
/// state was built against, and its shape must be the stored shape.
void _samePool(Session s, PoolDescriptor pool) {
  final (shape, why) = PoolShape.forPool(pool);
  if (shape == null) throw why!;
  final known = s.pool;
  if (known == null) {
    s.state.descriptor = pool.encode();
    return;
  }
  final mismatch = PoolShape.forPool(known).$1!.sameSizeAs(pool.leavesPerRound);
  if (mismatch != null) {
    throw Refusal(mismatch.step,
        'this wallet\'s note store and pool view were built for ${known.leavesPerRound} leaves a round and the '
        'pool\'s descriptor now says ${pool.leavesPerRound}; nothing was written');
  }
  if (known != pool) {
    throw const Refusal('descriptor',
        'the pool\'s feed now begins with a different descriptor from the one this wallet was built against, so it '
        'is not the same pool; nothing was written');
  }
}

/// A wallet with no view either catches up from a head proof and a frontier,
/// or, when asked, folds the feed from the genesis. It never falls back from
/// the first to the second on its own: reading a pool's whole feed is a
/// decision a person makes, not a thing that happens because a server would
/// not answer.
Future<PoolView> _firstView(Call call, Session s, CoordinatorClient client) async {
  if (call.flag('from-genesis')) return PoolView.atGenesis(client.shape);
  final checker = PaymentChecker(pool: client.pool, headers: await s.headerChecker());
  final (view, why) = await client.current(checker);
  if (view == null) {
    await _refuseUndelivered(s, why!, 'this wallet stands at round 0 and no pool view was written');
    if (why.step == 'transport' || why.step == 'notServed') {
      throw Refusal('catch-up',
          'the pool does not serve catch-up (${why.reason}); this wallet stands at round 0. Run cloak sync '
          '--from-genesis to fold the pool\'s whole feed instead');
    }
    throw Refusal(why.step, '${why.reason}; no pool view was written');
  }
  return view;
}

/// Refuses [why] as the pool going unasked when the transport could not
/// deliver the frame that asked it. Silence from a pool that was asked is its
/// answer; a frame the server never took is not, and saying the pool does not
/// serve catch-up then sends a person to fold its whole feed for nothing.
Future<void> _refuseUndelivered(Session s, Refusal why, String where) async {
  if (why.step != 'transport') return;
  final unreachable = (await s.mailbox())?.unreachable;
  if (unreachable == null) return;
  throw Refusal('transport',
      'the pool could not be asked: $unreachable. Nothing was learned about the pool; $where. Run cloak sync again');
}

/// The round an out-of-order refusal says the feed jumped to, or -1.
int _announcedFrom(Refusal r) {
  final m = RegExp(r'this one is for round (\d+)').firstMatch(r.reason);
  return m == null ? -1 : int.parse(m.group(1)!);
}

Future<void> _bringForward(Session s, CoordinatorClient client, PoolView view, PaymentChecker checker, int startRound) async {
  final why = await client.bringForward(view, checker);
  if (why == null) return;
  await _refuseUndelivered(s, why, 'this wallet stands at round $startRound');
  if (why.step == 'transport' || why.step == 'notServed') {
    throw Refusal('catch-up',
        'the pool\'s feed does not reach round ${startRound + 1} and the pool does not serve catch-up '
        '(${why.reason}); this wallet stands at round $startRound');
  }
  throw Refusal(why.step, '${why.reason}; the pool view was left at round $startRound');
}

Future<void> _save(Session s, PoolView view) async {
  s.view = view;
  await s.save(store: false);
}

void _say(Report r, PoolView view,
    {required int folded, required int from, required Stopwatch whole, required TimedTransport timed}) {
  whole.stop();
  final pool = whole.elapsedMilliseconds - timed.elapsed.inMilliseconds;
  r
    ..add('folded', folded, folded == 0 ? 'already current: no rounds folded' : 'folded $folded rounds from round $from')
    ..add('round', view.round, 'the pool view stands at round ${view.round}')
    ..add('checkedTo', view.checkedTo, 'checked to round ${view.checkedTo}')
    ..add('clockMs', {'whole': whole.elapsedMilliseconds, 'transport': timed.elapsed.inMilliseconds, 'folding': pool},
        'clock: ${whole.elapsedMilliseconds} ms, of which the transport ${timed.elapsed.inMilliseconds} ms and '
        'folding and checking $pool ms');
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
