/// Keeps the driver's navigation and the passenger's view of it in step.
///
/// Everything lives on the one `bookings/{id}` document that already carries
/// the trip and payment state, so there is no second location store and no
/// separate passenger record. The driver writes; both apps read the same
/// fields through their existing snapshot listeners, which is what makes the
/// passenger's ETA update without a refresh.
///
/// This service never changes `tripStatus`. Navigation observes the trip
/// state machine and reacts to it; only [TripService] moves it. Arriving at
/// a destination raises a prompt, and the driver's confirmation is what
/// advances the trip.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/navigation_state.dart';
import '../models/road_report.dart';
import '../models/trip_state.dart';
import 'navigation_router.dart';
import 'report_service.dart';
import 'traffic_incident_service.dart';

/// The navigation fields as they appear on the booking document.
class TripNavigation {
  final List<LatLng> routePoints;
  final double? etaSeconds;
  final double? remainingMeters;
  final LatLng? driverLocation;
  final DateTime? driverLocationAt;
  final String? rerouteMessage;
  final NavigationPhase phase;

  const TripNavigation({
    this.routePoints = const [],
    this.etaSeconds,
    this.remainingMeters,
    this.driverLocation,
    this.driverLocationAt,
    this.rerouteMessage,
    this.phase = NavigationPhase.idle,
  });

  bool get hasRoute => routePoints.length >= 2;

  Duration? get eta =>
      etaSeconds == null ? null : Duration(seconds: etaSeconds!.round());

  /// A location older than this is stale enough that showing it as "live"
  /// would mislead the passenger.
  static const Duration staleAfter = Duration(seconds: 45);

  bool isStale(DateTime now) {
    final at = driverLocationAt;
    if (at == null) return true;
    return now.difference(at) > staleAfter;
  }

  static double? _toDouble(dynamic v) => v is num ? v.toDouble() : null;

  factory TripNavigation.fromMap(
    Map<String, dynamic> data, {
    DateTime? Function(dynamic)? toDate,
  }) {
    final raw = data['routePoints'] as List? ?? const [];
    final points = <LatLng>[];
    for (final p in raw) {
      if (p is! Map) continue;
      final lat = _toDouble(p['lat']);
      final lng = _toDouble(p['lng']);
      if (lat != null && lng != null) points.add(LatLng(lat, lng));
    }

    final dLat = _toDouble(data['driverLatitude']);
    final dLng = _toDouble(data['driverLongitude']);

    return TripNavigation(
      routePoints: points,
      etaSeconds: _toDouble(data['etaSeconds']),
      remainingMeters: _toDouble(data['remainingMeters']),
      driverLocation: (dLat != null && dLng != null)
          ? LatLng(dLat, dLng)
          : null,
      driverLocationAt: toDate?.call(data['driverLocationAt']),
      rerouteMessage: data['rerouteMessage'] as String?,
      phase:
          NavigationPhase.values.firstWhere(
            (p) => p.name == data['navigationPhase'],
            orElse: () => NavigationPhase.idle,
          ),
    );
  }
}

class NavigationService {
  NavigationService._();
  static final NavigationService instance = NavigationService._();

  final _firestore = FirebaseFirestore.instance;

  /// Routes are recalculated no more often than this while simply driving
  /// along. Deviation and new incidents bypass it.
  static const Duration _minRecalcInterval = Duration(seconds: 45);

  /// Location writes are throttled so a 1-second GPS stream does not become
  /// a 1-second Firestore write bill.
  static const Duration _minLocationWrite = Duration(seconds: 4);

  final _offRoute = OffRouteDetector();
  DateTime? _lastRecalc;
  DateTime? _lastLocationWrite;
  RouteScore? _current;
  RouteChoices? _choices;
  bool _driverPicked = false;

  /// The route currently being driven, if any.
  RouteScore? get currentRoute => _current;

  /// What the driver may choose between for this leg.
  RouteChoices? get choices => _choices;

  /// Whether the driver overrode the recommendation.
  bool get driverPickedRoute => _driverPicked;

