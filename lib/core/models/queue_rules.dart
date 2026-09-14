/// When a driver's place in the queue is kept, and when it is lost.
///
/// Three rules, all of them about fairness at the terminal:
///
///   * A driver who leaves the terminal leaves the queue. Checking in used
///     to be the last time position was considered, so a driver could check
///     in, drive away, and still be sent the next passenger from a terminal
///     they were nowhere near.
///   * A passenger cancelling does not cost the driver their place: they
///     were waiting, and did nothing wrong. Their entry used to be
///     cancelled outright, sending them to the back of the queue.
///   * A driver who never answers does not hold a passenger indefinitely.
///     Nothing timed out a dispatch, so an ignored booking waited forever.
///
/// Pure, so the thresholds are tested without a device or a network.
library;

// The geometry lives with the other boundary work; the terminal rules below
// are what this file is for.
export 'boundary.dart' show metersOutsideBoundary;

/// How far outside the terminal's boundary counts as having left it.
///
/// Generous: GPS in town drifts, and a tricycle parked at the edge of a
/// terminal may read as just outside it.
const double kQueueExitMeters = 80;

/// Consecutive readings outside before the place is given up, so one stray
/// reading does not cost a driver their turn.
const int kQueueExitFixes = 3;

/// How long a dispatched driver has to accept before the passenger is
/// offered another driver.
const Duration kAcceptWindow = Duration(seconds: 90);

/// Whether a waiting driver has left the terminal for good.
bool leavesQueue({
  required double metersOutside,
  required int consecutiveOutside,
}) => metersOutside > kQueueExitMeters && consecutiveOutside >= kQueueExitFixes;

/// Whether a queue entry may be given up because the driver has left the
/// terminal.
///
/// Only one that is still waiting. A driver who has been dispatched or has
/// accepted is *supposed* to leave — they are going to the passenger — and
/// taking their entry away there strands the booking: it stays REQUESTED,
/// pointing at a cancelled entry, and the trip never appears on the
/// driver's screen. That happened, because the check ran against local
/// state that was seconds out of date, and a second device signed in as the
/// same driver had its own idea of where they were.
bool mayGiveUpPlace(String? entryStatus) => entryStatus == 'waiting';

/// Whether a dispatched driver has had long enough to answer.
bool waitedLongEnoughToReassign(Duration sinceDispatch) =>
    sinceDispatch >= kAcceptWindow;

/// The first driver in queue order who has not already refused this trip.
///
/// Refusing an out-of-town trip is a driver's right and costs them nothing,
/// but the passenger must not be handed straight back to them: without this,
/// the same driver at the front of the queue would be offered the trip again
/// and again. Returns null when everyone waiting has refused.
T? firstNotDeclined<T>(
  Iterable<T> queueInOrder,
  Set<String> declinedBy,
  String Function(T) driverIdOf,
) {
  for (final entry in queueInOrder) {
    if (!declinedBy.contains(driverIdOf(entry))) return entry;
  }
  return null;
}
