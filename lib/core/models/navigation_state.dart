/// Navigation: routes, ETA, deviation and rerouting decisions.
///
/// Navigation runs *alongside* the trip state machine, never in place of it.
/// Reaching a destination on the map does not complete a trip — it only tells
/// the driver they have arrived, and the driver's confirmation is what moves
/// [TripStatus]. Nothing in this file writes trip state.
///
/// Everything here is pure so the reroute and deviation rules can be tested
/// without a network or a map.
///
/// ## What is real and what is modelled
///
/// Routes, distances, durations and turn instructions come from OSRM and are
/// real. Durations are *free-flow* — OSRM has no live traffic feed, so they
/// are what the roads allow when clear, not what they are doing right now.
///
/// The congestion adjustment below is this app's own model, derived from
/// user reports. It is a real signal from real people, but it is sparse and
/// it is not measured traffic. See [RouteScore.isEstimate].
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'road_report.dart';
import 'traffic_segment.dart' show nearestOnWay;
import 'trip_state.dart';

/// Which leg of the journey the driver is navigating.
///
/// Derived from the trip state rather than stored, so navigation can never
/// disagree with the authoritative trip status.
enum NavigationPhase {
  /// Nothing to navigate — no accepted trip, or the trip is over.
  idle,

  /// Driving to collect the passenger.
  toPickup,

  /// At the pickup, waiting on the passenger and payment.
  atPickup,

  /// Carrying the passenger to their destination.
  toDestination;

  static NavigationPhase forTrip(TripStatus status) => switch (status) {
    TripStatus.requested ||
    TripStatus.driverAccepted ||
    TripStatus.driverOnTheWay => NavigationPhase.toPickup,
    TripStatus.driverArrived ||
    TripStatus.readyToStart => NavigationPhase.atPickup,
    TripStatus.tripInProgress => NavigationPhase.toDestination,
    TripStatus.tripCompleted || TripStatus.cancelled => NavigationPhase.idle,
  };

  bool get isNavigating =>
      this == NavigationPhase.toPickup || this == NavigationPhase.toDestination;

  String get driverLabel => switch (this) {
    NavigationPhase.idle => '',
    NavigationPhase.toPickup => 'Navigating to passenger',
    NavigationPhase.atPickup => 'At pickup',
    NavigationPhase.toDestination => 'Navigating to destination',
  };
}

/// One turn instruction along a route.
class NavStep {
  /// Road being joined or followed, as OSM names it. May be empty for
  /// unnamed roads, which is common on tricycle routes.
  final String road;

  /// OSRM manoeuvre type, e.g. `turn`, `roundabout`, `arrive`.
  final String maneuver;

  /// `left`, `right`, `straight`, and similar. Null for arrive/depart.
  final String? modifier;

  final double distanceMeters;

  /// A ready-made instruction from the router, when it supplies one.
  ///
  /// TomTom returns phrasing like "You have arrived at L. Beltran Street",
  /// which names roads it knows about and we would otherwise have to guess
  /// at. Preferred over the synthesised text when present.
  final String? text;

  const NavStep({
    required this.road,
    required this.maneuver,
    required this.distanceMeters,
    this.modifier,
    this.text,
  });

  /// A short spoken/displayed instruction.
  ///
  /// Deliberately plain: a driver glancing at a phone needs the verb and the
  /// road, not a sentence.
  String get instruction {
    final supplied = text?.trim();
    if (supplied != null && supplied.isNotEmpty) return supplied;

    final where = road.isEmpty ? '' : ' onto $road';
    return switch (maneuver) {
      'depart' => road.isEmpty ? 'Start driving' : 'Head along $road',
      'arrive' => 'You have arrived',
      'roundabout' || 'rotary' => 'Take the roundabout$where',
      'merge' => 'Merge$where',
      'fork' => switch (modifier) {
        'left' => 'Keep left$where',
        'right' => 'Keep right$where',
        _ => 'Keep going$where',
      },
      'new name' || 'continue' => road.isEmpty
          ? 'Continue straight'
          : 'Continue on $road',
      _ => switch (modifier) {
        'left' || 'slight left' || 'sharp left' => 'Turn left$where',
        'right' || 'slight right' || 'sharp right' => 'Turn right$where',
        'uturn' => 'Make a U-turn',
        _ => road.isEmpty ? 'Continue' : 'Continue on $road',
      },
    };
  }
}