  DocumentReference<Map<String, dynamic>> _ref(String bookingId) =>
      _firestore.collection('bookings').doc(bookingId);

  /// Live navigation for one trip. Both roles read this.
  Stream<TripNavigation> watch(String bookingId) =>
      _ref(bookingId).snapshots().map(
        (snap) => TripNavigation.fromMap(
          snap.data() ?? const {},
          toDate: (v) => v is Timestamp ? v.toDate() : null,
        ),
      );

  /// Clears the per-trip state. Call when a trip ends or the driver signs
  /// out, so a stale route cannot leak into the next trip.
  void reset() {
    _offRoute.reset();
    _lastRecalc = null;
    _lastLocationWrite = null;
    _current = null;
    _choices = null;
    // A choice belongs to the leg it was made on; the destination leg starts
    // from the recommendation again.
    _driverPicked = false;
  }

  /// Where the driver is heading for the given trip state, or null when
  /// there is nothing to navigate to.
  static LatLng? targetFor(TripState trip, Map<String, dynamic> booking) {
    double? d(String key) => (booking[key] as num?)?.toDouble();
    return switch (NavigationPhase.forTrip(trip.trip)) {
      NavigationPhase.toPickup =>
        (d('pickupLatitude') != null && d('pickupLongitude') != null)
            ? LatLng(d('pickupLatitude')!, d('pickupLongitude')!)
            : null,
      NavigationPhase.toDestination =>
        (d('destinationLatitude') != null && d('destinationLongitude') != null)
            ? LatLng(d('destinationLatitude')!, d('destinationLongitude')!)
            : null,
      NavigationPhase.atPickup || NavigationPhase.idle => null,
    };
  }

  /// Pushes the driver's position to the shared record.
  ///
  /// Throttled, and deliberately separate from routing so the passenger's
  /// dot keeps moving even when a recalculation is in flight.
  Future<void> publishLocation({
    required String bookingId,
    required LatLng position,
    required NavigationPhase phase,
  }) async {
    final now = DateTime.now();
    final last = _lastLocationWrite;
    if (last != null && now.difference(last) < _minLocationWrite) return;
    _lastLocationWrite = now;

    try {
      await _ref(bookingId).update({
        'driverLatitude': position.latitude,
        'driverLongitude': position.longitude,
        'driverLocationAt': FieldValue.serverTimestamp(),
        'navigationPhase': phase.name,
      });
    } catch (e) {
      // A dropped location write is not worth interrupting the driver over;
      // the next fix carries the same information.
      debugPrint('Could not publish driver location: $e');
    }
  }

  /// Establishes the route for a leg, replacing whatever was being driven.
  Future<RouteScore?> startLeg({
    required String bookingId,
    required LatLng from,
    required LatLng to,
  }) async {
    _offRoute.reset();
    final now = DateTime.now();
    final conditions = await _conditionsNear(from);
    final scored = await _scoredCandidates(from, to, conditions, now);
    if (scored.isEmpty) return null;

    final choices = buildChoices(scored);
    if (choices == null) return null;

    _choices = choices;
    _driverPicked = false;
    _current = choices.recommended;
    _lastRecalc = now;
    await _publishRoute(bookingId, choices.recommended, from, message: null);
    return choices.recommended;
  }

  /// Switches to a route the driver picked over the recommendation.
  ///
  /// Sets [driverPickedRoute], which stops the next tick quietly putting
  /// them back on the faster one. A closure ahead or leaving the route still
  /// reroutes — the override is about preference, not safety.
  Future<void> useRoute({
    required String bookingId,
    required RouteScore route,
    required LatLng from,
  }) async {
    _current = route;
    _driverPicked = true;
    _offRoute.reset();
    _lastRecalc = DateTime.now();
    await _publishRoute(bookingId, route, from, message: null);
  }

