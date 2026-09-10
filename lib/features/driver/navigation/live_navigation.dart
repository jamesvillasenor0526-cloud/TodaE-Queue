/// The live navigation session: one GPS stream, one route, many views.
///
/// This used to live inside the navigation panel, which meant the only way to
/// navigate was a strip under a 200-pixel map, and a second screen showing
/// the route would have needed a second GPS loop fighting the first over the
/// same trip record. Now the panel and the full-screen navigation view both
/// read this, and nothing else talks to the GPS for navigation.
///
/// Two speeds, deliberately:
///
///   * **Every GPS reading** moves the driver along the route: progress, the
///     line ahead, the distance to the next turn, heading and ETA. This is
///     local arithmetic and costs nothing, so the start point moves with the
///     driver continuously.
///   * **Routing** — publishing to the trip record, re-checking reports,
///     rerouting — is throttled, because each call writes to Firestore and
///     may call TomTom. [NavigationService] decides when a full
///     recalculation is due; leaving the route triggers one straight away.
///
/// It never touches the trip state machine. Arriving is announced, not
/// acted on.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/models/live_route.dart';
import '../../../core/models/navigation_state.dart';
import '../../../core/models/road_report.dart';
import '../../../core/models/trip_state.dart';
import '../../../core/models/voice_guidance.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/services/voice_service.dart';

/// Routing is asked at most this often while simply driving along.
const Duration kRoutingInterval = Duration(seconds: 3);

/// …or sooner once the driver has covered this much ground.
const double kRoutingDistanceMeters = 30;

/// How long a reroute message stays up.
const Duration kBannerTime = Duration(seconds: 6);

class LiveNavigation extends ChangeNotifier {
  LiveNavigation._();
  static final LiveNavigation instance = LiveNavigation._();

  // ---- Session -----------------------------------------------------------

  String? _bookingId;
  TripState? _trip;
  Map<String, dynamic> _booking = const {};

  /// Views holding the session open. GPS runs while this is above zero.
  int _holders = 0;

  String? get bookingId => _bookingId;
  bool get isRunning => _holders > 0 && _bookingId != null;

  NavigationPhase get phase =>
      _trip == null ? NavigationPhase.idle : NavigationPhase.forTrip(_trip!.trip);

  LatLng? get target => _trip == null
      ? null
      : NavigationService.targetFor(_trip!, _booking);

  // ---- Position ----------------------------------------------------------

  LatLng? _position;
  double _heading = 0;
  double _speed = 0;
  double? _accuracy;

  /// Latest GPS reading, unsnapped.
  LatLng? get position => _position;

  /// Where to draw the driver: on the road when the reading is close to it.
  LatLng? get shownPosition {
    final p = _position;
    return p == null ? null : displayPosition(p, _progress);
  }

  /// Which way the driver is facing, compass degrees.
  double get heading => _heading;

  /// Metres per second, from the GPS.
  double get speed => _speed;

  /// Horizontal accuracy of the last reading, metres.
  double? get accuracy => _accuracy;

  // ---- Route -------------------------------------------------------------

  RouteScore? _route;
  RouteChoices? _choices;
  RouteProgress? _progress;
  List<double>? _cumulative;
  String? _cumulativeFor;
  String? _banner;
  bool _working = false;

  RouteScore? get route => _route;
  RouteChoices? get choices => _choices;
  RouteProgress? get progress => _progress;

  /// Running distances along [route], for views that re-project the driver
  /// between readings (while animating the arrow) without recomputing them.
  List<double>? get cumulative => _cumulative;
  String? get banner => _banner;
  bool get working => _working;

  /// The route line still ahead of the driver — what should be drawn.
  List<LatLng> get lineAhead {
    final r = _route, p = _progress;
    if (r == null) return const [];
    if (p == null) return r.route.points;
    return remainingLine(r.route.points, p);
  }

  /// The GPS reading is too far from the road to be on the route. The
  /// driver is shown "Proceed to the route"; [NavigationService] reroutes
  /// if it persists.
  bool get isOffRoute =>
      _progress != null && _progress!.offRouteMeters > kOffRouteMeters;

  bool get arrived {
    final p = _position, t = target;
    return p != null && t != null && hasArrived(p, t);
  }

