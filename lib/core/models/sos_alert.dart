/// An SOS alert: what it says, where it stands, and what may honestly be
/// told to the person who raised it.
///
/// Pure — no Firebase, no plugins — so the rules about status and wording are
/// tested without a device.
///
/// Why this exists: the old screen announced "Help is on the way" the moment
/// the button was pressed, before any admin had seen anything. No one was
/// notified either — the SOS notification was never called — so that promise
/// could be false for as long as nobody happened to open the SOS tab. An
/// alert now reports exactly how far it has got.
library;

import 'package:latlong2/latlong.dart';

/// Where an alert stands.
///
/// `active` and `resolved` are what older versions of the app write, and
/// stay valid. `acknowledged` and `cancelled` are new: the first so the person
/// in trouble can be told a human has seen it, the second so "I'm safe" is not
/// recorded as though an admin had dealt with it.
enum SosStatus {
  /// Raised; no admin has responded yet.
  active('active'),

  /// An admin has seen it and is responding.
  acknowledged('acknowledged'),

  /// Dealt with by an admin.
  resolved('resolved'),

  /// Called off by the person who raised it.
  cancelled('cancelled');

  const SosStatus(this.wire);
  final String wire;

  static SosStatus fromWire(String? s) => SosStatus.values.firstWhere(
    (v) => v.wire == s,
    // An unknown status is treated as open: wrongly showing an alert as
    // live is recoverable; wrongly hiding one is not.
    orElse: () => SosStatus.active,
  );

  /// Still needs someone's attention.
  bool get isOpen => this == active || this == acknowledged;
}

/// How the person raised the alert.
enum SosSeverity {
  /// "I need help now and can't explain." Also what every alert from an
  /// older app version is: none of them said, and none may be taken lightly.
  critical('critical'),

  /// "I have time to say what happened" — comes with a [SosCategory]. Still
  /// sounds the alarm: the category changes the label, not whether admins
  /// hear it, or a frightened person who picks the calmer option would get a
  /// slower answer.
  incident('incident');

  const SosSeverity(this.wire);
  final String wire;

  static SosSeverity fromWire(String? s) =>
      s == incident.wire ? incident : critical;
}

/// What happened, chosen with one tap — never typed.
enum SosCategory {
  accident('accident', 'Accident'),
  medical('medical', 'Medical emergency'),
  threat('threat', 'Robbery or threat'),
  harassment('harassment', 'Harassment'),
  breakdown('breakdown', 'Vehicle breakdown'),
  other('other', 'Something else');

  const SosCategory(this.wire, this.label);
  final String wire;
  final String label;

  static SosCategory? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// Where a location came from, for judging how far to trust it.
enum SosLocationSource {
  /// A fresh reading taken for this alert.
  gps('gps'),

  /// The phone's last known position — sent at once so the alert is never
  /// held up, then replaced by a fresh reading when one arrives.
  lastKnown('last-known');

  const SosLocationSource(this.wire);
  final String wire;

  static SosLocationSource? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// The trip the person was on when they raised the alert, if any.
///
/// For a passenger this is the most useful part of an SOS: which tricycle,
/// which driver. The old alert carried only a name and a role.
class SosTrip {
  final String bookingId;
  final String? driverId;
  final String? driverName;
  final String? driverPhone;
  final String? plateNumber;
  final String? bodyNumber;
  final String? passengerId;
  final String? passengerName;
  final String? passengerPhone;

  /// The trip's stage when the alert went up — [TripStatus.wire], e.g.
  /// `TRIP_IN_PROGRESS`. Whether the passenger was already on board changes
  /// what responders should expect to find.
  final String? tripStatus;

  const SosTrip({
    required this.bookingId,
    this.driverId,
    this.driverName,
    this.driverPhone,
    this.plateNumber,
    this.bodyNumber,
    this.passengerId,
    this.passengerName,
    this.passengerPhone,
    this.tripStatus,
  });

