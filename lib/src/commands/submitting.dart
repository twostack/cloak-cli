import 'package:libcloak/libcloak.dart';
import 'package:tstokenlib/tstokenlib.dart';

import '../wallet/session.dart';
import 'settling.dart';

/// What came of a submission, and how long the pool took to say so.
class Sent {
  final SubmissionOutcome outcome;
  final Duration network;
  const Sent(this.outcome, this.network);
}

/// Sends [submission], which spends [note], with the note reserved **and that
/// reservation saved** before the frame leaves.
///
/// libcloak's client reserves a note in memory before it sends; this program
/// also writes the reservation down first, so neither a second process nor a
/// crash between the send and the answer can pick the same note. The answer
/// alone moves it afterwards: released where the transfer is known not to be
/// in a round (refused, expired, unsent), left reserved otherwise. [record]
/// is called with the outcome before the final save, so a command's own
/// state moves in the same write; it is called with null when the client
/// could not even be opened, and nothing was sent.
Future<Sent> submitReserved(
  Session s, {
  required HeldNote note,
  required PoolSubmission submission,
  required Future<void> Function() beforeSend,
  required Future<void> Function(SubmissionOutcome? outcome) record,
}) async {
  // a late answer to an earlier run's submission would otherwise be taken as
  // this one's
  await settleStaleReplies(s);
  final whyReserve = s.store.reserve(note);
  if (whyReserve != null) throw whyReserve;
  await beforeSend();
  await s.save(view: false);

  Future<Never> unsent(Refusal why) async {
    // nothing was sent, so the note was never spent
    s.store.release(note);
    await record(null);
    await s.save(view: false);
    throw Refusal(why.step, '${why.reason}; nothing was sent and the note is released');
  }

  final network = Stopwatch()..start();
  final (client, whyOpen) = await CoordinatorClient.open(await s.transport(), timeout: s.config.timeout);
  if (client == null) return unsent(whyOpen!);
  if (client.pool != s.poolOrRefuse) {
    return unsent(const Refusal('descriptor', 'the pool answering is not the pool this wallet follows'));
  }
  final outcome = await client.send(submission);
  network.stop();
  if (outcome.isSettled) s.store.release(note);
  await record(outcome);
  await s.save(view: false);
  return Sent(outcome, network.elapsed);
}