/// The manoeuvre ahead of the driver, and the distance still to run.
class UpcomingTurn {
  final NavStep step;

  /// Distance from the driver to the manoeuvre.
  final double metersAway;

  const UpcomingTurn({required this.step, required this.metersAway});

  bool get isArrival => step.maneuver == 'arrive';

  /// Identifies the manoeuvre itself rather than this snapshot of it.
  ///
  /// The route is rebuilt on every GPS fix, so the same physical turn arrives
  /// as a fresh object several times a minute. Without this, guidance would
  /// announce one turn over and over.
  String get key => '${step.maneuver}|${step.modifier ?? ''}|${step.road}';

  @override
  String toString() => '${step.instruction} in ${metersAway.round()} m';
}

/// A route returned by the routing service.
class NavRoute {
  /// Road geometry, in order.
  final List<LatLng> points;

  final double distanceMeters;

  /// OSRM's free-flow estimate. Not traffic-aware — see the library note.
  final double durationSeconds;

  final List<NavStep> steps;

  /// How this route was obtained, for the UI to label honestly.
  final String source;

  /// Measured congestion already included in [durationSeconds], when the
  /// router provides it. Zero from OSRM, which has no traffic feed at all.
  final double trafficDelaySeconds;

  const NavRoute({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    this.steps = const [],
    this.source = 'osrm',
    this.trafficDelaySeconds = 0,
  });

  /// Whether [durationSeconds] reflects real traffic rather than free flow.
  ///
  /// This decides whether the app's own traffic model should be applied on
  /// top. Doing both would count the same congestion twice.
  bool get isTrafficAware => source == 'tomtom';

  /// A straight line, used only when routing is unreachable. Flagged so the
  /// UI can say the route is unavailable rather than draw a fake road.
  factory NavRoute.straightLine(LatLng from, LatLng to) {
    final metres = const Distance().as(LengthUnit.Meter, from, to);
    return NavRoute(
      points: [from, to],
      distanceMeters: metres,
      // A tricycle in town averages roughly 20 km/h; this is a placeholder
      // for a failed lookup, not a routing result.
      durationSeconds: metres / (20 * 1000 / 3600),
      source: 'straight-line',
    );
  }

  bool get isRealRoute => source != 'straight-line';

  NavStep? get nextStep => steps.isEmpty ? null : steps.first;

  /// The manoeuvre the driver is approaching, and how far off it is.
  ///
  /// Not the same as [nextStep]. A router's first instruction is "depart",
  /// and its distance is how far to drive *before* the first real turn, so
  /// showing it verbatim tells a driver "start driving, 1.9 km" for the whole
  /// leg and never names the turn coming up. What a driver needs is the next
  /// manoeuvre and the distance to it, which is what this pairs.
  ///
  /// Routes are re-fetched from the driver's live position, so the distance
  /// shrinks on its own as they approach.
  UpcomingTurn? get upcoming {
    var travelled = 0.0;
    for (final step in steps) {
      if (step.maneuver != 'depart') {
        return UpcomingTurn(step: step, metersAway: travelled);
      }
      travelled += step.distanceMeters;
    }
    return null;
  }

  /// Identifies a route by the road it describes rather than by object
  /// identity.
  ///
  /// The candidates are re-fetched and rebuilt on every recalculation, so
  /// two NavRoute instances describing the same road are never `identical`.
  /// Comparing by reference made the UI mark the wrong option as active the
  /// moment the choices refreshed — the header would say one route while the
  /// radio showed the other.
  String get key {
    if (points.isEmpty) return 'empty';
    final first = points.first, last = points.last;
    return '${points.length}'
        ':${first.latitude.toStringAsFixed(5)},'
        '${first.longitude.toStringAsFixed(5)}'
        ':${last.latitude.toStringAsFixed(5)},'
        '${last.longitude.toStringAsFixed(5)}'
        ':${distanceMeters.round()}';
  }

  bool sameRouteAs(NavRoute? other) => other != null && key == other.key;
}

/// A route with this app's congestion model applied.
class RouteScore {
  final NavRoute route;

  /// Reports judged to be on this route.
  final List<RoadReport> incidentsOnRoute;

  /// Seconds added for the reported conditions.
  final double penaltySeconds;

  const RouteScore({
    required this.route,
    required this.incidentsOnRoute,
    required this.penaltySeconds,
  });

  /// Free-flow duration plus the modelled delay.
  double get adjustedSeconds => route.durationSeconds + penaltySeconds;