  Map<String, dynamic> toMap() => {
    'bookingId': bookingId,
    'driverId': driverId,
    'driverName': driverName,
    'driverPhone': driverPhone,
    'plateNumber': plateNumber,
    'bodyNumber': bodyNumber,
    'passengerId': passengerId,
    'passengerName': passengerName,
    'passengerPhone': passengerPhone,
    'tripStatus': tripStatus,
  };

  static SosTrip? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['bookingId'];
    if (id is! String || id.isEmpty) return null;
    String? s(String k) {
      final v = raw[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    return SosTrip(
      bookingId: id,
      driverId: s('driverId'),
      driverName: s('driverName'),
      driverPhone: s('driverPhone'),
      plateNumber: s('plateNumber'),
      bodyNumber: s('bodyNumber'),
      passengerId: s('passengerId'),
      passengerName: s('passengerName'),
      passengerPhone: s('passengerPhone'),
      tripStatus: s('tripStatus'),
    );
  }

  /// "Plate ABC 123 · Body #45 · Driver Juan", as much as is known.
  String get vehicleLine => [
    if (plateNumber != null) 'Plate $plateNumber',
    if (bodyNumber != null) 'Body #$bodyNumber',
    if (driverName != null) 'Driver $driverName',
  ].join(' · ');
}

class SosAlert {
  final String id;
  final String userId;
  final String userName;
  final String userRole;
  final String? userPhone;
  final SosStatus status;
  final SosSeverity severity;
  final SosCategory? category;

  /// Sent by holding the SOS button, for someone who cannot be seen asking
  /// for help. Nothing on their phone may give it away, and admins are told
  /// not to call them.
  final bool silent;
  final double? latitude;
  final double? longitude;
  final double? locationAccuracy;
  final DateTime? locationAt;
  final SosLocationSource? locationSource;
  final DateTime? triggeredAt;
  final DateTime? acknowledgedAt;
  final String? acknowledgedBy;
  final DateTime? resolvedAt;
  final DateTime? cancelledAt;

  /// Set by an admin who has decided to bring in emergency services.
  final DateTime? escalatedAt;
  final String? escalatedBy;
  final SosTrip? trip;

  const SosAlert({
    required this.id,
    required this.userId,
    required this.userName,
    required this.userRole,
    required this.status,
    this.severity = SosSeverity.critical,
    this.category,
    this.silent = false,
    this.userPhone,
    this.latitude,
    this.longitude,
    this.locationAccuracy,
    this.locationAt,
    this.locationSource,
    this.triggeredAt,
    this.acknowledgedAt,
    this.acknowledgedBy,
    this.resolvedAt,
    this.cancelledAt,
    this.escalatedAt,
    this.escalatedBy,
    this.trip,
  });

  bool get hasLocation => latitude != null && longitude != null;

