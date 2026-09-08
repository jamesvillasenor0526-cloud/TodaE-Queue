import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';

/// Baliwag city centre, used as the reference point for the geo tests.
const _center = LatLng(14.9540, 120.9010);

RoadReport _report({
  String id = 'r1',
  ReportType type = ReportType.trafficHeavy,
  LatLng? at,
  DateTime? createdAt,
  DateTime? expiresAt,
  bool cleared = false,
  int confirmations = 0,
  List<String> confirmedBy = const [],
  String reportedBy = 'user-a',
}) => RoadReport(
  id: id,
  type: type,
  location: at ?? _center,
  reportedBy: reportedBy,
  reporterName: 'Test',
  reporterRole: 'driver',
  createdAt: createdAt,
  expiresAt: expiresAt,
  cleared: cleared,
  confirmations: confirmations,
  confirmedBy: confirmedBy,
);

void main() {
  final now = DateTime(2026, 9, 8, 12);

  group('report types', () {
    test('every type round-trips through its wire value', () {
      for (final t in ReportType.values) {
        expect(ReportType.fromWire(t.wire), t, reason: t.name);
      }
    });

    test('unknown and missing wire values do not resolve to a type', () {
      expect(ReportType.fromWire('NOT_A_TYPE'), isNull);
      expect(ReportType.fromWire(null), isNull);
    });

    test('traffic expires sooner than incidents', () {
      expect(
        ReportType.trafficHeavy.lifespan,
        lessThan(ReportType.accident.lifespan),
      );
    });

    test('each type is filed under exactly one category', () {
      expect(ReportType.trafficModerate.category, ReportCategory.traffic);
      expect(ReportType.flooding.category, ReportCategory.incident);
    });
  });

  group('liveness', () {
    test('a report is live before its expiry', () {
      final r = _report(expiresAt: now.add(const Duration(minutes: 5)));
      expect(r.isLive(now), isTrue);
    });

    test('a report is not live once expired', () {
      final r = _report(expiresAt: now.subtract(const Duration(minutes: 1)));
      expect(r.isLive(now), isFalse);
    });

    test('a cleared report is not live even before its expiry', () {
      final r = _report(
        expiresAt: now.add(const Duration(hours: 2)),
        cleared: true,
      );
      expect(r.isLive(now), isFalse);
    });

    test('a report with no expiry is treated as live', () {
      expect(_report().isLive(now), isTrue);
    });
  });

  group('corroboration', () {
    test('a single unconfirmed report is not corroborated', () {
      expect(_report().isCorroborated, isFalse);
    });

    test('two or more confirmations count as corroborated', () {
      expect(_report(confirmations: 2).isCorroborated, isTrue);
    });

    test('confirmedByUser only matches users who actually confirmed', () {
      final r = _report(confirmedBy: const ['user-b']);
      expect(r.confirmedByUser('user-b'), isTrue);
      expect(r.confirmedByUser('user-c'), isFalse);
    });
  });

  group('visibleReports', () {
    // ~1.1 km north and ~11 km north of the centre.
    final near = LatLng(_center.latitude + 0.01, _center.longitude);
    final far = LatLng(_center.latitude + 0.1, _center.longitude);
    final live = now.add(const Duration(minutes: 20));

    test('keeps live reports inside the radius', () {
      final out = visibleReports(
        [_report(at: near, expiresAt: live)],
        _center,
        now: now,
      );
      expect(out, hasLength(1));
    });

    test('drops reports outside the radius', () {
      final out = visibleReports(
        [_report(at: far, expiresAt: live)],
        _center,
        now: now,
      );
      expect(out, isEmpty);
    });

    test('drops expired reports even when they are close by', () {
      final out = visibleReports(
        [
          _report(at: near, expiresAt: now.subtract(const Duration(minutes: 1))),
        ],
        _center,
        now: now,
      );
      expect(out, isEmpty);
    });

    test('sorts nearest first', () {
      final out = visibleReports(
        [
          _report(id: 'far', at: near, expiresAt: live),
          _report(id: 'near', at: _center, expiresAt: live),
        ],
        _center,
        now: now,
      );
      expect(out.map((r) => r.id), ['near', 'far']);
    });

    test('filters to one category when asked', () {
      final out = visibleReports(
        [
          _report(id: 't', type: ReportType.trafficHeavy, expiresAt: live),
          _report(id: 'i', type: ReportType.accident, expiresAt: live),
        ],
        _center,
        now: now,
        only: ReportCategory.incident,
      );
      expect(out.map((r) => r.id), ['i']);
    });
  });

  group('fromMap', () {
    test('reads a well-formed document', () {
      final r = RoadReport.fromMap('abc', {
        'type': 'FLOODING',
        'latitude': 14.95,
        'longitude': 120.90,
        'note': 'knee deep',
        'reportedBy': 'uid-1',
        'reporterName': 'Ana',
        'reporterRole': 'driver',
        'confirmations': 3,
        'confirmedBy': ['uid-2', 'uid-3'],
        'cleared': false,
        'createdAt': now,
      });

      expect(r.id, 'abc');
      expect(r.type, ReportType.flooding);
      expect(r.location.latitude, closeTo(14.95, 1e-9));
      expect(r.note, 'knee deep');
      expect(r.confirmations, 3);
      expect(r.confirmedBy, ['uid-2', 'uid-3']);
      expect(r.createdAt, now);
    });

    test('an int coordinate is still read as a number', () {
      final r = RoadReport.fromMap('abc', {
        'type': 'HAZARD',
        'latitude': 15,
        'longitude': 121,
      });
      expect(r.location.latitude, 15.0);
      expect(r.location.longitude, 121.0);
    });

    test('a malformed document does not throw', () {
      final r = RoadReport.fromMap('abc', const {});
      expect(r.type, ReportType.hazard);
      expect(r.confirmations, 0);
      expect(r.confirmedBy, isEmpty);
      expect(r.cleared, isFalse);
    });
  });

  group('ageLabel', () {
    test('describes recent, hourly and daily ages', () {
      expect(_report(createdAt: now).ageLabel(now), 'just now');
      expect(
        _report(createdAt: now.subtract(const Duration(minutes: 5)))
            .ageLabel(now),
        '5 min ago',
      );
      expect(
        _report(createdAt: now.subtract(const Duration(hours: 3)))
            .ageLabel(now),
        '3 h ago',
      );
      expect(
        _report(createdAt: now.subtract(const Duration(days: 2))).ageLabel(now),
        '2 d ago',
      );
    });

    test('falls back safely when the timestamp has not landed yet', () {
      // createdAt is a server timestamp, so it reads null for a moment
      // between the local write and the server ack.
      expect(_report().ageLabel(now), 'just now');
    });
  });
}