  /// True when reports moved the estimate, meaning the number is partly
  /// this app's model rather than purely OSRM's. The UI says "estimated"
  /// in that case rather than implying measured traffic.
  bool get isEstimate => penaltySeconds > 0;

  /// A route the driver should not be sent down at all.
  ///
  /// No trust check here: [incidentsOn] already dropped anything expired or
  /// dismissed, judged against the same instant. Re-checking would reach for
  /// the wall clock and could disagree with the list it is filtering.
  bool get isBlocked =>
      incidentsOnRoute.any((r) => r.type == ReportType.roadClosure);

  /// The worst thing reported on this route, for labelling the choice.
  ReportType? get worstIncident {
    ReportType? worst;
    for (final r in incidentsOnRoute) {
      if (worst == null || r.type.severity > worst.severity) worst = r.type;
    }
    return worst;
  }

  /// A short reason the driver can weigh one route against another by.
  ///
  /// Says "reported" rather than stating conditions as fact, because that is
  /// what this is — other people's reports, not a traffic measurement.
  String get conditionLabel {
    if (isBlocked) return 'Road reported closed';
    final worst = worstIncident;
    if (worst == null) return 'Nothing reported';
    final count = incidentsOnRoute.length;
    return count == 1
        ? '${worst.label} reported'
        : '${worst.label} + ${count - 1} more reported';
  }
}

/// Two routes offered to the driver, best first.
///
/// Deliberately capped: the spec asks for a recommendation and at most one
/// alternative, because a driver choosing between five lines on a phone is
/// worse off than one being given a good answer.
class RouteChoices {
  final RouteScore recommended;
  final RouteScore? alternative;

  const RouteChoices({required this.recommended, this.alternative});

  bool get hasAlternative => alternative != null;

  /// How much longer the alternative takes. Negative would mean it is
  /// quicker, which cannot happen since the quicker one is recommended.
  Duration? get alternativeCost => alternative == null
      ? null
      : Duration(
          seconds:
              (alternative!.adjustedSeconds - recommended.adjustedSeconds)
                  .round(),
        );
}

/// How much slower an alternative may be before it stops being a choice.
///
/// Alternatives are forced by routing via an offset waypoint, because the
/// public OSRM server returns only one route. That reliably produces a
/// *different* road, but not necessarily a sensible one — left unfiltered it
/// offers things like a 19-minute loop against a clear 12-minute run, which
/// no driver would take and which makes the whole panel look broken.
const double kMaxDetourFraction = 0.35;

/// Picks what to offer the driver from everything the router found.
///
/// The best usable route is recommended. An alternative is only offered when
/// it is genuinely worth weighing: meaningfully different from the
/// recommendation, and not absurdly slower than it.
///
/// The exception is when the recommended route has something reported on it.
/// Then a longer way round is exactly what the driver wants to see, however
/// much slower it looks on paper, because the estimate for the short way is
/// the part in doubt.
RouteChoices? buildChoices(
  List<RouteScore> candidates, {
  Duration minDifference = const Duration(seconds: 30),
  double maxDetourFraction = kMaxDetourFraction,
}) {
  final best = chooseBest(candidates);
  if (best == null) return null;

  // Something reported on the recommended route makes any usable detour
  // worth showing.
  final recommendedHasTrouble =
      best.isBlocked || best.incidentsOnRoute.isNotEmpty;
  final ceiling = best.adjustedSeconds * (1 + maxDetourFraction);

  RouteScore? alternative;
  for (final c in candidates) {
    // Identity is right here: the best route is one of these objects. The
    // value comparison is for the UI, which sees rebuilt objects.
    if (identical(c, best)) continue;
    if (c.isBlocked) continue;
    if ((c.adjustedSeconds - best.adjustedSeconds).abs() <
        minDifference.inSeconds) {
      continue;
    }
    if (!recommendedHasTrouble && c.adjustedSeconds > ceiling) continue;
    if (alternative == null ||
        c.adjustedSeconds < alternative.adjustedSeconds) {
      alternative = c;
    }
  }
  return RouteChoices(recommended: best, alternative: alternative);
}

/// How close to the line a report has to be to count as "on this route".
const double kIncidentOnRouteMeters = 45;

