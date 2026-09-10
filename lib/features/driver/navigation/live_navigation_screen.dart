/// Full-screen turn-by-turn navigation.
///
/// A view of [LiveNavigation]: it draws what the session knows, as it
/// changes, and holds nothing of its own beyond the camera and the arrow's
/// animation. Everything on it is real — the position is the phone's GPS,
/// every line is a complete route geometry from the router, the times are
/// the router's (with reported delays added, and said so), and the "2 min
/// slower" labels are the difference between those times.
///
/// The start point moves. The line is drawn from where the driver is to the
/// destination and shortens as they go; alternatives are drawn from where
/// the driver meets them and disappear once they have been passed; every
/// few seconds the session re-routes from the new position, and leaving the
/// route recalculates at once.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../config/theme.dart';
import '../../../core/models/live_route.dart';
import '../../../core/models/navigation_state.dart';
import '../../../core/models/trip_state.dart';
import '../../../core/services/voice_service.dart';
import '../../../widgets/map_tiles.dart';
import '../../shared/reports/quick_report_sheet.dart';
import '../../shared/reports/report_map_layer.dart';
import 'live_navigation.dart';

/// Zoom while following the driver — close enough to read the junction ahead.
const double _followZoom = 17;

/// Where the driver sits on screen while following: below centre, so more of
/// the road ahead is visible than behind, as every navigation app does.
const double _driverScreenOffset = 0.22;

/// How long the arrow takes to glide to a new reading. About the GPS
/// interval, so it arrives as the next reading does rather than jumping.
const Duration _glide = Duration(milliseconds: 950);

const Color _routeBlue = Color(0xFF1A73E8);
const Color _altBlue = Color(0xFF8AB4F8);

class LiveNavigationScreen extends StatefulWidget {
  const LiveNavigationScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const LiveNavigationScreen(),
    ),
  );

  @override
  State<LiveNavigationScreen> createState() => _LiveNavigationScreenState();
}

enum _Camera { follow, overview, free }

