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
  final String? driverName;
  final String? driverPhone;
  final String? plateNumber;
  final String? bodyNumber;
  final String? passengerName;

  const SosTrip({
    required this.bookingId,
    this.driverName,
    this.driverPhone,
    this.plateNumber,
    this.bodyNumber,
    this.passengerName,
  });

  Map<String, dynamic> toMap() => {
    'bookingId': bookingId,
    'driverName': driverName,
    'driverPhone': driverPhone,
    'plateNumber': plateNumber,
    'bodyNumber': bodyNumber,
    'passengerName': passengerName,
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
      driverName: s('driverName'),
      driverPhone: s('driverPhone'),
      plateNumber: s('plateNumber'),
      bodyNumber: s('bodyNumber'),
      passengerName: s('passengerName'),
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
  final SosTrip? trip;

  const SosAlert({
    required this.id,
    required this.userId,
    required this.userName,
    required this.userRole,
    required this.status,
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
      latitude: d('latitude'),
      longitude: d('longitude'),
      locationAccuracy: d('locationAccuracy'),
      locationAt: toDate(data['locationAt']),
      locationSource: SosLocationSource.fromWire(data['locationSource'] as String?),
      triggeredAt: toDate(data['triggeredAt']),
      acknowledgedAt: toDate(data['acknowledgedAt']),
      acknowledgedBy: s('acknowledgedBy'),
      resolvedAt: toDate(data['resolvedAt']),
      cancelledAt: toDate(data['cancelledAt']),
      trip: SosTrip.fromMap(data['trip']),
    );
  }
}

/// What the person who raised [alert] is told, in words that are true.
///
/// Never "help is on the way" until someone has actually responded: before
/// that, the honest answer is that the alert is waiting to be seen.
({String title, String detail}) sosStatusMessage(SosAlert alert) =>
    switch (alert.status) {
      SosStatus.active => (
        title: 'SOS alert sent',
        detail:
            'TODA admins have been alerted. Waiting for one to respond — '
            'call 911 now if you are in danger.',
      ),
      SosStatus.acknowledged => (
        title: 'An admin has seen your alert',
        detail: alert.acknowledgedBy == null
            ? 'A TODA admin is responding. Stay where it is safe.'
            : '${alert.acknowledgedBy} is responding. Stay where it is safe.',
      ),
      SosStatus.resolved => (
        title: 'Alert resolved',
        detail: 'A TODA admin has closed this alert.',
      ),
      SosStatus.cancelled => (
        title: 'Alert cancelled',
        detail: 'You told us you are safe.',
      ),
    };

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
