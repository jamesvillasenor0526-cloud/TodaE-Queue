/// Live road incidents from TomTom, alongside the ones drivers report.
///
/// These are two different kinds of knowledge and the app keeps them
/// separate on purpose:
///
///   * TomTom's are measured and city-wide — mostly jams, with a real delay
///     in seconds. Authoritative, but impersonal and a little behind.
///   * A driver's report is local knowledge nothing else has: an accident
///     that happened two minutes ago, a flooded barangay road, a street
///     closed for a fiesta.
///
/// So TomTom incidents are shown but never confirmed, dismissed or edited —
/// they are not this app's data to rule on, and the verification lifecycle
/// belongs to reports people here actually filed.
///
/// They are also not stored in Firestore. They expire on TomTom's side and
/// re-reading them is cheaper and more honest than keeping a stale copy.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../config/api_keys.dart';
import '../models/road_report.dart';
import 'tomtom_router.dart';

/// One incident as TomTom reports it.
class TrafficIncident {
  final String id;

  /// Mapped onto the app's own vocabulary so it renders with the same
  /// icons and colours as a driver's report.
  final ReportType type;

  /// The affected stretch of road. TomTom returns these as LineStrings, so
  /// no snapping is needed to draw them along the road.
  final List<LatLng> points;

  /// Measured delay in seconds, where TomTom provides one.
  final double delaySeconds;

  /// 0 unknown, 1 minor, 2 moderate, 3 major, 4 undefined.
  final int magnitude;

  final String description;
  final String from;
  final String to;

  const TrafficIncident({
    required this.id,
    required this.type,
    required this.points,
    this.delaySeconds = 0,
    this.magnitude = 0,
    this.description = '',
    this.from = '',
    this.to = '',
  });

  LatLng? get midpoint =>
      points.isEmpty ? null : points[points.length ~/ 2];

  /// Only the serious ones are worth interrupting a driver about.
  bool get isSignificant => magnitude >= 2 || delaySeconds >= 300;

  String get delayLabel {
    if (delaySeconds <= 0) return description;
    final minutes = (delaySeconds / 60).round();
    return minutes < 1 ? description : '$description · about $minutes min';
  }

  String get where {
    if (from.isEmpty && to.isEmpty) return '';
    if (to.isEmpty) return from;
    if (from.isEmpty) return to;
    return '$from → $to';
  }
}

/// How close a measured incident must be to back up a report.
///
/// Generous, because TomTom places a jam along a whole stretch of road while
/// a driver reports the point they are sitting at.
const double kCorroborationMeters = 250;

/// Whether TomTom independently sees what a driver just reported.
///
/// Only ever used to *support* a report, never to contradict one. TomTom
/// lags, covers roads unevenly, and knows nothing about a barangay street —
/// so its silence is not evidence that a driver is wrong, and treating it
/// that way would suppress exactly the local knowledge this app exists to
/// collect.
///
/// Types must match, with one deliberate exception: TomTom reports almost
/// everything as a jam, so a measured jam also backs up the slower-moving
/// incident types, which do cause jams.
bool liveTrafficAgreesWith(
  ReportType reported,
  LatLng where,
  Iterable<TrafficIncident> incidents, {
  double withinMeters = kCorroborationMeters,
}) {
  const distance = Distance();

  for (final incident in incidents) {
    if (!_typesAgree(reported, incident.type)) continue;
    for (final p in incident.points) {
      if (distance.as(LengthUnit.Meter, where, p) <= withinMeters) return true;
    }
  }
  return false;
}

bool _typesAgree(ReportType reported, ReportType measured) {
  if (reported == measured) return true;
  // A measured jam is consistent with the things that cause one.
  if (measured == ReportType.trafficHeavy) {
    return reported == ReportType.trafficModerate ||
        reported == ReportType.accident ||
        reported == ReportType.roadClosure ||
        reported == ReportType.breakdown;
  }
  return false;
}

/// TomTom's iconCategory, mapped onto the app's report vocabulary.
///
/// The two sets line up closely, which is what lets a TomTom incident and a
/// driver's report be drawn with the same language instead of inventing a
/// second one. Weather categories collapse to a hazard: the app has no
/// separate idea of fog or ice, and for a tricycle they amount to the same
/// warning.
ReportType reportTypeForTomTomCategory(int category) => switch (category) {
  1 => ReportType.accident,
  6 => ReportType.trafficHeavy,
  7 => ReportType.hazard,
  8 => ReportType.roadClosure,
  9 => ReportType.construction,
  11 => ReportType.flooding,
  14 => ReportType.breakdown,
  // 2 fog, 3 dangerous conditions, 4 rain, 5 ice, 10 wind, 0 unknown.
  _ => ReportType.hazard,
};

class TrafficIncidentService {
  TrafficIncidentService._();
  static final TrafficIncidentService instance = TrafficIncidentService._();

  static const _host = 'api.tomtom.com';
  static const _timeout = Duration(seconds: 15);

