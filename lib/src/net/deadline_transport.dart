import 'dart:async';

import 'package:libcloak/libcloak.dart';

/// A transport whose feed reads cannot outlast twice the configured timeout.
///
/// libcloak already holds a request to twice its deadline, so a transport
/// that never answers a submission leaves it unanswered rather than hung.
/// Opening a client and following the feed are feed reads, and libcloak puts
/// no deadline on those, so this does: a transport is somebody else's code,
/// and a wallet that waits as long as a transport feels like is a wallet a
/// transport can hang. Requests pass through untouched, because turning a
/// slow submission into a failed send would release a note that may be in a
/// round.
class DeadlineTransport implements Transport {
  final Transport inner;
  final Duration timeout;

  DeadlineTransport(this.inner, this.timeout);

  Duration get hardDeadline => timeout * 2;

  @override
  Future<List<int>> request(List<int> frame, {Duration timeout = const Duration(seconds: 30)}) =>
      inner.request(frame, timeout: timeout);

  @override
  Future<List<FeedEntry>> readFeed(int from, {int max = 100}) =>
      inner.readFeed(from, max: max).timeout(hardDeadline,
          onTimeout: () => throw TransportFailure(
              'readFeed', 'the transport did not come back within ${hardDeadline.inMilliseconds} ms'));
}