  /// One navigation tick: the driver has moved, so update the shared record
  /// and decide whether the route still makes sense.
  ///
  /// Returns the reason a reroute happened, so the UI can say why. Returns
  /// [RerouteReason.none] when the route was left alone.
  Future<RerouteReason> onDriverMoved({
    required String bookingId,
    required LatLng position,
    required LatLng target,
    required NavigationPhase phase,
  }) async {
    await publishLocation(
      bookingId: bookingId,
      position: position,
      phase: phase,
    );

    final current = _current;
    if (current == null) {
      await startLeg(bookingId: bookingId, from: position, to: target);
      return RerouteReason.none;
    }

    // Keep the passenger's ETA moving even when nothing is recalculated.
    await _publishProgress(bookingId, current, position);

    final wentOffRoute = _offRoute.update(current.route, position);
    final now = DateTime.now();
    final due =
        _lastRecalc == null ||
        now.difference(_lastRecalc!) >= _minRecalcInterval;

    // Leaving the route recalculates immediately; otherwise this is a
    // periodic check, so a reroute is never triggered by GPS jitter alone.
    if (!wentOffRoute && !due) return RerouteReason.none;
    _lastRecalc = now;

    final conditions = await _conditionsNear(position);
    // Re-score what is being driven against the conditions reported since it
    // was chosen — this is how a new incident reaches an in-progress trip.
    final rescoredCurrent = conditions.score(
      current.route,
      now: now,
      from: position,
    );

    final scored = await _scoredCandidates(
      position,
      target,
      conditions,
      now,
      // What is ahead on the road actually being driven, not only on the
      // fresh routes — that is the incident the driver is heading into.
      alsoAvoid: rescoredCurrent.incidentsOnRoute,
    );
    if (scored.isEmpty) return RerouteReason.none;

    final choices = buildChoices(scored);
    if (choices == null) return RerouteReason.none;
    // Refresh what the driver can switch to, so the options panel reflects
    // conditions now rather than when the leg started.
    _choices = choices;
    final best = choices.recommended;

    final decision = rerouteDecision(
      current: rescoredCurrent,
      candidate: best,
      driverIsOffRoute: wentOffRoute,
      driverPickedRoute: _driverPicked,
    );

    if (decision == RerouteReason.none) {
      // Not worth switching, but the delay estimate may still have changed.
      _current = rescoredCurrent;
      await _publishProgress(bookingId, rescoredCurrent, position);
      return RerouteReason.none;
    }

    // A forced reroute overrides the driver's earlier pick, and the new
    // route becomes the recommendation rather than a lingering override.
    _driverPicked = false;

    _current = best;
    await _publishRoute(bookingId, best, position, message: decision.message);
    return decision;
  }

  /// Every route worth considering from [from] to [to], scored.
  ///
  /// This is what turns other drivers' reports into routing. TomTom's own
  /// alternatives are fetched and scored first; if the best of them — or the
  /// route being driven, via [alsoAvoid] — runs into something reported,
  /// TomTom is asked again with those places marked as areas to avoid. Both
  /// sets are then scored together, so the detour is taken only when it
  /// beats the delay the incident is expected to cause. Otherwise the driver
  /// keeps the road and the ETA carries that delay.
  Future<List<RouteScore>> _scoredCandidates(
    LatLng from,
    LatLng to,
    _Conditions conditions,
    DateTime now, {
    List<RoadReport> alsoAvoid = const [],
  }) async {
    final routes = await NavigationRouter.instance.routeWithAlternatives(
      from,
      to,
    );
    final scored = [
      for (final r in routes) conditions.score(r, now: now, from: from),
    ];
    if (scored.isEmpty) return scored;

    final best = chooseBest(scored)!;
    final trouble = <RoadReport>[
      for (final r in [...best.incidentsOnRoute, ...alsoAvoid])
        if (conditions.costsTime(r)) r,
    ]..sort((a, b) => b.type.severity.compareTo(a.type.severity));
    if (trouble.isEmpty) return scored;

    // One spot per place: two drivers reporting the same accident is one
    // area to avoid, not two overlapping ones eating the request's limit.
    final spots = <LatLng>[];
    for (final r in trouble) {
      if (spots.every((s) => distanceKm(s, r.location) > 0.1)) {
        spots.add(r.location);
      }
    }

    final detours = await NavigationRouter.instance.routeWithAlternatives(
      from,
      to,
      maxAlternatives: 1,
      avoid: spots,
    );
    for (final d in detours) {
      if (!d.isRealRoute) continue;
      // TomTom's times include measured traffic and OSRM's are free-flow.
      // Should the avoiding request fall back to OSRM, its optimistic time
      // would beat a TomTom route unfairly, so only like is compared with
      // like.
      if (d.isTrafficAware != best.route.isTrafficAware) continue;
      if (scored.any((s) => s.route.sameRouteAs(d))) continue;
      scored.add(conditions.score(d, now: now, from: from));
    }
    return scored;
  }