  /// The free tier covers 2,500 requests a day across routing and this, so
  /// incidents are refreshed sparingly. Jams do not appear and clear inside
  /// a couple of minutes anyway.
  static const Duration minRefresh = Duration(minutes: 3);

  /// Half-width of the box fetched around the driver, in degrees — roughly
  /// 6 km, comfortably past the 5 km the map draws.
  static const double boxHalfWidth = 0.055;

  List<TrafficIncident> _cached = const [];
  DateTime? _fetchedAt;
  LatLng? _fetchedAround;
  Future<List<TrafficIncident>>? _inFlight;

  /// Incidents near [origin], from cache when it is still fresh.
  ///
  /// Returns whatever is cached on failure rather than nothing, so a dropped
  /// request does not blank the map.
  Future<List<TrafficIncident>> near(LatLng origin) async {
    if (!TomTomRouter.isConfigured) return const [];

    final now = DateTime.now();
    final movedFar =
        _fetchedAround == null ||
        const Distance().as(LengthUnit.Kilometer, _fetchedAround!, origin) > 3;
    final stale =
        _fetchedAt == null || now.difference(_fetchedAt!) >= minRefresh;

    if (!stale && !movedFar) return _cached;
    if (_inFlight != null) return _inFlight!;

    final future = _fetch(origin);
    _inFlight = future;
    try {
      final result = await future;
      return result;
    } finally {
      _inFlight = null;
    }
  }

  Future<List<TrafficIncident>> _fetch(LatLng origin) async {
    const fields =
        '{incidents{type,geometry{type,coordinates},properties{id,'
        'iconCategory,magnitudeOfDelay,events{description,code,iconCategory},'
        'startTime,endTime,from,to,length,delay}}}';

    final uri = Uri.https(_host, '/traffic/services/5/incidentDetails', {
      'key': ApiKeys.tomTom,
      'bbox':
          '${origin.longitude - boxHalfWidth},'
          '${origin.latitude - boxHalfWidth},'
          '${origin.longitude + boxHalfWidth},'
          '${origin.latitude + boxHalfWidth}',
      'fields': fields,
      'language': 'en-GB',
      'timeValidityFilter': 'present',
    });

    try {
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        debugPrint('TomTom incidents returned ${response.statusCode}');
        return _cached;
      }
      _cached = parseTomTomIncidents(response.body);
      _fetchedAt = DateTime.now();
      _fetchedAround = origin;
      return _cached;
    } catch (e) {
      // Keep showing what we had rather than clearing the map.
      debugPrint('TomTom incidents unavailable: $e');
      return _cached;
    }
  }

  @visibleForTesting
  void clearCache() {
    _cached = const [];
    _fetchedAt = null;
    _fetchedAround = null;
  }
}

/// Reads an Incident Details response.
///
/// Pure and tolerant: anything malformed yields fewer incidents rather than
/// an exception, because losing the overlay is survivable and a crash on a
/// driver's phone is not.
List<TrafficIncident> parseTomTomIncidents(String body) {
  try {
    final data = json.decode(body) as Map<String, dynamic>;
    final incidents = data['incidents'] as List?;
    if (incidents == null) return const [];

    final out = <TrafficIncident>[];
    for (final raw in incidents) {
      if (raw is! Map) continue;
      final props = raw['properties'];
      if (props is! Map) continue;

      final points = <LatLng>[];
      final geometry = raw['geometry'];
      if (geometry is Map) {
        final coords = geometry['coordinates'];
        // LineString gives [[lon,lat], ...]; Point gives [lon,lat].
        if (geometry['type'] == 'Point' && coords is List && coords.length >= 2) {
          final lon = (coords[0] as num?)?.toDouble();
          final lat = (coords[1] as num?)?.toDouble();
          if (lat != null && lon != null) points.add(LatLng(lat, lon));
        } else if (coords is List) {
          for (final c in coords) {
            if (c is! List || c.length < 2) continue;
            final lon = (c[0] as num?)?.toDouble();
            final lat = (c[1] as num?)?.toDouble();
            if (lat != null && lon != null) points.add(LatLng(lat, lon));
          }
        }
      }
      if (points.isEmpty) continue;

      final events = props['events'];
      final description = (events is List && events.isNotEmpty && events.first is Map)
          ? ((events.first as Map)['description'] as String? ?? '')
          : '';

      out.add(
        TrafficIncident(
          id: props['id'] as String? ?? '',
          type: reportTypeForTomTomCategory(
            (props['iconCategory'] as num?)?.toInt() ?? 0,
          ),
          points: points,
          delaySeconds: (props['delay'] as num?)?.toDouble() ?? 0,
          magnitude: (props['magnitudeOfDelay'] as num?)?.toInt() ?? 0,
          description: description,
          from: props['from'] as String? ?? '',
          to: props['to'] as String? ?? '',
        ),
      );
    }
    return out;
  } catch (e) {
    debugPrint('Could not read TomTom incidents: $e');
    return const [];
  }
}