class _LiveNavigationScreenState extends State<LiveNavigationScreen>
    with SingleTickerProviderStateMixin {
  final LiveNavigation _nav = LiveNavigation.instance;
  final MapController _map = MapController();
  late final AnimationController _anim;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _booking;

  bool _mapReady = false;
  _Camera _camera = _Camera.follow;
  bool _headingUp = true;

  // The arrow glides between readings rather than jumping.
  LatLng? _fromPos, _toPos, _shownPos;
  double _fromHeading = 0, _toHeading = 0, _shownHeading = 0;

  // Label positions, worked out once per set of routes.
  String? _anchorsFor;
  Map<String, LatLng?> _anchors = const {};

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: _glide)
      ..addListener(_onFrame);
    _nav.holdExisting();
    _nav.addListener(_onNav);
    _onNav();
    _watchTrip();
    // A navigation screen that sleeps after thirty seconds is not one.
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _booking?.cancel();
    _nav.removeListener(_onNav);
    _nav.release();
    _anim.dispose();
    super.dispose();
  }

  /// Follows the trip itself, so the leg switches from pickup to destination
  /// here too, and the screen closes when there is nothing to navigate.
  void _watchTrip() {
    final id = _nav.bookingId;
    if (id == null) return;
    _booking = FirebaseFirestore.instance
        .collection('bookings')
        .doc(id)
        .snapshots()
        .listen((snap) {
          final data = snap.data();
          if (data == null) return;
          _nav.update(TripState.fromMap(id, data), data);
          if (!_nav.phase.isNavigating && mounted) {
            Navigator.of(context).maybePop();
          }
        });
  }

  // ---- Motion ------------------------------------------------------------

  void _onNav() {
    // Drawn on the road when close to it, as every navigation app does.
    final p = _nav.shownPosition;
    if (p != null && p != _toPos) {
      _fromPos = _shownPos ?? p;
      _toPos = p;
      _fromHeading = _shownHeading;
      _toHeading = _nav.heading;
      _anim.forward(from: 0);
    } else if (_nav.heading != _toHeading) {
      _fromHeading = _shownHeading;
      _toHeading = _nav.heading;
      _anim.forward(from: 0);
    }
    if (mounted) setState(() {});
  }

  void _onFrame() {
    final from = _fromPos, to = _toPos;
    if (from == null || to == null) return;
    final t = Curves.easeOut.transform(_anim.value);
    _shownPos = LatLng(
      from.latitude + (to.latitude - from.latitude) * t,
      from.longitude + (to.longitude - from.longitude) * t,
    );
    _shownHeading =
        (_fromHeading + shortestTurn(_fromHeading, _toHeading) * t) % 360;
    _followCamera();
    if (mounted) setState(() {});
  }

  void _followCamera() {
    final at = _shownPos;
    if (!_mapReady || at == null || _camera != _Camera.follow) return;
    final size = MediaQuery.of(context).size;
    // Rotated first, then moved: the offset is applied in rotated screen
    // space, so the driver stays low on screen whichever way they face.
    _map.rotate(_headingUp ? -_shownHeading : 0);
    _map.move(
      at,
      _followZoom,
      offset: Offset(0, size.height * _driverScreenOffset),
    );
  }

  void _recenter() {
    setState(() => _camera = _Camera.follow);
    _followCamera();
  }

  void _showOverview() {
    final lines = [
      for (final s in _nav.choices?.all ?? [?_nav.route])
        ...s.route.points,
      // Including the blocked way, so the driver can see why it is not taken.
      ...?_nav.choices?.blocked?.route.points,
      ?_shownPos,
      ?_nav.target,
    ];
    if (lines.length < 2) return;
    setState(() => _camera = _Camera.overview);
    _map.rotate(0);
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: lines,
        padding: const EdgeInsets.fromLTRB(40, 200, 90, 220),
      ),
    );
  }

  // ---- Geometry for drawing ---------------------------------------------

  /// The route line from the arrow onwards — re-projected every frame so it
  /// starts exactly under the gliding arrow, not at the last raw reading.
  List<LatLng> _activeLine() {
    final r = _nav.route, at = _shownPos;
    if (r == null) return const [];
    if (at == null) return r.route.points;
    final p = progressAlong(
      r.route.points,
      at,
      hint: _nav.progress?.segment,
      cumulative: _nav.cumulative,
    );
    return p == null ? r.route.points : remainingLine(r.route.points, p);
  }

  /// Every other complete route, from where the driver meets it onwards.
  /// A route the driver has already turned away from is not drawn: it is no
  /// longer a choice, and the next re-route will offer fresh ones from here.
  List<({RouteScore score, List<LatLng> line})> _otherLines() {
    final active = _nav.route, choices = _nav.choices, at = _shownPos;
    if (active == null || choices == null) return const [];
    final out = <({RouteScore score, List<LatLng> line})>[];
    for (final s in choices.all) {
      if (s.route.sameRouteAs(active.route)) continue;
      if (s.isBlocked) continue;
      if (at == null) {
        out.add((score: s, line: s.route.points));
        continue;
      }
      final p = progressAlong(s.route.points, at);
      if (p == null || p.offRouteMeters > kOffRouteMeters) continue;
      out.add((score: s, line: remainingLine(s.route.points, p)));
    }
    return out;
  }

  /// The quickest way that is blocked, from the driver onwards, and where to
  /// say why. Shown so the driver is not left wondering why the obvious road
  /// is not the one being taken.
  ({RouteScore score, List<LatLng> line, LatLng? label})? _blockedWay() {
    final active = _nav.route, blocked = _nav.choices?.blocked, at = _shownPos;
    if (active == null || blocked == null) return null;
    var line = blocked.route.points;
    if (at != null) {
      final p = progressAlong(line, at);
      if (p == null || p.offRouteMeters > kOffRouteMeters) return null;
      line = remainingLine(line, p);
    }
    if (_blockedFor != blocked.route.key) {
      _blockedFor = blocked.route.key;
      // On the stretch the blocked way does not share with the route being
      // driven — which is where the blockage is.
      final spot = blocked.blockers.firstOrNull?.location;
      _blockedLabel = spot ?? labelAnchor(blocked.route.points, active.route.points);
    }
    return (score: blocked, line: line, label: _blockedLabel);
  }

  String? _blockedFor;
  LatLng? _blockedLabel;

  Map<String, LatLng?> _labelAnchors(
    RouteScore active,
    List<({RouteScore score, List<LatLng> line})> others,
  ) {
    final key = [active.route.key, ...others.map((o) => o.score.route.key)]
        .join('|');
    if (key != _anchorsFor) {
      _anchorsFor = key;
      _anchors = {
        for (final o in others)
          o.score.route.key: labelAnchor(
            o.score.route.points,
            active.route.points,
            // Each label where its route goes its own way, so two
            // alternatives sharing a road do not stack their labels on it.
            others: [
              for (final x in others)
                if (!identical(x, o)) x.score.route.points,
            ],
          ),
      };
    }
    return _anchors;
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final active = _nav.route;
    final at = _shownPos ?? _nav.shownPosition;
    final target = _nav.target;
    final others = _otherLines();
    final anchors = active == null
        ? const <String, LatLng?>{}
        : _labelAnchors(active, others);
    final activeLine = _activeLine();
    final blockedWay = _blockedWay();

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: at ?? target ?? const LatLng(14.954, 120.901),
              initialZoom: _followZoom,
              onMapReady: () {
                _mapReady = true;
                _followCamera();
              },
              onPositionChanged: (camera, hasGesture) {
                // The driver moved the map by hand: stop dragging it back.
                if (hasGesture && _camera != _Camera.free) {
                  setState(() => _camera = _Camera.free);
                }
              },
            ),
            children: [
              const AppTileLayer(),
              if (at != null) TrafficOverlay(origin: at, radiusKm: 3),
              // Alternatives under the route being driven, lighter, so the
              // fastest way reads first.
              PolylineLayer(
                polylines: [
                  // The blocked way, dashed and grey: visible, clearly not a
                  // choice.
                  if (blockedWay != null && blockedWay.line.length >= 2)
                    Polyline(
                      points: blockedWay.line,
                      strokeWidth: 5,
                      color: const Color(0xFF9E9E9E),
                      pattern: StrokePattern.dashed(segments: const [12, 10]),
                    ),
                  for (final o in others) ...[
                    Polyline(
                      points: o.line,
                      strokeWidth: 10,
                      color: Colors.white.withValues(alpha: 0.9),
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                    Polyline(
                      points: o.line,
                      strokeWidth: 6,
                      color: _altBlue,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                  ],
                  if (activeLine.length >= 2) ...[
                    Polyline(
                      points: activeLine,
                      strokeWidth: 12,
                      color: Colors.white,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                    Polyline(
                      points: activeLine,
                      strokeWidth: 8,
                      color: active?.route.isRealRoute == false
                          ? AppTheme.warning
                          : _routeBlue,
                      strokeCap: StrokeCap.round,
                      strokeJoin: StrokeJoin.round,
                    ),
                  ],
                ],
              ),
              MarkerLayer(
                markers: [
                  if (blockedWay?.label != null)
                    Marker(
                      point: blockedWay!.label!,
                      width: 190,
                      height: 40,
                      rotate: true,
                      child: _BlockedLabel(
                        text: blockedWay.score.conditionLabel,
                      ),
                    ),
                  if (target != null)
                    Marker(
                      point: target,
                      width: 44,
                      height: 44,
                      rotate: true,
                      child: const _Destination(),
                    ),
                  if (active != null)
                    for (final o in others)
                      if (anchors[o.score.route.key] != null)
                        Marker(
                          point: anchors[o.score.route.key]!,
                          width: 124,
                          height: 40,
                          rotate: true,
                          child: _RouteLabel(
                            text: timeDifferenceLabel(
                              alternativeSeconds: o.score.adjustedSeconds,
                              activeSeconds: active.adjustedSeconds,
                              estimate: o.score.isEstimate || active.isEstimate,
                            ),
                            onTap: () => _nav.useRoute(o.score),
                          ),
                        ),
                  if (at != null)
                    Marker(
                      point: at,
                      width: 56,
                      height: 56,
                      child: _DriverArrow(headingDegrees: _shownHeading),
                    ),
                ],
              ),
            ],
          ),

          // Instruction and any reroute message.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InstructionBanner(nav: _nav),
                  if (_nav.banner != null) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _RerouteNotice(text: _nav.banner!),
                  ],
                ],
              ),
            ),
          ),

          // Controls down the right, as in every navigation app.
          Positioned(
            right: AppSpacing.md,
            top: MediaQuery.of(context).padding.top + 190,
            child: Column(
              children: [
                _RoundButton(
                  icon: _headingUp ? Icons.navigation : Icons.explore,
                  tooltip: _headingUp ? 'Show north up' : 'Show direction up',
                  onTap: () {
                    setState(() => _headingUp = !_headingUp);
                    _recenter();
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                ListenableBuilder(
                  listenable: VoiceService.instance,
                  builder: (context, _) => _RoundButton(
                    icon: VoiceService.instance.enabled
                        ? Icons.volume_up
                        : Icons.volume_off,
                    tooltip: VoiceService.instance.enabled
                        ? 'Mute voice guidance'
                        : 'Unmute voice guidance',
                    onTap: () => VoiceService.instance.setEnabled(
                      !VoiceService.instance.enabled,
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _RoundButton(
                  icon: Icons.add_alert,
                  tooltip: 'Report a road condition',
                  color: AppTheme.warning,
                  onTap: () => showQuickReportSheet(
                    context,
                    tripId: _nav.bookingId,
                    at: _nav.position,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                _RoundButton(
                  icon: Icons.alt_route,
                  tooltip: 'See all routes',
                  onTap: _showOverview,
                ),
              ],
            ),
          ),

          if (_camera != _Camera.follow)
            Positioned(
              left: AppSpacing.md,
              bottom: 150,
              child: FloatingActionButton.extended(
                heroTag: 'recenter',
                onPressed: _recenter,
                icon: const Icon(Icons.my_location),
                label: const Text('Re-centre'),
              ),
            ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _TripSummary(
              nav: _nav,
              onEnd: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Pieces ----------------------------------------------------------------

class _InstructionBanner extends StatelessWidget {
  const _InstructionBanner({required this.nav});
  final LiveNavigation nav;

  @override
  Widget build(BuildContext context) {
    final String title;
    final String? subtitle;
    final IconData icon;

    final turn = nav.upcoming;
    if (nav.position == null) {
      icon = Icons.gps_not_fixed;
      title = 'Waiting for GPS…';
      subtitle = null;
    } else if (nav.route == null) {
      icon = Icons.route;
      title = 'Finding your route…';
      subtitle = null;
    } else if (nav.arrived) {
      icon = Icons.flag;
      title = 'You have arrived';
      subtitle = nav.phase == NavigationPhase.toPickup
          ? 'Confirm the pickup on the trip screen'
          : 'Complete the trip on the trip screen';
    } else if (nav.isOffRoute) {
      // The GPS is off the line. Rerouting takes a few readings, so the
      // driver is told plainly what to do in the meantime.
      icon = Icons.u_turn_right;
      title = 'Proceed to the route';
      subtitle = '${formatDistance(nav.progress!.offRouteMeters)} away';
    } else if (turn != null) {
      icon = _maneuverIcon(turn);
      title = formatDistance(turn.metersAway);
      subtitle = turn.step.instruction;
    } else {
      icon = Icons.straight;
      title = 'Follow the route';
      subtitle = null;
    }

    return Material(
      color: const Color(0xFF1F3B3A),
      elevation: 6,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 48),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      height: 1.1,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _maneuverIcon(UpcomingTurn turn) {
    if (turn.isArrival) return Icons.flag;
    return switch (turn.step.modifier) {
      'left' || 'sharp left' => Icons.turn_left,
      'slight left' => Icons.turn_slight_left,
      'right' || 'sharp right' => Icons.turn_right,
      'slight right' => Icons.turn_slight_right,
      'uturn' => Icons.u_turn_left,
      _ => switch (turn.step.maneuver) {
        'roundabout' || 'rotary' => Icons.roundabout_right,
        'merge' => Icons.merge,
        'fork' => Icons.fork_right,
        _ => Icons.straight,
      },
    };
  }
}

class _RerouteNotice extends StatelessWidget {
  const _RerouteNotice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Material(
    color: _routeBlue,
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          const Icon(Icons.alt_route, color: Colors.white),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Arrival time, time left and distance left — the three numbers a driver
/// glances down for.
class _TripSummary extends StatelessWidget {
  const _TripSummary({required this.nav, required this.onEnd});
  final LiveNavigation nav;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final remaining = nav.remaining;
    final metres = nav.remainingMeters;
    final estimate = nav.route?.isEstimate ?? false;
    final arrival = remaining == null ? null : arrivalTime(remaining);
    final incidents = nav.route?.incidentsOnRoute ?? const [];

    String clock(DateTime t) {
      final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return '$h:${t.minute.toString().padLeft(2, '0')}';
    }

    return Material(
      color: const Color(0xFF1F3B3A),
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (incidents.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Text(
                    nav.route!.conditionLabel,
                    style: const TextStyle(color: Color(0xFFFFCC80)),
                  ),
                ),
              Row(
                children: [
                  _Figure(
                    value: arrival == null ? '--' : clock(arrival),
                    label: 'arrival',
                  ),
                  _Figure(
                    value: remaining == null
                        ? '--'
                        : '${estimate ? '≈' : ''}'
                              '${math.max(1, (remaining.inSeconds / 60).round())}',
                    label: 'min',
                  ),
                  _Figure(
                    value: metres == null
                        ? '--'
                        : metres < 1000
                        ? '${(metres / 10).round() * 10}'
                        : (metres / 1000).toStringAsFixed(1),
                    label: metres != null && metres < 1000 ? 'm' : 'km',
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: onEnd,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.errorRed,
                      minimumSize: const Size(64, 48),
                    ),
                    child: const Text('End'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label});
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 15)),
      ],
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color = Colors.white,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF1F3B3A),
    shape: const CircleBorder(),
    elevation: 4,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 28,
      padding: const EdgeInsets.all(14),
      icon: Icon(icon, color: color),
    ),
  );
}

/// "2 min slower", sitting on the alternative's own road. Tapping it takes
/// that route.
class _RouteLabel extends StatelessWidget {
  const _RouteLabel({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1F3B3A),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: _altBlue,
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ),
    ),
  );
}

/// Why the obvious road is not the one being taken. Not tappable: a blocked
/// road is not a choice.
class _BlockedLabel extends StatelessWidget {
  const _BlockedLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF3A3A3A),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.block, size: 16, color: Color(0xFFFF8A80)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The driver: an arrow pointing the way they face, in world terms. The
/// marker turns with the map, so rotating it by the compass heading keeps
/// it pointing down the road in both heading-up and north-up views.
class _DriverArrow extends StatelessWidget {
  const _DriverArrow({required this.headingDegrees});
  final double headingDegrees;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: _routeBlue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
      ),
      child: Transform.rotate(
        angle: headingDegrees * math.pi / 180,
        child: const Icon(Icons.navigation, color: Colors.white, size: 26),
      ),
    ),
  );
}

class _Destination extends StatelessWidget {
  const _Destination();

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppTheme.primaryGreen,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
    ),
    child: const Icon(Icons.flag, color: Colors.white, size: 22),
  );
}