  /// What is known about the roads near [origin]: what drivers reported, and
  /// what the live traffic feed measured.
  Future<_Conditions> _conditionsNear(LatLng origin) async {
    final reports = await _nearbyReports(origin);
    var measured = const <TrafficIncident>[];
    try {
      measured = await TrafficIncidentService.instance.near(origin);
    } catch (e) {
      // With no measured data every report counts in full, which errs
      // towards believing drivers — the safer direction.
      debugPrint('Could not read measured traffic for routing: $e');
    }
    return _Conditions(reports, measured);
  }

  /// Reports near enough to matter for routing.
  Future<List<RoadReport>> _nearbyReports(LatLng origin) async {
    try {
      return await ReportService.instance
          .watchNearby(origin, radiusKm: 8)
          .first
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      // Routing without incident data is worse than routing with it, but far
      // better than not routing at all.
      debugPrint('Could not read reports for routing: $e');
      return const [];
    }
  }

  Future<void> _publishRoute(
    String bookingId,
    RouteScore score,
    LatLng from, {
    required String? message,
  }) async {
    final remaining = remainingMeters(score.route, from);
    try {
      await _ref(bookingId).update({
        'routePoints': [
          for (final p in score.route.points)
            {'lat': p.latitude, 'lng': p.longitude},
        ],
        'routeDistanceMeters': score.route.distanceMeters,
        'remainingMeters': remaining,
        'etaSeconds': remainingDuration(score, from).inSeconds,
        'etaIsEstimate': score.isEstimate,
        'routeUpdatedAt': FieldValue.serverTimestamp(),
        // Cleared by the driver UI once shown, so it is not replayed.
        'rerouteMessage': message,
      });
    } catch (e) {
      debugPrint('Could not publish route: $e');
    }
  }

  Future<void> _publishProgress(
    String bookingId,
    RouteScore score,
    LatLng position,
  ) async {
    try {
      await _ref(bookingId).update({
        'remainingMeters': remainingMeters(score.route, position),
        'etaSeconds': remainingDuration(score, position).inSeconds,
        'etaIsEstimate': score.isEstimate,
      });
    } catch (e) {
      debugPrint('Could not publish progress: $e');
    }
  }

  /// Acknowledges a reroute banner so it is shown once, not on every rebuild.
  Future<void> clearRerouteMessage(String bookingId) async {
    try {
      await _ref(bookingId).update({'rerouteMessage': null});
    } catch (_) {
      // Cosmetic only.
    }
  }
}

/// Reported and measured conditions, gathered once per recalculation so
/// every candidate route is judged against the same picture.
class _Conditions {
  _Conditions(this.reports, this.measured);

  final List<RoadReport> reports;
  final List<TrafficIncident> measured;

  /// Whether the live feed already shows this report's congestion, in which
  /// case TomTom's travel time includes it.
  bool alreadyMeasured(RoadReport r) =>
      liveTrafficAgreesWith(r.type, r.location, measured);

  /// Whether a report on the route is expected to cost the driver time that
  /// the router does not already know about — and so is worth routing
  /// around.
  bool costsTime(RoadReport r) =>
      incidentDelaySeconds(r.type) > 0 &&
      !(r.type.category == ReportCategory.traffic && alreadyMeasured(r));

  RouteScore score(NavRoute route, {required DateTime now, LatLng? from}) =>
      scoreRoute(
        route,
        reports,
        now: now,
        from: from,
        alreadyMeasured: alreadyMeasured,
      );
}
