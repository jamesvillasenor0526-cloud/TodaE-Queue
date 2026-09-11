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
      'new name' ||
      'continue' => road.isEmpty ? 'Continue straight' : 'Continue on $road',
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

  /// Source of a route found on OpenStreetMap's road network, with its
  /// traffic-free time scaled to the traffic TomTom measured nearby.
  static const String osmEstimateSource = 'osm-estimate';

  /// Whether [durationSeconds] is this app's estimate rather than a router's
  /// answer. Such a route is labelled "estimated", and every report on it
  /// counts in full, since no measured traffic stands behind its time.
  bool get hasEstimatedTime => source == osmEstimateSource;

  /// This route with its traffic-free time scaled by [trafficFactor].
  ///
  /// For a way round that TomTom's map does not have. OSRM knows the road
  /// but not the traffic on it; TomTom knows the traffic but not the road.
  /// Scaling by how much slower TomTom found the direct road than OSRM did
  /// is a model, and the result is labelled as one — but it makes the two
  /// comparable, where an unscaled free-flow time would beat every
  /// measured route and send drivers the long way for nothing.
  NavRoute withTrafficEstimate(double trafficFactor) => NavRoute(
    points: points,
    distanceMeters: distanceMeters,
    durationSeconds: durationSeconds * trafficFactor,
    steps: steps,
    source: osmEstimateSource,
  );

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

  /// Reports on this route that make it impassable, judged when it was
  /// scored — see [blocksRoad]. Stored rather than derived, because whether
  /// an accident blocks depends on its status at a given instant and this
  /// class deliberately never reads the clock.
  final List<RoadReport> blockers;

  const RouteScore({
    required this.route,
    required this.incidentsOnRoute,
    required this.penaltySeconds,
    this.blockers = const [],
  });

  /// Free-flow duration plus the modelled delay.
  double get adjustedSeconds => route.durationSeconds + penaltySeconds;

  /// True when the number is partly this app's model rather than purely a
  /// router's: reports moved it, or the route's own time was estimated from
  /// traffic-free data. The UI says "estimated" rather than implying a
  /// measurement.
  bool get isEstimate => penaltySeconds > 0 || route.hasEstimatedTime;

  /// A route the driver should not be sent down at all.
  bool get isBlocked => blockers.isNotEmpty;

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
    if (isBlocked) {
      // Name what is in the way. "Road reported closed" for a crash told the
      // driver something that was not true.
      return switch (blockers.first.type) {
        ReportType.roadClosure => 'Road reported closed',
        final other => '${other.label} blocking the road',
      };
    }
    final worst = worstIncident;
    if (worst == null) return 'Nothing reported';
    final count = incidentsOnRoute.length;
    return count == 1
        ? '${worst.label} reported'
        : '${worst.label} + ${count - 1} more reported';
  }
}

/// The routes offered to the driver, best first.
///
/// Capped at [kMaxAlternatives]: the live-navigation spec asks for the
/// fastest route plus slower complete alternatives ("2 min slower", "5 min
/// slower"), the way Apple and Google Maps show them. More than that is a
/// driver choosing between five lines on a phone, which is worse than being
/// given a good answer.
class RouteChoices {
  final RouteScore recommended;

  /// Slower complete routes, quickest first.
  final List<RouteScore> alternatives;

  /// The quickest way that is blocked, when the recommendation is not it.
  ///
  /// Never offered — it cannot be driven — but shown, because otherwise the
  /// driver looks at a longer route, sees the obvious road beside it, and
  /// concludes the app is wrong. "Accident blocking the road" on that road
  /// answers the question before it is asked.
  final RouteScore? blocked;

  const RouteChoices({
    required this.recommended,
    this.alternatives = const [],
    this.blocked,
  });

  /// The best of the alternatives, for places that show only one.
  RouteScore? get alternative =>
      alternatives.isEmpty ? null : alternatives.first;

  /// Every route on offer, recommended first.
  List<RouteScore> get all => [recommended, ...alternatives];

  bool get hasAlternative => alternatives.isNotEmpty;

