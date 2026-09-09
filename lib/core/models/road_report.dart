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

  /// How bad this condition is for someone trying to get through, 0 (clear)
  /// to 1 (impassable). Drives the colour of the traffic overlay.
  double get severity => switch (this) {
    ReportType.trafficClear => 0,
    ReportType.trafficModerate => 0.5,
    ReportType.trafficHeavy => 1,
    ReportType.breakdown => 0.5,
    ReportType.hazard => 0.55,
    ReportType.flooding => 0.75,
    ReportType.accident => 0.9,
    ReportType.roadClosure => 1,
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

/// How much an incident is trusted.
///
/// A single report is not treated as established fact: one person can be
/// mistaken, or malicious. Corroboration promotes an incident on its own,
/// and an admin can settle it either way from the dashboard.
enum IncidentStatus {
  reported('REPORTED'),
  verifying('VERIFYING'),
  confirmed('CONFIRMED'),
  rejected('REJECTED'),
  expired('EXPIRED');

  const IncidentStatus(this.wire);
  final String wire;

  static IncidentStatus? fromWire(String? value) {
    if (value == null) return null;
    for (final s in IncidentStatus.values) {
      if (s.wire == value) return s;
    }
    return null;
  }

  /// An admin's word is final and is never recomputed from report counts.
  bool get isAdminDecision =>
      this == IncidentStatus.confirmed || this == IncidentStatus.rejected;

  /// Whether this incident may influence what the driver is shown and how
  /// routes are scored. Rejected and expired incidents influence nothing.
  bool get isTrusted =>
      this != IncidentStatus.rejected && this != IncidentStatus.expired;

  String get label => switch (this) {
    IncidentStatus.reported => 'Reported',
    IncidentStatus.verifying => 'Being confirmed',
    IncidentStatus.confirmed => 'Confirmed',
    IncidentStatus.rejected => 'Dismissed',
    IncidentStatus.expired => 'Expired',
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
  final DateTime? updatedAt;
  final DateTime? expiresAt;
  final bool cleared;

  /// Whatever status is stored on the document. Only meaningful when an
  /// admin has ruled on it — otherwise [status] derives the value.
  final IncidentStatus? storedStatus;

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
    this.updatedAt,
    this.expiresAt,
    this.cleared = false,
    this.storedStatus,
  });

  /// How many people have reported this, counting the original reporter.
  int get reportCount => confirmations + 1;

  /// The status to act on.
  ///
  /// An admin ruling wins outright. Otherwise expiry comes first — a stale
  /// incident is expired no matter how many people once agreed — and below
  /// that, corroboration promotes it.
  IncidentStatus statusAt(DateTime now) {
    final stored = storedStatus;
    if (stored != null && stored.isAdminDecision) return stored;
    if (cleared) return IncidentStatus.expired;
    final until = expiresAt;
    if (until != null && !now.isBefore(until)) return IncidentStatus.expired;
    if (confirmations >= 3) return IncidentStatus.confirmed;
    if (confirmations >= 1) return IncidentStatus.verifying;
    return IncidentStatus.reported;
  }

  /// Convenience for call sites that already know the clock is now.
  IncidentStatus get status => statusAt(DateTime.now());

  /// A report is live until it expires or someone marks it cleared.
  bool isLive(DateTime now) {
    if (cleared) return false;
    if (storedStatus == IncidentStatus.rejected) return false;
    final until = expiresAt;
    if (until == null) return true;
    return now.isBefore(until);
  }

  bool confirmedByUser(String uid) => confirmedBy.contains(uid);

  /// How much this report should count towards a zone's colour.
  ///
  /// Corroborated reports pull harder than a lone voice, and a report loses
  /// influence as it ages towards its expiry — so a zone fades out on its own
  /// as conditions go unconfirmed rather than staying red all afternoon.
  double weight(DateTime now) {
    final corroboration = 1 + confirmations.clamp(0, 8);
    final from = createdAt, until = expiresAt;
    var freshness = 1.0;
    if (from != null && until != null && until.isAfter(from)) {
      final total = until.difference(from).inSeconds;
      final elapsed = now.difference(from).inSeconds.clamp(0, total);
      freshness = 1 - 0.6 * (elapsed / total);
    }
    return corroboration * freshness;
  }

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
      updatedAt: conv(data['updatedAt']),
      expiresAt: conv(data['expiresAt']),
      cleared: data['cleared'] as bool? ?? false,
      storedStatus: IncidentStatus.fromWire(data['status'] as String?),
    );
  }
}