/// Seconds of delay attributed to a report sitting on the route.
///
/// These are deliberate, declared assumptions rather than measurements —
/// there is no live traffic feed to calibrate them against. They only have
/// to be good enough to rank one real route against another.
double incidentDelaySeconds(ReportType type) => switch (type) {
  ReportType.roadClosure => 1800,
  ReportType.accident => 480,
  ReportType.flooding => 420,
  ReportType.trafficHeavy => 300,
  ReportType.fallenTree => 300,
  ReportType.construction => 180,
  ReportType.trafficModerate => 120,
  ReportType.breakdown => 120,
  ReportType.checkpoint => 90,
  ReportType.hazard => 60,
  ReportType.roadDamage => 45,
  ReportType.trafficClear => 0,
};

/// An incident this close to the driver is level with them, not ahead.
///
/// Something you are already alongside cannot be avoided by rerouting, and
/// counting it would penalise every possible route by the same amount —
/// which tells the driver nothing and makes "ahead" a lie.
const double kAlreadyPassedMeters = 80;

/// Reports that lie on [route].
///
/// When [from] is given, only what is still **ahead** of that position
/// counts. Without it, an accident at the driver's own location lands on
/// every alternative equally, so no route can ever look better than
/// another and the avoidance is inert.
List<RoadReport> incidentsOn(
  NavRoute route,
  Iterable<RoadReport> reports, {
  required DateTime now,
  double thresholdMeters = kIncidentOnRouteMeters,
  LatLng? from,
}) {
  if (route.points.length < 2) return const [];

  // Distance still to run from the driver. An incident is ahead when less
  // of the route remains after it than after the driver.
  final driverRemaining = from == null ? null : remainingMeters(route, from);

  return [
    // statusAt(now), not status: the latter reads the wall clock, which
    // would judge a report against a different instant from the liveness
    // check beside it.
    for (final r in reports)
      if (r.isLive(now) && r.statusAt(now).isTrusted)
        if ((nearestOnWay(route.points, r.location)?.distanceMeters ??
                double.infinity) <=
            thresholdMeters)
          if (driverRemaining == null ||
              driverRemaining - remainingMeters(route, r.location) >
                  kAlreadyPassedMeters)
            r,
  ];
}

/// Applies the congestion model to a route.
RouteScore scoreRoute(
  NavRoute route,
  Iterable<RoadReport> reports, {
  required DateTime now,
  LatLng? from,
}) {
  final on = incidentsOn(route, reports, now: now, from: from);
  var penalty = 0.0;
  for (final r in on) {
    // When the router already measured the traffic, adding this app's guess
    // at the same congestion on top would count it twice. Discrete
    // incidents still count — a router knows the road is slow, but not that
    // there is an accident on it.
    if (route.isTrafficAware && r.type.category == ReportCategory.traffic) {
      continue;
    }
    // A corroborated report is trusted more, up to double weight — but a
    // lone report still counts for something.
    final confidence = (1 + r.confirmations.clamp(0, 4) * 0.25).clamp(1.0, 2.0);
    penalty += incidentDelaySeconds(r.type) * confidence;
  }
  return RouteScore(
    route: route,
    incidentsOnRoute: on,
    penaltySeconds: penalty,
  );
}

/// Picks the route to drive.
///
/// Blocked routes lose to any usable route regardless of time. Otherwise the
/// lowest adjusted time wins, which is what makes this "fastest given what
/// we know" rather than "shortest".
RouteScore? chooseBest(List<RouteScore> candidates) {
  if (candidates.isEmpty) return null;
  final usable = candidates.where((c) => !c.isBlocked).toList();
  final pool = usable.isEmpty ? candidates : usable;
  return pool.reduce((a, b) => a.adjustedSeconds <= b.adjustedSeconds ? a : b);
}

/// Why a reroute happened, so the driver is told something specific rather
/// than just seeing the line jump.
enum RerouteReason {
  none,
  roadBlocked,
  fasterRoute,
  offRoute;

  String get message => switch (this) {
    RerouteReason.none => '',
    RerouteReason.roadBlocked => 'Route updated — road reported closed ahead',
    RerouteReason.fasterRoute => 'Route updated — avoiding reported delays',
    RerouteReason.offRoute => 'New route found',
  };
}

/// A reroute must save at least this much to be worth it.
///
/// Both thresholds must be met. Without them the route would twitch every
/// time a report aged or a GPS fix wobbled, which is worse than a slightly
/// suboptimal route.
const Duration kMinRerouteSaving = Duration(minutes: 2);
const double kMinRerouteFraction = 0.15;

/// How far off the line counts as having left the route.
///
/// Generous, because urban GPS drifts and a tricycle may legitimately pull
/// to the side of the road.
const double kOffRouteMeters = 60;