  /// How much longer the alternative takes. Negative would mean it is
  /// quicker, which cannot happen since the quicker one is recommended.
  Duration? get alternativeCost => alternative == null
      ? null
      : Duration(
          seconds: (alternative!.adjustedSeconds - recommended.adjustedSeconds)
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
  int maxAlternatives = kMaxAlternatives,
  // 1.0 turns the check off, which keeps the geometry-free tests meaningful;
  // navigation passes [kMaxSharedWithRecommended].
  double maxShared = 1.0,
}) {
  final best = chooseBest(candidates);
  if (best == null) return null;

  // Something reported on the recommended route makes any usable detour
  // worth showing.
  final recommendedHasTrouble =
      best.isBlocked || best.incidentsOnRoute.isNotEmpty;
  final ceiling = best.adjustedSeconds * (1 + maxDetourFraction);

  final eligible = <RouteScore>[];
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
    // The same road fetched twice is already dropped where candidates are
    // gathered (NavigationService._scoredCandidates), so it is not re-checked
    // here by geometry.
    eligible.add(c);
  }
  eligible.sort((a, b) => a.adjustedSeconds.compareTo(b.adjustedSeconds));

  // The quickest blocked way, to explain why the recommendation is not it.
  final blockedWays = [
    for (final c in candidates)
      if (c.isBlocked && !best.isBlocked) c,
  ]..sort((a, b) => a.route.durationSeconds.compareTo(b.route.durationSeconds));
  final blocked = blockedWays.firstOrNull;

  if (maxShared >= 1.0) {
    return RouteChoices(
      recommended: best,
      alternatives: eligible.take(maxAlternatives).toList(),
      blocked: blocked,
    );
  }

  // Quickest first, keeping only ways that are genuinely different from the
  // recommendation, and from each other.
  final picked = <RouteScore>[];
  for (final c in eligible) {
    if (picked.length >= maxAlternatives) break;
    if (sharedFraction(c.route.points, best.route.points) > maxShared) continue;
    if (picked.any(
      (p) =>
          sharedFraction(c.route.points, p.route.points) >
          kMaxSharedBetweenAlternatives,
    )) {
      continue;
    }
    picked.add(c);
  }
  return RouteChoices(
    recommended: best,
    alternatives: picked,
    blocked: blocked,
  );
}

/// How many slower routes are offered beside the fastest.
const int kMaxAlternatives = 2;

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

/// How much slower, per kilometre, TomTom finds travel here than OSRM's
/// traffic-free estimate — the ratio used to put an OpenStreetMap route's
/// time on the same footing as TomTom's.
///
/// Compared per kilometre, not trip against trip. The two routers' routes
/// are usually different roads: dividing TomTom's 5.8 km south route by
/// OSRM's 6.6 km east one made OSRM's route come out, by construction,
/// exactly as fast as TomTom's — so a route 13% longer tied with it. Pace
/// against pace keeps the longer road longer.
///
/// Bounded, because a mismatched pair can still produce nonsense: 10 would
/// make a way round look like an hour, 0.1 would make it look free.
double trafficFactor({
  required double measuredSeconds,
  required double measuredMeters,
  required double freeFlowSeconds,
  required double freeFlowMeters,
}) {
  if (measuredSeconds <= 0 ||
      measuredMeters <= 0 ||
      freeFlowSeconds <= 0 ||
      freeFlowMeters <= 0) {
    return 1;
  }
  final measuredPace = measuredSeconds / measuredMeters;
  final freeFlowPace = freeFlowSeconds / freeFlowMeters;
  return (measuredPace / freeFlowPace).clamp(0.5, 4.0);
}

