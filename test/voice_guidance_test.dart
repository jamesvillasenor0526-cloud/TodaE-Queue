/// Tests for spoken guidance.
///
/// The failure mode here is not a crash, it is a phone that talks over
/// itself at someone driving a tricycle through traffic, so most of these
/// are about *not* speaking.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/navigation_state.dart';
import 'package:toda_equeue_plus/core/models/road_report.dart';
import 'package:toda_equeue_plus/core/models/voice_guidance.dart';

UpcomingTurn turn(double metersAway, {String road = 'B.S. Aquino Avenue'}) =>
    UpcomingTurn(
      step: NavStep(
        road: road,
        maneuver: 'turn',
        modifier: 'left',
        distanceMeters: 400,
      ),
      metersAway: metersAway,
    );

RoadReport report(
  ReportType type, {
  LatLng at = const LatLng(14.954, 120.901),
  int confirmations = 0,
}) => RoadReport(
  id: 'r',
  type: type,
  location: at,
  reportedBy: 'uid',
  reporterName: 'Test',
  reporterRole: 'driver',
  confirmations: confirmations,
  createdAt: DateTime(2026, 9, 9, 12),
  expiresAt: DateTime(2026, 9, 9, 13),
);

final now = DateTime(2026, 9, 9, 12, 5);

/// Far enough past the last utterance that the gap never masks a result.
DateTime later(int seconds) => now.add(Duration(seconds: seconds));

