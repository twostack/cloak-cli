import 'package:tstokenlib/tstokenlib.dart' show PoolMessage, PoolAnnouncement;
import 'package:libcloak/libcloak.dart';

/// A transport that keeps a stopwatch on the one it wraps.
///
/// `cloak sync` reports the time spent folding apart from the time spent
/// waiting on the pool, because the two are bounded separately and missed for
/// different reasons: a slow fold is this program's problem, a slow feed is
/// the pipe's. This adds nothing to what crosses the port and reads none of it.
class TimedTransport implements Transport {
  final Transport inner;
  final Stopwatch _clock = Stopwatch();

  TimedTransport(this.inner);

  /// Time spent inside the wrapped transport.
  Duration get elapsed => _clock.elapsed;

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) async {
    _clock.start();
    try {
      return await inner.request(frame, timeout: timeout);
    } finally {
      _clock.stop();
    }
  }

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) async {
    _clock.start();
    try {
      return await inner.readFeed(from, max: max);
    } finally {
      _clock.stop();
    }
  }
}

/// A transport that keeps the feed entries read through it.
///
/// `cloak sync` needs one thing the client does not hand back: the live
/// round's transaction id, which a deposit's covenant names. The entries are
/// the same bytes every follower reads, and they are decoded after the fold,
/// by the command, never by the transport.
class FeedTap implements Transport {
  final Transport inner;
  final List<FeedEntry> entries = [];

  FeedTap(this.inner);

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) =>
      inner.request(frame, timeout: timeout);

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) async {
    final got = await inner.readFeed(from, max: max);
    entries.addAll(got);
    return got;
  }
}

/// A transport whose feed stops at a round, so a sync can stand its fold at
/// that round.
///
/// A leaf's path above its block is made from the pool's frontier at the
/// leaf's own round, and a fold that has moved past that round cannot give
/// the frontier back. So `cloak sync` folds to each round something of the
/// wallet's is waiting on, keeps the frontier there, and folds on. This hands
/// the client the feed up to and including [upTo]'s announcement and nothing
/// after it; the client asks again from where it stopped when the limit is
/// lifted. The entries are decoded here, in the command's code, never in the
/// transport underneath.
class FeedLimit implements Transport {
  final Transport inner;
  int? upTo;

  FeedLimit(this.inner);

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) =>
      inner.request(frame, timeout: timeout);

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) async {
    final got = await inner.readFeed(from, max: max);
    final limit = upTo;
    if (limit == null) return got;
    final out = <FeedEntry>[];
    for (final e in got) {
      if (_roundOf(e.bytes) case final r? when r > limit) break;
      out.add(e);
    }
    return out;
  }

  static int? _roundOf(List<int> bytes) {
    try {
      final m = PoolMessage.decode(bytes);
      return m is PoolAnnouncement ? m.round : null;
    } catch (_) {
      return null;
    }
  }
}