/// Several reports of the same thing, shown as one incident.
class Incident {
  /// Worst-first, so [primary] is the most serious report in the group.
  final List<RoadReport> reports;
  final LatLng location;

  const Incident({required this.reports, required this.location});

  RoadReport get primary => reports.first;
  ReportType get type => primary.type;

  /// Everyone who reported it — the original reporter of each grouped
  /// report, plus everyone who confirmed one.
  int get reportCount =>
      reports.fold(0, (sum, r) => sum + r.reportCount);

  IncidentStatus statusAt(DateTime now) {
    // The group is as trusted as its best-supported member, except that an
    // admin dismissal of the primary report settles it.
    if (primary.storedStatus == IncidentStatus.rejected) {
      return IncidentStatus.rejected;
    }
    if (reports.any((r) => r.statusAt(now) == IncidentStatus.confirmed) ||
        reportCount >= 4) {
      return IncidentStatus.confirmed;
    }
    if (reportCount >= 2) return IncidentStatus.verifying;
    return primary.statusAt(now);
  }

  DateTime? get newestReport {
    DateTime? newest;
    for (final r in reports) {
      final at = r.createdAt;
      if (at == null) continue;
      if (newest == null || at.isAfter(newest)) newest = at;
    }
    return newest;
  }

  String summary(DateTime now) {
    final count = reportCount;
    final age = primary.ageLabel(now);
    return count == 1
        ? 'Reported $age'
        : '$count reports · latest $age';
  }
}

/// How close two reports of the same type must be to be the same incident.
///
/// Wider than the submit-time dedupe radius, because reports that arrive
/// from opposite ends of the same jam should still read as one problem.
const double kIncidentGroupingKm = 0.25;

/// Groups nearby reports of the same type into single incidents.
///
/// Three drivers reporting the same accident should be one marker saying
/// "3 reports", not three markers implying three accidents.
List<Incident> groupIncidents(
  Iterable<RoadReport> reports, {
  required DateTime now,
  double radiusKm = kIncidentGroupingKm,
}) {
  // Worst first so the most serious report leads its group.
  final live = reports.where((r) => r.isLive(now)).toList()
    ..sort((a, b) => b.type.severity.compareTo(a.type.severity));

  final groups = <List<RoadReport>>[];
  for (final report in live) {
    List<RoadReport>? match;
    var best = double.infinity;
    for (final group in groups) {
      if (group.first.type != report.type) continue;
      final d = distanceKm(group.first.location, report.location);
      if (d <= radiusKm && d < best) {
        match = group;
        best = d;
      }
    }
    if (match == null) {
      groups.add([report]);
    } else {
      match.add(report);
    }
  }

  return [
    for (final group in groups)
      Incident(reports: group, location: group.first.location),
  ];
}

/// Straight-line distance in km — good enough for deciding whether a report
/// is near enough to show, without pulling in a routing call.
double distanceKm(LatLng a, LatLng b) =>
    const Distance().as(LengthUnit.Kilometer, a, b);

/// A patch of road that several reports agree about, drawn as one shaded
/// area on the map instead of a scatter of individual pins.
class CongestionZone {
  /// Weighted centre of the reports that make up this zone.
  final LatLng center;

  /// 0 (clear) to 1 (impassable) — the blended severity of its reports.
  final double severity;

