/// Crowd-sourced road conditions: traffic and incidents.
///
/// Both are the same shape — a geo-tagged report with a type, a lifespan and
/// a pin on the map — so they share one collection and one service rather
/// than being built twice.
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../../config/theme.dart';

/// Whether a report describes flowing traffic or a discrete incident.
/// Used for filtering and for how long the report stays live.
enum ReportCategory { traffic, incident }

enum ReportType {
  trafficHeavy('TRAFFIC_HEAVY', ReportCategory.traffic),
  trafficModerate('TRAFFIC_MODERATE', ReportCategory.traffic),
  trafficClear('TRAFFIC_CLEAR', ReportCategory.traffic),
  accident('ACCIDENT', ReportCategory.incident),
  roadClosure('ROAD_CLOSURE', ReportCategory.incident),
  flooding('FLOODING', ReportCategory.incident),
  hazard('HAZARD', ReportCategory.incident),
  breakdown('BREAKDOWN', ReportCategory.incident);

  const ReportType(this.wire, this.category);

  /// Value stored in Firestore.
  final String wire;
  final ReportCategory category;

  static ReportType? fromWire(String? value) {
    if (value == null) return null;
    for (final t in ReportType.values) {
      if (t.wire == value) return t;
    }
    return null;
  }

  String get label => switch (this) {
    ReportType.trafficHeavy => 'Heavy traffic',
    ReportType.trafficModerate => 'Moderate traffic',
    ReportType.trafficClear => 'Clear road',
    ReportType.accident => 'Accident',
    ReportType.roadClosure => 'Road closed',
    ReportType.flooding => 'Flooding',
    ReportType.hazard => 'Road hazard',
    ReportType.breakdown => 'Vehicle breakdown',
  };

  String get hint => switch (this) {
    ReportType.trafficHeavy => 'Barely moving',
    ReportType.trafficModerate => 'Slow but moving',
    ReportType.trafficClear => 'Traffic has cleared',
    ReportType.accident => 'Collision blocking the road',
    ReportType.roadClosure => 'Road is impassable',
    ReportType.flooding => 'Flooded and risky to cross',
    ReportType.hazard => 'Debris, potholes, or similar',
    ReportType.breakdown => 'Stalled vehicle in the way',
  };

  IconData get icon => switch (this) {
    ReportType.trafficHeavy => Icons.traffic,
    ReportType.trafficModerate => Icons.slow_motion_video,
    ReportType.trafficClear => Icons.check_circle_outline,
    ReportType.accident => Icons.car_crash,
    ReportType.roadClosure => Icons.block,
    ReportType.flooding => Icons.water,
    ReportType.hazard => Icons.warning_amber,
    ReportType.breakdown => Icons.build_circle_outlined,
  };

  Color get color => switch (this) {
    ReportType.trafficHeavy => AppTheme.errorRed,
    ReportType.trafficModerate => AppTheme.warning,
    ReportType.trafficClear => AppTheme.success,
    ReportType.accident => AppTheme.errorRed,
    ReportType.roadClosure => AppTheme.errorRed,
    ReportType.flooding => AppTheme.info,
    ReportType.hazard => AppTheme.warning,
    ReportType.breakdown => AppTheme.warning,
  };

  /// How long a report stays live before it stops being shown.
  ///
  /// Traffic changes minute to minute, so those expire quickly; an accident
  /// or closure is worth trusting for longer. Expiry is evaluated on read,
  /// so no scheduled cleanup job is required.
  Duration get lifespan => switch (category) {
    ReportCategory.traffic => const Duration(minutes: 30),
    ReportCategory.incident => const Duration(hours: 3),
  };
}

/// One crowd-sourced report.
class RoadReport {
  final String id;
  final ReportType type;
  final LatLng location;
  final String? note;
  final String? photoUrl;
  final String reportedBy;
  final String reporterName;
  final String reporterRole;
  final int confirmations;
  final List<String> confirmedBy;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final bool cleared;

  const RoadReport({
    required this.id,
    required this.type,
    required this.location,
    required this.reportedBy,
    required this.reporterName,
    required this.reporterRole,
    this.note,
    this.photoUrl,
    this.confirmations = 0,
    this.confirmedBy = const [],
    this.createdAt,
    this.expiresAt,
    this.cleared = false,
  });

  /// A report is live until it expires or someone marks it cleared.
  bool isLive(DateTime now) {
    if (cleared) return false;
    final until = expiresAt;
    if (until == null) return true;
    return now.isBefore(until);
  }

  bool confirmedByUser(String uid) => confirmedBy.contains(uid);

  /// Reports corroborated by others are worth trusting more; used to weight
  /// the marker so a single stale report doesn't dominate the map.
  bool get isCorroborated => confirmations >= 2;

  String ageLabel(DateTime now) {
    final at = createdAt;
    if (at == null) return 'just now';
    final d = now.difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  static double? _toDouble(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  /// Builds from a Firestore document. [toDate] converts whatever the
  /// backend returns for a timestamp into a DateTime, keeping this model
  /// free of a Firestore dependency so it can be unit tested.
  factory RoadReport.fromMap(
    String id,
    Map<String, dynamic> data, {
    DateTime? Function(dynamic)? toDate,
  }) {
    DateTime? conv(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      return toDate?.call(v);
    }

    return RoadReport(
      id: id,
      type: ReportType.fromWire(data['type'] as String?) ?? ReportType.hazard,
      location: LatLng(
        _toDouble(data['latitude']) ?? 0,
        _toDouble(data['longitude']) ?? 0,
      ),
      note: data['note'] as String?,
      photoUrl: data['photoUrl'] as String?,
      reportedBy: data['reportedBy'] as String? ?? '',
      reporterName: data['reporterName'] as String? ?? 'Someone',
      reporterRole: data['reporterRole'] as String? ?? 'passenger',
      confirmations: (data['confirmations'] as num?)?.toInt() ?? 0,
      confirmedBy: (data['confirmedBy'] as List?)?.cast<String>() ?? const [],
      createdAt: conv(data['createdAt']),
      expiresAt: conv(data['expiresAt']),
      cleared: data['cleared'] as bool? ?? false,
    );
  }
}

/// Straight-line distance in km — good enough for deciding whether a report
/// is near enough to show, without pulling in a routing call.
double distanceKm(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Kilometer, a, b);

/// Reports worth showing to someone at [origin]: live, within [radiusKm],
/// nearest first. Filtering happens client-side because the whole service
/// area is one small city and the live set stays tiny.
List<RoadReport> visibleReports(
  Iterable<RoadReport> all,
  LatLng origin, {
  required DateTime now,
  double radiusKm = 5,
  ReportCategory? only,
}) {
  final out = all
      .where((r) => r.isLive(now))
      .where((r) => only == null || r.type.category == only)
      .where((r) => distanceKm(origin, r.location) <= radiusKm)
      .toList();
  out.sort(
    (a, b) => distanceKm(origin, a.location)
        .compareTo(distanceKm(origin, b.location)),
  );
  return out;
}