/// Consecutive off-route fixes required before recalculating, so one bad
/// GPS reading does not trigger a reroute.
const int kOffRouteFixes = 3;

/// Whether [current] should be replaced by [candidate].
///
/// [driverPickedRoute] means the driver deliberately chose this route over
/// the recommendation. Their choice is then respected: the system will not
/// quietly put them back on the faster one, because a driver who picked the
/// longer way usually knows something the app does not. Safety still
/// overrides — a closure ahead, or leaving the route entirely, reroutes
/// regardless.
RerouteReason rerouteDecision({
  required RouteScore current,
  required RouteScore candidate,
  bool driverIsOffRoute = false,
  bool driverPickedRoute = false,
}) {
  if (driverIsOffRoute) return RerouteReason.offRoute;

  // A closure ahead justifies a change even if the detour is slower.
  if (current.isBlocked && !candidate.isBlocked) {
    return RerouteReason.roadBlocked;
  }
  if (candidate.isBlocked) return RerouteReason.none;

  if (driverPickedRoute) return RerouteReason.none;

  final saving = current.adjustedSeconds - candidate.adjustedSeconds;
  if (saving < kMinRerouteSaving.inSeconds) return RerouteReason.none;
  if (current.adjustedSeconds <= 0) return RerouteReason.none;
  if (saving / current.adjustedSeconds < kMinRerouteFraction) {
    return RerouteReason.none;
  }
  return RerouteReason.fasterRoute;
}

/// How far the driver is from the route line, in metres.
///
/// Returns null when there is no usable route to measure against.
double? distanceFromRoute(NavRoute route, LatLng position) =>
    nearestOnWay(route.points, position)?.distanceMeters;

/// Tracks whether the driver has genuinely left the route.
///
/// Deliberately stateful and forgiving: a single stray fix does not count,
/// because recalculating on GPS noise is how navigation apps get annoying.
class OffRouteDetector {
  int _consecutive = 0;

  /// Feeds one position. Returns true when the driver should be considered
  /// off-route and the route recalculated.
  bool update(NavRoute route, LatLng position) {
    final offset = distanceFromRoute(route, position);
    if (offset == null) return false;
    if (offset <= kOffRouteMeters) {
      _consecutive = 0;
      return false;
    }
    _consecutive++;
    if (_consecutive >= kOffRouteFixes) {
      _consecutive = 0;
      return true;
    }
    return false;
  }

  void reset() => _consecutive = 0;
}

/// Remaining distance along [route] from the driver's current position.
///
/// Measured along the road rather than as the crow flies, so the number
/// shrinks the way the driver expects.
double remainingMeters(NavRoute route, LatLng position) {
  final hit = nearestOnWay(route.points, position);
  if (hit == null) return route.distanceMeters;
  const d = Distance();
  var total = d.as(LengthUnit.Meter, hit.point, route.points[hit.index + 1]);
  for (var i = hit.index + 1; i < route.points.length - 1; i++) {
    total += d.as(LengthUnit.Meter, route.points[i], route.points[i + 1]);
  }
  return total;
}

/// ETA for the remaining part of the route, keeping the route's own average
/// speed so a congestion penalty carries through proportionally.
Duration remainingDuration(RouteScore score, LatLng position) {
  final route = score.route;
  if (route.distanceMeters <= 0) return Duration.zero;
  final fraction = (remainingMeters(route, position) / route.distanceMeters)
      .clamp(0.0, 1.0);
  return Duration(seconds: (score.adjustedSeconds * fraction).round());
}

/// Arrival clock time.
DateTime arrivalTime(Duration remaining, {DateTime? from}) =>
    (from ?? DateTime.now()).add(remaining);

/// "4 min", "1 hr 10 min" — the form a driver reads at a glance.
String formatEta(Duration d) {
  final minutes = math.max(1, (d.inSeconds / 60).round());
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours hr' : '$hours hr $rest min';
}

/// "450 m", "2.4 km".
String formatDistance(double meters) => meters < 1000
    ? '${meters.round()} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';

/// Close enough to the destination to tell the driver they have arrived.
///
/// This only drives the UI prompt. The trip state still changes only when
/// the driver confirms.
const double kArrivalMeters = 50;

bool hasArrived(LatLng position, LatLng target) =>
    const Distance().as(LengthUnit.Meter, position, target) <= kArrivalMeters;