  /// The next manoeuvre, with the distance to it measured from where the
  /// driver is now rather than from where the route was fetched.
  UpcomingTurn? get upcoming {
    final r = _route;
    if (r == null) return null;
    final p = _progress, cum = _cumulative;
    if (p == null || cum == null) return r.route.upcoming;
    return upcomingAt(r.route, p.travelledMeters, geometryMeters: cum.last);
  }

  /// Time still to drive, including reported delays still ahead.
  Duration? get remaining {
    final r = _route, p = _progress;
    if (r == null) return null;
    final fraction = p?.remainingFraction ?? 1;
    return Duration(seconds: (r.adjustedSeconds * fraction).round());
  }

  double? get remainingMeters =>
      _progress?.remainingMeters ?? _route?.route.distanceMeters;

  // ---- Lifecycle -----------------------------------------------------------

  StreamSubscription<Position>? _positions;
  final VoiceGuide _guide = VoiceGuide();
  Timer? _bannerTimer;

  /// Opens (or joins) the session for a trip. Each view that holds the
  /// session calls [release] when it goes; GPS stops when none remain.
  void hold({
    required String bookingId,
    required TripState trip,
    required Map<String, dynamic> booking,
  }) {
    _holders++;
    _apply(bookingId, trip, booking);
    if (_positions == null) _startGps();
  }

  /// Joins the session without new trip details — for a view opened from
  /// one that already holds it.
  void holdExisting() {
    _holders++;
    if (_positions == null && _bookingId != null) _startGps();
  }

  /// Passes on a fresh booking snapshot. A change of leg — pickup to
  /// destination — starts the route again.
  void update(TripState trip, Map<String, dynamic> booking) {
    final id = _bookingId;
    if (id == null) return;
    _apply(id, trip, booking);
  }

  void release() {
    if (_holders > 0) _holders--;
    if (_holders == 0) {
      _positions?.cancel();
      _positions = null;
      VoiceService.instance.stop();
    }
  }

  void _apply(String bookingId, TripState trip, Map<String, dynamic> booking) {
    final previousPhase = phase;
    final newTrip = bookingId != _bookingId;
    _bookingId = bookingId;
    _trip = trip;
    _booking = booking;

    if (newTrip || phase != previousPhase) {
      NavigationService.instance.reset();
      _route = null;
      _choices = null;
      _progress = null;
      _cumulative = null;
      _cumulativeFor = null;
      // The run to the destination may repeat turns from the run to the
      // pickup, and they need saying again.
      _guide.reset();
      VoiceService.instance.stop();
      _lastRoutingAt = null;
      _lastRoutingPosition = null;
      notifyListeners();
      if (phase.isNavigating && _position != null) recalculate();
    }
  }

  // ---- GPS ---------------------------------------------------------------

  Future<void> _startGps() async {
    VoiceService.instance.load();
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }
    if (_holders == 0) return;