/// Share of [a]'s length that runs within [within] metres of [b].
///
/// What tells a genuinely different way from the main road with a variation
/// on it. TomTom's alternatives from the Calantipay trip all left on the
/// same southern road and split later; offered as "alternatives", they were
/// the main way again.
double sharedFraction(List<LatLng> a, List<LatLng> b, {double within = 25}) {
  if (a.length < 2 || b.length < 2) return 0;
  const d = Distance();
  var shared = 0.0, total = 0.0;
  for (var i = 1; i < a.length; i++) {
    final length = d.as(LengthUnit.Meter, a[i - 1], a[i]);
    total += length;
    // The midpoint of each piece, so a long straight segment is judged by
    // where it actually runs rather than only by its ends.
    final mid = LatLng(
      (a[i - 1].latitude + a[i].latitude) / 2,
      (a[i - 1].longitude + a[i].longitude) / 2,
    );
    final near = nearestOnWay(b, mid)?.distanceMeters ?? double.infinity;
    if (near <= within) shared += length;
  }
  return total <= 0 ? 0 : shared / total;
}

/// An alternative that shares more than this with the recommended route is
/// the same way again, not another one.
const double kMaxSharedWithRecommended = 0.7;

/// Two alternatives that share more than this with each other are one.
const double kMaxSharedBetweenAlternatives = 0.9;

/// A route that runs this much on another is the same road, fetched again.
const double kSameRoadFraction = 0.9;

/// Whether [r] makes the road impassable at [now], rather than just slow.
///
/// A blocked route loses to any usable one however long the way round, so
/// this is deliberately narrow:
///
///   * A reported closure always blocks — that is what it says.
///   * An accident or a fallen tree blocks once **confirmed** — by an admin,
///     or by enough drivers agreeing. The report sheet describes both as
///     "blocking the road", and a confirmed accident was being modelled as
///     an 8-minute delay to drive through: the route went straight through
///     one because the only way round was slower. A road you cannot pass is
///     not made passable by the detour being long.
///
/// A single unverified accident still only costs time, so one mistaken or
/// malicious report cannot send every driver in town the long way round.
bool blocksRoad(RoadReport r, DateTime now) => switch (r.type) {
  ReportType.roadClosure => true,
  ReportType.accident ||
  ReportType.fallenTree => r.statusAt(now) == IncidentStatus.confirmed,
  _ => false,
};

/// The delay one report adds to a route it sits on.
///
/// A corroborated report is trusted more, up to double weight — but a lone
/// report still counts for something. Shared by [scoreRoute] and
/// [worthLookingForDetour] so the two can never disagree about what a
/// report costs.
double reportDelaySeconds(RoadReport r) {
  final confidence = (1 + r.confirmations.clamp(0, 4) * 0.25).clamp(1.0, 2.0);
  return incidentDelaySeconds(r.type) * confidence;
}