void main() {
  group('announcing a manoeuvre', () {
    test('says nothing while the turn is still far off', () {
      final guide = VoiceGuide();
      expect(guide.update(turn: turn(900), now: now), isNull);
    });

    test('prepares the driver at a useful distance', () {
      final guide = VoiceGuide();
      final said = guide.update(turn: turn(280), now: now);
      expect(said, 'In 300 meters, turn left onto B.S. Aquino Avenue.');
    });

    test('gives the plain instruction at the turn itself', () {
      final guide = VoiceGuide();
      guide.update(turn: turn(280), now: now);
      expect(
        guide.update(turn: turn(40), now: later(30)),
        'Turn left onto B.S. Aquino Avenue.',
      );
    });

    test('does not repeat itself on every fix', () {
      final guide = VoiceGuide();
      // A GPS fix a second arriving while the driver closes on one turn.
      expect(guide.update(turn: turn(280), now: now), isNotNull);
      for (var m = 270; m > 100; m -= 10) {
        expect(
          guide.update(turn: turn(m.toDouble()), now: later(300 - m)),
          isNull,
          reason: '$m m',
        );
      }
    });

    test('a turn that appears close is announced once, not twice', () {
      // On a short link the prepare and act cues would land seconds apart.
      final guide = VoiceGuide();
      expect(guide.update(turn: turn(100), now: now), 'Turn left onto B.S. Aquino Avenue.');
      expect(guide.update(turn: turn(30), now: later(60)), isNull);
    });

    test('a turn reached without warning is not announced afterwards', () {
      final guide = VoiceGuide();
      expect(guide.update(turn: turn(40), now: now), isNotNull);
      // Having already passed it, the prepare cue must never fire late.
      expect(guide.update(turn: turn(40), now: later(60)), isNull);
    });

    test('the next turn is announced even on the same road name', () {
      final guide = VoiceGuide();
      guide.update(turn: turn(40, road: 'Main'), now: now);
      final second = guide.update(
        turn: UpcomingTurn(
          step: const NavStep(
            road: 'Main',
            maneuver: 'turn',
            modifier: 'right',
            distanceMeters: 300,
          ),
          metersAway: 250,
        ),
        now: later(60),
      );
      expect(second, contains('turn right'));
    });

    test('arrival is spoken', () {
      final guide = VoiceGuide();
      final said = guide.update(
        turn: const UpcomingTurn(
          step: NavStep(road: 'L. Beltran Street', maneuver: 'arrive', distanceMeters: 0),
          metersAway: 20,
        ),
        now: now,
      );
      expect(said, 'You have arrived.');
    });

    test('prefers the phrasing the router supplied', () {
      final guide = VoiceGuide();
      final said = guide.update(
        turn: const UpcomingTurn(
          step: NavStep(
            road: 'Dona Remedios Trinidad Highway',
            maneuver: 'turn',
            modifier: 'left',
            distanceMeters: 400,
            text: 'Turn left onto Dona Remedios Trinidad Highway/AH26',
          ),
          metersAway: 40,
        ),
        now: now,
      );
      expect(said, 'Turn left onto Dona Remedios Trinidad Highway/AH26.');
    });
  });

  group('not talking over itself', () {
    test('two cues never land within a few seconds of each other', () {
      final guide = VoiceGuide();
      expect(guide.update(turn: turn(280), now: now), isNotNull);
      expect(
        guide.update(
          turn: turn(40),
          now: now.add(const Duration(seconds: 2)),
          reroute: RerouteReason.roadBlocked,
        ),
        isNull,
      );
    });

    test('a suppressed cue is not lost, only delayed', () {
      final guide = VoiceGuide();
      guide.update(turn: turn(280), now: now);
      guide.update(turn: turn(40), now: now.add(const Duration(seconds: 2)));
      expect(guide.update(turn: turn(35), now: later(30)), isNotNull);
    });
  });

  group('rerouting', () {
    test('says why the route changed', () {
      expect(
        VoiceGuide().update(
          turn: null,
          now: now,
          reroute: RerouteReason.roadBlocked,
        ),
        'Road blocked ahead. Taking a new route.',
      );
      expect(
        VoiceGuide().update(
          turn: null,
          now: now,
          reroute: RerouteReason.fasterRoute,
        ),
        'Taking a faster route.',
      );
    });

    test('the same reason is not repeated while it persists', () {
      final guide = VoiceGuide();
      expect(
        guide.update(turn: null, now: now, reroute: RerouteReason.offRoute),
        isNotNull,
      );
      expect(
        guide.update(
          turn: null,
          now: later(30),
          reroute: RerouteReason.offRoute,
        ),
        isNull,
      );
    });

    test('a new reason after the route settles is spoken again', () {
      final guide = VoiceGuide();
      guide.update(turn: null, now: now, reroute: RerouteReason.offRoute);
      guide.update(turn: null, now: later(30));
      expect(
        guide.update(
          turn: null,
          now: later(60),
          reroute: RerouteReason.offRoute,
        ),
        isNotNull,
      );
    });

    test('a reroute outranks the turn coming up', () {
      final guide = VoiceGuide();
      final said = guide.update(
        turn: turn(280),
        now: now,
        reroute: RerouteReason.roadBlocked,
      );
      expect(said, contains('Road blocked'));
    });
  });

  group('conditions ahead', () {
    Incident incident(ReportType type, {int confirmations = 0}) => Incident(
      reports: [report(type, confirmations: confirmations)],
      location: const LatLng(14.954, 120.901),
    );

    test('warns about a corroborated condition', () {
      final guide = VoiceGuide();
      expect(
        guide.update(
          turn: null,
          now: now,
          ahead: [incident(ReportType.flooding, confirmations: 2)],
        ),
        'Flooding reported ahead.',
      );
    });

    test('a single unverified report does not interrupt the driver', () {
      // It is already on the map. Speaking every maybe would train drivers
      // to stop listening, which costs them the warnings that matter.
      final guide = VoiceGuide();
      expect(
        guide.update(
          turn: null,
          now: now,
          ahead: [incident(ReportType.hazard)],
        ),
        isNull,
      );
    });

    test('the same condition is called out once, not every fix', () {
      final guide = VoiceGuide();
      final ahead = [incident(ReportType.accident, confirmations: 3)];
      expect(guide.update(turn: null, now: now, ahead: ahead), isNotNull);
      expect(guide.update(turn: null, now: later(30), ahead: ahead), isNull);
      expect(guide.update(turn: null, now: later(90), ahead: ahead), isNull);
    });

    test('a turn at hand outranks traffic half a kilometre away', () {
      final guide = VoiceGuide();
      final said = guide.update(
        turn: turn(40),
        now: now,
        ahead: [incident(ReportType.trafficHeavy, confirmations: 3)],
      );
      expect(said, contains('Turn left'));
    });
  });

  group('starting a new leg', () {
    test('reset lets the same turn be announced again', () {
      // Driving to the pickup and then to the destination can genuinely
      // involve the same turn twice.
      final guide = VoiceGuide();
      expect(guide.update(turn: turn(40), now: now), isNotNull);
      guide.reset();
      expect(guide.update(turn: turn(40), now: now), isNotNull);
    });
  });

  group('speaking distances the way a person would', () {
    test('rounds to something sayable', () {
      expect(spokenDistance(287), '300 meters');
      expect(spokenDistance(140), '150 meters');
      expect(spokenDistance(640), '600 meters');
      expect(spokenDistance(1500), '1.5 kilometers');
      expect(spokenDistance(2000), '2 kilometers');
    });

    test('never says zero', () {
      expect(spokenDistance(10), '50 meters');
      expect(spokenDistance(0), '50 meters');
    });
  });

  group('the upcoming manoeuvre', () {
    test('is the turn ahead, not the depart instruction', () {
      // A router's first instruction is "depart", and its distance is how
      // far to drive before the first real turn. Showing it verbatim tells
      // a driver "start driving, 1.9 km" and never names the turn.
      const route = NavRoute(
        points: [LatLng(14.95, 120.9), LatLng(14.96, 120.91)],
        distanceMeters: 2000,
        durationSeconds: 400,
        steps: [
          NavStep(road: '', maneuver: 'depart', distanceMeters: 1851),
          NavStep(
            road: 'Dona Remedios Trinidad Highway',
            maneuver: 'turn',
            modifier: 'left',
            distanceMeters: 460,
          ),
        ],
      );
      final up = route.upcoming!;
      expect(up.step.maneuver, 'turn');
      expect(up.metersAway, 1851);
      expect(up.step.instruction, contains('Turn left'));
    });

    test('a route of nothing but depart has no manoeuvre to announce', () {
      const route = NavRoute(
        points: [LatLng(14.95, 120.9), LatLng(14.96, 120.91)],
        distanceMeters: 100,
        durationSeconds: 30,
        steps: [NavStep(road: '', maneuver: 'depart', distanceMeters: 100)],
      );
      expect(route.upcoming, isNull);
    });

    test('the same physical turn keeps one identity across refetches', () {
      // The route is rebuilt on every GPS fix; without a stable key the
      // guide would announce one turn over and over.
      expect(turn(280).key, turn(120).key);
    });
  });
}