    // Every couple of metres, at least once a second: often enough that the
    // arrow moves smoothly and the line visibly shortens, which a 10 m
    // filter did not give. The routing throttle keeps Firestore writes to
    // one every few seconds regardless.
    final settings = defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
            intervalDuration: const Duration(seconds: 1),
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 2,
          );
    _positions = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onFix, onError: (Object e) {
          debugPrint('Navigation GPS error: $e');
        });

    // The stream only emits after movement, so a phone standing still
    // produces nothing — and a driver waiting at a terminal is exactly that.
    try {
      final cached = await Geolocator.getLastKnownPosition();
      if (cached != null && _position == null) _onFix(cached);
    } catch (_) {
      // Nothing cached yet; the live reading below covers it.
    }
    try {
      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 12));
      _onFix(fresh);
    } catch (_) {
      // Indoors or GPS off: the views keep saying they are waiting rather
      // than showing a route from nowhere.
    }
  }

  void _onFix(Position fix) {
    _position = LatLng(fix.latitude, fix.longitude);
    _speed = fix.speed.isFinite && fix.speed > 0 ? fix.speed : 0;
    _gpsHeading = fix.heading.isFinite ? fix.heading : null;
    _accuracy = fix.accuracy;
    _advance();
    _refreshHeading();

    notifyListeners();
    _speak(RerouteReason.none);
    _maybeRoute();
  }

  double? _gpsHeading;

  /// Re-derives the heading from the latest reading and the current route.
  ///
  /// Also run when the route changes, not only on a new reading: a phone
  /// standing still sends no readings, so a heading worked out before the
  /// route arrived — north, by default — stayed north while the route ran
  /// the other way, and the heading-up map showed the road going down the
  /// screen.
  void _refreshHeading() {
    final roadBearing = (_route != null && _progress != null)
        ? routeBearingAt(_route!.route.points, _progress!)
        : null;
    _heading = displayHeading(
      gpsHeading: _gpsHeading,
      speedMetersPerSecond: _speed,
      roadBearing: isOffRoute ? null : roadBearing,
      previous: _heading,
    );
  }

  /// Moves the driver along the current route. Cheap; runs on every reading.
  void _advance() {
    final r = _route, p = _position;
    if (r == null || p == null) {
      _progress = null;
      return;
    }
    final key = r.route.key;
    if (_cumulativeFor != key) {
      _cumulative = cumulativeMeters(r.route.points);
      _cumulativeFor = key;
      _progress = null; // a new route: do not carry the old segment hint
    }
    _progress = progressAlong(
      r.route.points,
      p,
      hint: _progress?.segment,
      cumulative: _cumulative,
    );
  }

  // ---- Routing -----------------------------------------------------------

  DateTime? _lastRoutingAt;
  LatLng? _lastRoutingPosition;
  bool _busy = false;

  void _maybeRoute() {
    final position = _position, t = target, id = _bookingId;
    if (position == null || t == null || id == null) return;
    if (!phase.isNavigating || _busy) return;

    final now = DateTime.now();
    final last = _lastRoutingAt;
    final moved = _lastRoutingPosition == null
        ? double.infinity
        : const Distance().as(LengthUnit.Meter, _lastRoutingPosition!, position);
    final due =
        last == null ||
        now.difference(last) >= kRoutingInterval ||
        moved >= kRoutingDistanceMeters ||
        isOffRoute;
    if (!due) return;

    _lastRoutingAt = now;
    _lastRoutingPosition = position;
    _routeFrom(id, position, t);
  }

  /// The one place the navigation service is driven from while moving.
  Future<void> _routeFrom(String id, LatLng position, LatLng target) async {
    _busy = true;
    try {
      final reason = await NavigationService.instance.onDriverMoved(
        bookingId: id,
        position: position,
        target: target,
        phase: phase,
      );
      _route = NavigationService.instance.currentRoute;
      _choices = NavigationService.instance.choices;
      _advance();
      _refreshHeading();
      if (reason != RerouteReason.none) _showBanner(reason.message);
      notifyListeners();
      _speak(reason);
    } finally {
      _busy = false;
    }
  }

  /// Fetches the leg afresh from where the driver is.
  Future<void> recalculate() async {
    final position = _position, t = target, id = _bookingId;
    if (position == null || t == null || id == null) return;
    _working = true;
    notifyListeners();
    try {
      _route = await NavigationService.instance.startLeg(
        bookingId: id,
        from: position,
        to: t,
      );
      _choices = NavigationService.instance.choices;
      _advance();
      _refreshHeading();
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  /// Switches to a route the driver picked, from the list or the map.
  Future<void> useRoute(RouteScore choice) async {
    final position = _position, id = _bookingId;
    if (position == null || id == null) return;
    if (_route != null && choice.route.sameRouteAs(_route!.route)) return;
    _working = true;
    notifyListeners();
    try {
      await NavigationService.instance.useRoute(
        bookingId: id,
        route: choice,
        from: position,
      );
      _route = choice;
      _advance();
      _refreshHeading();
      _guide.reset();
    } finally {
      _working = false;
      notifyListeners();
    }
  }

  void _showBanner(String text) {
    _banner = text;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(kBannerTime, () {
      _banner = null;
      notifyListeners();
    });
  }

  /// Speaks the next cue, if there is one and the driver wants it. Output
  /// only: nothing here can change the route, the trip or the payment.
  void _speak(RerouteReason reason) {
    final r = _route;
    if (r == null || !VoiceService.instance.enabled) return;
    final line = _guide.update(
      turn: upcoming,
      now: DateTime.now(),
      reroute: reason,
      ahead: groupIncidents(r.incidentsOnRoute, now: DateTime.now()),
    );
    if (line != null) VoiceService.instance.speak(line);
  }
}