  /// Drawn radius in metres. Grows a little with the number of reports, so a
  /// stretch several people flagged reads as bigger than a single sighting.
  final double radiusMeters;

  /// The reports behind this zone, worst first.
  final List<RoadReport> reports;

  const CongestionZone({
    required this.center,
    required this.severity,
    required this.radiusMeters,
    required this.reports,
  });

  /// The condition driving the zone's colour, used to label it.
  ReportType get dominantType => reports.first.type;

  /// Strong red through to a slight green, by severity.
  Color get color => severityColor(severity);

  /// Faint where conditions are slight, solid where they are bad.
  double get fillOpacity => 0.16 + 0.34 * severity.clamp(0.0, 1.0);

  String get label => severityLabel(severity);
}

/// The traffic colour ramp: a slight green through to a strong red.
///
/// Shared by the road segments and the fallback zone shading so the two
/// never disagree about what a given severity looks like.
Color severityColor(double severity) {
  const clear = Color(0xFF2E7D32);
  const light = Color(0xFFC0CA33);
  const moderate = Color(0xFFE58900);
  const heavy = Color(0xFFEF6C00);
  const severe = Color(0xFFD32F2F);

  final s = severity.clamp(0.0, 1.0);
  return switch (s) {
    < 0.25 => Color.lerp(clear, light, s / 0.25)!,
    < 0.5 => Color.lerp(light, moderate, (s - 0.25) / 0.25)!,
    < 0.75 => Color.lerp(moderate, heavy, (s - 0.5) / 0.25)!,
    _ => Color.lerp(heavy, severe, (s - 0.75) / 0.25)!,
  };
}

String severityLabel(double severity) => switch (severity) {
  < 0.25 => 'Clear',
  < 0.5 => 'Light traffic',
  < 0.75 => 'Moderate traffic',
  _ => 'Heavy traffic',
};

/// Groups nearby reports into shaded zones for the traffic overlay.
///
/// Greedy single-pass clustering: reports are taken worst-first, and each
/// one either joins the zone it is closest to or starts a new one. At the
/// handful-of-reports-per-city scale this app works at, that is both cheap
/// and stable enough that zones don't jump around between rebuilds.
List<CongestionZone> buildCongestionZones(
  Iterable<RoadReport> reports, {
  required DateTime now,
  double clusterRadiusKm = 0.4,
}) {
  final live = reports.where((r) => r.isLive(now)).toList()
    ..sort((a, b) => b.type.severity.compareTo(a.type.severity));
  if (live.isEmpty) return const [];

  final groups = <List<RoadReport>>[];
  for (final report in live) {
    List<RoadReport>? nearest;
    var nearestDistance = double.infinity;
    for (final group in groups) {
      final d = distanceKm(group.first.location, report.location);
      if (d <= clusterRadiusKm && d < nearestDistance) {
        nearest = group;
        nearestDistance = d;
      }
    }
    if (nearest == null) {
      groups.add([report]);
    } else {
      nearest.add(report);
    }
  }

  return groups.map((group) {
    var totalWeight = 0.0;
    var weightedSeverity = 0.0;
    var lat = 0.0;
    var lng = 0.0;
    for (final r in group) {
      final w = r.weight(now);
      totalWeight += w;
      weightedSeverity += r.type.severity * w;
      lat += r.location.latitude * w;
      lng += r.location.longitude * w;
    }
    // Every weight is positive, but guard the division rather than risk a
    // NaN reaching the map layer.
    if (totalWeight <= 0) {
      return CongestionZone(
        center: group.first.location,
        severity: group.first.type.severity,
        radiusMeters: 180,
        reports: group,
      );
    }
    return CongestionZone(
      center: LatLng(lat / totalWeight, lng / totalWeight),
      severity: (weightedSeverity / totalWeight).clamp(0.0, 1.0),
      radiusMeters: 160 + 110 * (weightedSeverity / totalWeight) +
          35 * (group.length - 1).clamp(0, 6),
      reports: group,
    );
  }).toList();
}

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
