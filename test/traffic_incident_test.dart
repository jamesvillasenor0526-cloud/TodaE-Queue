/// Tests for the TomTom incidents parser, against a response captured live
/// over Baliwag — 24 real incidents, 23 jams and one set of roadworks, all
/// as LineStrings along actual roads.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
import 'package:toda_equeue_plus/core/services/traffic_incident_service.dart';

void main() {
  final body = File(
    'test/fixtures/tomtom_baliwag_incidents.json',
  ).readAsStringSync();

  group('parsing what Baliwag actually returned', () {
    test('reads every incident', () {
      expect(parseTomTomIncidents(body), hasLength(24));
    });

    test('every incident has a drawable line', () {
      // TomTom returns LineStrings along the road, which is why these need
      // none of the Overpass snapping a driver's point report does.
      for (final i in parseTomTomIncidents(body)) {
        expect(i.points.length, greaterThan(1), reason: i.id);
      }
    });

    test('the jams come through as heavy traffic', () {
      final incidents = parseTomTomIncidents(body);
      final jams = incidents.where(
        (i) => i.type == ReportType.trafficHeavy,
      );
      expect(jams.length, 23);
    });

    test('roadworks map to construction', () {
      final incidents = parseTomTomIncidents(body);
      expect(
        incidents.where((i) => i.type == ReportType.construction),
        hasLength(1),
      );
    });

    test('carries the measured delay', () {
      final withDelay = parseTomTomIncidents(
        body,
      ).where((i) => i.delaySeconds > 0);
      expect(withDelay, isNotEmpty);
      // The worst jam in the capture was around 41 minutes.
      final worst = withDelay
          .map((i) => i.delaySeconds)
          .reduce((a, b) => a > b ? a : b);
      expect(worst, greaterThan(2000));
    });

    test('names the stretch of road affected', () {
      final named = parseTomTomIncidents(
        body,
      ).where((i) => i.where.isNotEmpty);
      expect(named, isNotEmpty);
      expect(named.first.where, contains('→'));
    });

    test('describes what is happening', () {
      final described = parseTomTomIncidents(
        body,
      ).where((i) => i.description.isNotEmpty);
      expect(described, isNotEmpty);
    });

    test('separates the serious ones from the trivial', () {
      final incidents = parseTomTomIncidents(body);
      final significant = incidents.where((i) => i.isSignificant);
      // Not all of them, or the flag would mean nothing.
      expect(significant, isNotEmpty);
      expect(significant.length, lessThan(incidents.length));
    });

    test('a delay is phrased in minutes', () {
      final worst = parseTomTomIncidents(body).reduce(
        (a, b) => a.delaySeconds > b.delaySeconds ? a : b,
      );
      expect(worst.delayLabel, contains('min'));
    });
  });

  group('category mapping', () {
    test('covers the categories TomTom documents', () {
      const expected = {
        1: ReportType.accident,
        6: ReportType.trafficHeavy,
        7: ReportType.hazard,
        8: ReportType.roadClosure,
        9: ReportType.construction,
        11: ReportType.flooding,
        14: ReportType.breakdown,
      };
      expected.forEach((category, type) {
        expect(reportTypeForTomTomCategory(category), type, reason: '$category');
      });
    });

    test('weather and unknown fall back to a hazard, not a crash', () {
      // The app has no separate idea of fog or ice, and for a tricycle they
      // amount to the same warning.
      for (final c in [0, 2, 3, 4, 5, 10, 99, -1]) {
        expect(reportTypeForTomTomCategory(c), ReportType.hazard, reason: '$c');
      }
    });
  });

  group('corroborating a driver report', () {
    final incidents = parseTomTomIncidents(body);
    // A point taken from one of the jams TomTom actually reported.
    final onAJam = incidents
        .firstWhere((i) => i.type == ReportType.trafficHeavy)
        .points
        .first;

    test('agrees when a driver reports the jam it can see', () {
      expect(
        liveTrafficAgreesWith(ReportType.trafficHeavy, onAJam, incidents),
        isTrue,
      );
    });

    test('does not agree about somewhere far away', () {
      // Manila, well outside the captured box.
      expect(
        liveTrafficAgreesWith(
          ReportType.trafficHeavy,
          const LatLng(14.5995, 120.9842),
          incidents,
        ),
        isFalse,
      );
    });

    test('a measured jam backs up the things that cause one', () {
      // TomTom reports almost everything as a jam, so a jam where a driver
      // reports an accident is consistent, not contradictory.
      for (final reported in [
        ReportType.accident,
        ReportType.roadClosure,
        ReportType.breakdown,
        ReportType.trafficModerate,
      ]) {
        expect(
          liveTrafficAgreesWith(reported, onAJam, incidents),
          isTrue,
          reason: reported.name,
        );
      }
    });

    test('a jam does not vouch for an unrelated report', () {
      // Nothing about slow traffic says the road is flooded.
      for (final unrelated in [
        ReportType.flooding,
        ReportType.fallenTree,
        ReportType.checkpoint,
      ]) {
        expect(
          liveTrafficAgreesWith(unrelated, onAJam, incidents),
          isFalse,
          reason: unrelated.name,
        );
      }
    });

    test('silence is never treated as disagreement', () {
      // The whole point of the reports is what the feed cannot see. With no
      // incidents at all the answer is "not corroborated", which must leave
      // the report standing rather than counting against it.
      expect(
        liveTrafficAgreesWith(ReportType.accident, onAJam, const []),
        isFalse,
      );
    });

    test('corroboration lifts a lone report out of unverified', () {
      final alone = RoadReport(
        id: 'r',
        type: ReportType.trafficHeavy,
        location: onAJam,
        reportedBy: 'uid',
        reporterName: 'Test',
        reporterRole: 'driver',
        createdAt: DateTime(2026, 9, 9, 12),
        expiresAt: DateTime(2026, 9, 9, 13),
      );
      final backed = RoadReport(
        id: 'r',
        type: ReportType.trafficHeavy,
        location: onAJam,
        reportedBy: 'uid',
        reporterName: 'Test',
        reporterRole: 'driver',
        createdAt: DateTime(2026, 9, 9, 12),
        expiresAt: DateTime(2026, 9, 9, 13),
        corroboratedByTraffic: true,
      );
      final now = DateTime(2026, 9, 9, 12, 5);

      expect(alone.statusAt(now), IncidentStatus.reported);
      expect(backed.statusAt(now), IncidentStatus.verifying);
      // But it is still one person on the road, not two.
      expect(backed.reportCount, 1);
      expect(backed.corroborationCount, 1);
    });
  });

  group('degrading safely', () {
    test('junk and empty replies yield nothing', () {
      expect(parseTomTomIncidents('{"incidents":[]}'), isEmpty);
      expect(parseTomTomIncidents('<html>403</html>'), isEmpty);
      expect(parseTomTomIncidents('{}'), isEmpty);
      expect(parseTomTomIncidents(body.substring(0, 60)), isEmpty);
    });

    test('an incident with no geometry is skipped, not returned empty', () {
      const noGeometry =
          '{"incidents":[{"properties":{"id":"x","iconCategory":6}}]}';
      expect(parseTomTomIncidents(noGeometry), isEmpty);
    });

    test('a Point geometry is read as well as a LineString', () {
      const point =
          '{"incidents":[{"geometry":{"type":"Point",'
          '"coordinates":[120.9,14.95]},'
          '"properties":{"id":"p","iconCategory":1}}]}';
      final parsed = parseTomTomIncidents(point);
      expect(parsed, hasLength(1));
      expect(parsed.first.type, ReportType.accident);
      expect(parsed.first.points.first.latitude, 14.95);
    });

    test('missing properties do not throw', () {
      const bare =
          '{"incidents":[{"geometry":{"type":"LineString",'
          '"coordinates":[[120.9,14.95],[120.91,14.96]]},"properties":{}}]}';
      final parsed = parseTomTomIncidents(bare);
      expect(parsed, hasLength(1));
      expect(parsed.first.delaySeconds, 0);
      expect(parsed.first.type, ReportType.hazard);
    });
  });
}