/// Whether the reports ahead are worth asking the router to go around.
///
/// Every detour lookup is a request against a 2,500-a-day quota, and for a
/// minor report the answer is already known: a mid-trip reroute has to save
/// [kMinRerouteSaving], so a detour around that much delay or less can never
/// be taken unless going round costs nothing at all. A lone road hazard is
/// modelled at 60 s; asking TomTom about it spent a request to learn that
/// the 63 s way round the rotonda was not worth it.
///
/// Delays are summed, not judged one by one: three hazards on the same road
/// cost three minutes, and that is worth looking at.
bool worthLookingForDetour(Iterable<RoadReport> avoidable) {
  final total = avoidable.fold(0.0, (sum, r) => sum + reportDelaySeconds(r));
  return total > kMinRerouteSaving.inSeconds;
}

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
///
/// [alreadyMeasured] says whether the router's own traffic data already
/// shows a report's congestion at that spot. Only then is the report's
/// delay left out, because the router's travel time includes it and adding
/// it again would count the same jam twice. Without it every report counts.
RouteScore scoreRoute(
  NavRoute route,
  Iterable<RoadReport> reports, {
  required DateTime now,
  LatLng? from,
  bool Function(RoadReport report)? alreadyMeasured,
}) {
  final on = incidentsOn(route, reports, now: now, from: from);
  var penalty = 0.0;
  for (final r in on) {
    // This used to skip every traffic report on a traffic-aware route, on
    // the assumption the router had measured it. TomTom is now the router
    // on every trip, and it saw nothing at all at the Glorieta Rotonda when
    // a driver reported heavy traffic there — so the report added nothing,
    // the route never avoided it, and the ETA never moved. A jam is only
    // left out when the measured data demonstrably has it; the feed saying
    // nothing is not evidence the road is clear.
    if (route.isTrafficAware &&
        r.type.category == ReportCategory.traffic &&
        (alreadyMeasured?.call(r) ?? false)) {
      continue;
    }
    penalty += reportDelaySeconds(r);
  }
  return RouteScore(
    route: route,
    incidentsOnRoute: on,
    penaltySeconds: penalty,
    blockers: [
      for (final r in on)
        if (blocksRoad(r, now)) r,
    ],
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
    // Not "closed": this also fires for a confirmed accident or fallen tree.
    RerouteReason.roadBlocked => 'Route updated — road blocked ahead',
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

/// Moving at least this fast (m/s, about 11 km/h), the GPS course is the way
/// the driver is actually going. Slower, it wanders, and standing still it
/// says nothing at all.
const double kMovingSpeed = 3;

/// A course this far from the road's direction is travel against the route.
const double kWrongWayDegrees = 135;

/// How far along a route its starting direction is judged over.
const double kSetOffMeters = 40;

double _bearing(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180, lat2 = b.latitude * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dLng) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

double _angleBetween(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/// Whether a driver going [speed] m/s on course [heading] is travelling
/// against a road running [roadBearing]. False whenever the course cannot be
/// trusted — too slow, or no heading.
bool isAgainstRoute({
  required double? heading,
  required double speed,
  required double? roadBearing,
}) {
  if (heading == null || roadBearing == null || speed < kMovingSpeed) {
    return false;
  }
  return _angleBetween(heading, roadBearing) > kWrongWayDegrees;
}

/// The route's direction of travel at the point nearest [position].
double? routeDirectionNear(List<LatLng> points, LatLng position) {
  final hit = nearestOnWay(points, position);
  if (hit == null) return null;
  final i = hit.index.clamp(0, points.length - 2);
  if (points[i] == points[i + 1]) return null;
  return _bearing(points[i], points[i + 1]);
}

/// The way [route] sets off: the bearing over its first [kSetOffMeters].
double? setOffBearing(NavRoute route) {
  final pts = route.points;
  if (pts.length < 2) return null;
  const d = Distance();
  for (var i = 1; i < pts.length; i++) {
    if (d.as(LengthUnit.Meter, pts.first, pts[i]) >= kSetOffMeters) {
      return _bearing(pts.first, pts[i]);
    }
  }
  return pts.first == pts.last ? null : _bearing(pts.first, pts.last);
}

/// [candidates] without those that set off against the driver's course —
/// unless that is all of them, when nothing is dropped: a U-turn route
/// beats no route.
///
/// A route that starts by going back the way the driver came is drawn
/// behind the arrow, and the driver pulls further from it every second. On
/// a recorded drive north along B.S. Aquino Avenue with the destination
/// south, every route set off south, the line trailed behind the arrow, and
/// it caught up only when the next recalculation started a new one.
List<T> keepThoseAhead<T>(
  List<T> candidates,
  NavRoute Function(T) routeOf, {
  required double? heading,
  required double speed,
}) {
  if (heading == null || speed < kMovingSpeed) return candidates;
  final ahead = [
    for (final c in candidates)
      if (!isAgainstRoute(
        heading: heading,
        speed: speed,
        roadBearing: setOffBearing(routeOf(c)),
      ))
        c,
  ];
  return ahead.isEmpty ? candidates : ahead;
}

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
  ///
  /// Travelling against the route counts as leaving it, even on the line
  /// itself. A driver who has turned round — or never faced the route's way
  /// — is on its road but not following it, and waiting until they were
  /// 60 m clear took the recorded drive 25 s to recalculate.
  bool update(
    NavRoute route,
    LatLng position, {
    double? heading,
    double speed = 0,
  }) {
    final offset = distanceFromRoute(route, position);
    if (offset == null) return false;
    final against = isAgainstRoute(
      heading: heading,
      speed: speed,
      roadBearing: routeDirectionNear(route.points, position),
    );
    if (offset <= kOffRouteMeters && !against) {
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