  factory SosAlert.fromMap(
    String id,
    Map<String, dynamic> data, {
    required DateTime? Function(dynamic) toDate,
  }) {
    double? d(String k) => (data[k] as num?)?.toDouble();
    String? s(String k) {
      final v = data[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    return SosAlert(
      id: id,
      userId: s('userId') ?? '',
      userName: s('userName') ?? 'Unknown',
      userRole: s('userRole') ?? 'passenger',
      userPhone: s('userPhone'),
      status: SosStatus.fromWire(data['status'] as String?),
      severity: SosSeverity.fromWire(data['severity'] as String?),
      category: SosCategory.fromWire(data['category'] as String?),
      silent: data['silent'] == true,
      latitude: d('latitude'),
      longitude: d('longitude'),
      locationAccuracy: d('locationAccuracy'),
      locationAt: toDate(data['locationAt']),
      locationSource: SosLocationSource.fromWire(
        data['locationSource'] as String?,
      ),
      triggeredAt: toDate(data['triggeredAt']),
      acknowledgedAt: toDate(data['acknowledgedAt']),
      acknowledgedBy: s('acknowledgedBy'),
      resolvedAt: toDate(data['resolvedAt']),
      cancelledAt: toDate(data['cancelledAt']),
      escalatedAt: toDate(data['escalatedAt']),
      escalatedBy: s('escalatedBy'),
      trip: SosTrip.fromMap(data['trip']),
    );
  }
}

/// What the person who raised [alert] is told, in words that are true.
///
/// Never "help is on the way" until someone has actually responded: before
/// that, the honest answer is that the alert is waiting to be seen. And
/// never a claim that police or rescue are coming: an escalation means an
/// admin is calling them, which is all that can be said.
({String title, String detail}) sosStatusMessage(SosAlert alert) {
  final who = alert.acknowledgedBy ?? alert.escalatedBy ?? 'A TODA admin';
  if (alert.silent) {
    // Short and plain: this may be read with someone looking on.
    return switch (alert.status) {
      SosStatus.active => (
        title: 'Silent alert sent',
        detail:
            'Admins can see your location and trip. '
            "They won't call you.",
      ),
      SosStatus.acknowledged => (
        title: 'An admin has seen it',
        detail: alert.escalatedBy != null
            ? '$who is contacting emergency services.'
            : "$who is responding and won't call you.",
      ),
      _ => _closedMessage(alert.status),
    };
  }
  return switch (alert.status) {
    SosStatus.active => (
      title: alert.severity == SosSeverity.incident
          ? 'Help request sent'
          : 'SOS alert sent',
      detail:
          'TODA admins have been alerted. Waiting for one to respond — '
          'call 911 now if you are in danger.',
    ),
    SosStatus.acknowledged when alert.escalatedBy != null => (
      title: 'Emergency services are being contacted',
      detail: '$who is contacting them for you. Stay where it is safe.',
    ),
    SosStatus.acknowledged => (
      title: 'An admin has seen your alert',
      detail: '$who is responding. Stay where it is safe.',
    ),
    _ => _closedMessage(alert.status),
  };
}

({String title, String detail}) _closedMessage(SosStatus status) =>
    switch (status) {
      SosStatus.cancelled => (
        title: 'Alert cancelled',
        detail: 'You told us you are safe.',
      ),
      _ => (
        title: 'Alert resolved',
        detail: 'A TODA admin has closed this alert.',
      ),
    };

/// The path an open alert records: a point each time the person has moved
/// this far. Close enough to show which road and which way; far enough that
/// a phone lying still adds nothing.
const double kSosPathStepMeters = 10;

/// Points recorded per alert at most — about 20 km at one per 10 m, far
/// beyond any tricycle SOS, and well inside a database record's size limit.
const int kSosPathMaxPoints = 2000;

/// Whether moving to [next] adds a point to the path after [last].
bool extendsSosPath(LatLng? last, LatLng next) =>
    last == null ||
    const Distance().as(LengthUnit.Meter, last, next) >= kSosPathStepMeters;

/// A last known position older than this is not sent as the location.
///
/// At tricycle speeds ten minutes is several kilometres — far enough that
/// responders would go to the wrong place, which is worse than being told
/// there is no location and asking.
const Duration kMaxLastKnownAge = Duration(minutes: 10);

/// How the location in an alert should be described to the person who sent
/// it, so they know whether to tell responders where they are.
String sosLocationLine(SosAlert alert, DateTime now) {
  if (!alert.hasLocation) {
    return 'Location not available — say where you are when you call.';
  }
  final at = alert.locationAt;
  final age = at == null ? null : now.difference(at);
  final accuracy = alert.locationAccuracy;
  final parts = <String>[
    'Location shared',
    if (accuracy != null) 'within ${accuracy.round()} m',
    if (age != null)
      age.inSeconds < 60
          ? 'updated just now'
          : 'updated ${age.inMinutes} min ago',
  ];
  return parts.join(' · ');
}
