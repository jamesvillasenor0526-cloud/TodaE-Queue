/// Tests for SOS alerts: status, compatibility with alerts older versions
/// wrote, and — mostly — what the person in trouble is told.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/sos_alert.dart';

DateTime? _date(dynamic v) => v is DateTime ? v : null;

SosAlert alert(Map<String, dynamic> data) =>
    SosAlert.fromMap('a1', data, toDate: _date);

final now = DateTime(2026, 9, 11, 12, 0);

void main() {
  _noteTests();

  group('status', () {
    test('open means someone still has to act', () {
      expect(SosStatus.active.isOpen, isTrue);
      expect(SosStatus.acknowledged.isOpen, isTrue);
      expect(SosStatus.resolved.isOpen, isFalse);
      expect(SosStatus.cancelled.isOpen, isFalse);
    });

    test('an unknown status is treated as open, never hidden', () {
      // Wrongly showing an alert as live is recoverable; hiding one is not.
      expect(SosStatus.fromWire('something-new'), SosStatus.active);
      expect(SosStatus.fromWire(null), SosStatus.active);
    });
  });

  group('alerts written by the old app still read', () {
    // The 50 alerts in the database carry only these fields.
    final old = {
      'userId': 'u1',
      'userName': 'Erikka',
      'userRole': 'passenger',
      'latitude': null,
      'longitude': null,
      'status': 'resolved',
      'triggeredAt': DateTime(2026, 8, 31, 7, 13),
      'resolvedAt': null,
    };

    test('without a location', () {
      final a = alert(old);
      expect(a.hasLocation, isFalse);
      expect(a.status, SosStatus.resolved);
      expect(a.trip, isNull);
      expect(a.userPhone, isNull);
    });

    test('an old "active" alert is open', () {
      expect(alert({...old, 'status': 'active'}).status.isOpen, isTrue);
    });
  });

  group('what the person who raised it is told', () {
    test('never "help is on the way" before anyone has responded', () {
      // The old screen said it the instant the button was pressed, while no
      // one had been notified at all.
      final m = sosStatusMessage(alert({'status': 'active'}));
      expect(m.title.toLowerCase(), isNot(contains('help')));
      expect(m.detail.toLowerCase(), isNot(contains('on the way')));
      expect(m.detail, contains('Waiting'));
      expect(m.detail, contains('911'));
    });

    test('once an admin responds, says who', () {
      final m = sosStatusMessage(
        alert({'status': 'acknowledged', 'acknowledgedBy': 'Admin Reyes'}),
      );
      expect(m.title, contains('seen'));
      expect(m.detail, contains('Admin Reyes'));
    });

    test('acknowledged without a name still says a human is on it', () {
      final m = sosStatusMessage(alert({'status': 'acknowledged'}));
      expect(m.detail, contains('responding'));
    });

    test('cancelling is not reported as an admin resolving it', () {
      expect(
        sosStatusMessage(alert({'status': 'cancelled'})).title,
        isNot(sosStatusMessage(alert({'status': 'resolved'})).title),
      );
    });
  });

  group('describing the location', () {
    test('no location says to tell responders where you are', () {
      expect(
        sosLocationLine(alert({'status': 'active'}), now),
        contains('say where you are'),
      );
    });

    test('a fresh reading says how precise and how recent', () {
      final line = sosLocationLine(
        alert({
          'status': 'active',
          'latitude': 14.95,
          'longitude': 120.9,
          'locationAccuracy': 12.4,
          'locationAt': now.subtract(const Duration(seconds: 20)),
        }),
        now,
      );
      expect(line, contains('within 12 m'));
      expect(line, contains('just now'));
    });

    test('an older reading says how old', () {
      final line = sosLocationLine(
        alert({
          'status': 'active',
          'latitude': 14.95,
          'longitude': 120.9,
          'locationAt': now.subtract(const Duration(minutes: 4)),
        }),
        now,
      );
      expect(line, contains('4 min ago'));
    });
  });

  group('the trip', () {
    test('names the vehicle and driver for responders', () {
      final a = alert({
        'status': 'active',
        'trip': {
          'bookingId': 'b1',
          'driverName': 'Juan Dela Cruz',
          'plateNumber': 'ABC 123',
          'bodyNumber': '45',
        },
      });
      expect(
        a.trip!.vehicleLine,
        'Plate ABC 123 · Body #45 · Driver Juan Dela Cruz',
      );
    });

    test('says only what is known', () {
      final a = alert({
        'status': 'active',
        'trip': {'bookingId': 'b1', 'driverName': 'Juan', 'plateNumber': ' '},
      });
      expect(a.trip!.vehicleLine, 'Driver Juan');
    });

    test('a malformed trip is ignored rather than crashing', () {
      expect(alert({'status': 'active', 'trip': 'oops'}).trip, isNull);
      expect(
        alert({
          'status': 'active',
          'trip': {'driverName': 'x'},
        }).trip,
        isNull,
      );
    });
  });

  group('how it was raised', () {
    test('an alert that does not say is critical', () {
      // Every alert from an older app version, and anything unrecognised:
      // none may be taken as the less urgent kind.
      expect(alert({'status': 'active'}).severity, SosSeverity.critical);
      expect(
        alert({'status': 'active', 'severity': 'bogus'}).severity,
        SosSeverity.critical,
      );
      expect(alert({'status': 'active'}).silent, isFalse);
    });

    test('a help request carries what happened', () {
      final a = alert({
        'status': 'active',
        'severity': 'incident',
        'category': 'medical',
      });
      expect(a.severity, SosSeverity.incident);
      expect(a.category, SosCategory.medical);
      expect(sosStatusMessage(a).title, 'Help request sent');
    });

    test('an unknown category is dropped, not guessed', () {
      expect(alert({'status': 'active', 'category': 'fire'}).category, isNull);
    });

    test('only a real true makes an alert silent', () {
      expect(alert({'status': 'active', 'silent': 'yes'}).silent, isFalse);
      expect(alert({'status': 'active', 'silent': true}).silent, isTrue);
    });
  });

  group('a silent alert', () {
    test('says admins will not call, without alarming words', () {
      final m = sosStatusMessage(alert({'status': 'active', 'silent': true}));
      expect(m.detail, contains("won't call"));
      expect('${m.title} ${m.detail}', isNot(contains('SOS')));
      expect('${m.title} ${m.detail}', isNot(contains('danger')));
    });

    test('says who has seen it, and still that they will not call', () {
      final m = sosStatusMessage(
        alert({
          'status': 'acknowledged',
          'silent': true,
          'acknowledgedBy': 'Admin Reyes',
        }),
      );
      expect(m.detail, contains('Admin Reyes'));
      expect(m.detail, contains("won't call"));
    });
  });

  group('an escalated alert', () {
    test('says emergency services are being contacted, and by whom', () {
      final m = sosStatusMessage(
        alert({
          'status': 'acknowledged',
          'acknowledgedBy': 'Admin Reyes',
          'escalatedBy': 'Admin Reyes',
        }),
      );
      expect(m.title, contains('Emergency services'));
      expect(m.detail, contains('Admin Reyes'));
    });

    test('never promises that anyone is on the way', () {
      final m = sosStatusMessage(
        alert({'status': 'acknowledged', 'escalatedBy': 'Admin Reyes'}),
      );
      expect(
        '${m.title} ${m.detail}'.toLowerCase(),
        isNot(contains('on the way')),
      );
      expect('${m.title} ${m.detail}'.toLowerCase(), isNot(contains('coming')));
    });
  });

  test('the trip keeps both phones and its stage', () {
    final trip = alert({
      'status': 'active',
      'trip': {
        'bookingId': 'b1',
        'driverId': 'd1',
        'driverPhone': '0917 000 0001',
        'passengerId': 'p1',
        'passengerPhone': '0917 000 0002',
        'tripStatus': 'TRIP_IN_PROGRESS',
      },
    }).trip!;
    expect(trip.passengerPhone, '0917 000 0002');
    expect(trip.driverPhone, '0917 000 0001');
    expect(trip.tripStatus, 'TRIP_IN_PROGRESS');
    expect(SosTrip.fromMap(trip.toMap())!.passengerId, 'p1');
  });

  group('the path an open alert records', () {
    const start = LatLng(14.9540, 120.9010);
    LatLng north(double m) =>
        LatLng(start.latitude + m / 111320.0, start.longitude);

    test('starts with the first reading', () {
      expect(extendsSosPath(null, start), isTrue);
    });

    test('adds a point once they have moved ten metres', () {
      expect(extendsSosPath(start, north(12)), isTrue);
    });

    test('a phone lying still adds nothing', () {
      // Heartbeats every 15 s must not fill the record with one spot.
      expect(extendsSosPath(start, north(3)), isFalse);
    });
  });

  test('a last known position older than ten minutes is not sent', () {
    // Several kilometres at tricycle speed — responders would go to the
    // wrong place. Pinned so the rule is not loosened by accident.
    expect(kMaxLastKnownAge, const Duration(minutes: 10));
  });
}

void _noteTests() {
  group('saying what happened, for "Something else"', () {
    test('that category is the only one that asks for words', () {
      expect(SosCategory.other.needsNote, isTrue);
      for (final c in SosCategory.values.where((c) => c != SosCategory.other)) {
        expect(c.needsNote, isFalse, reason: '${c.wire} should not ask');
      }
    });

    test('a couple of words is enough to send', () {
      // The bar is low on purpose: this stands between someone and help.
      expect(worthSendingAsNote('gun'), isTrue);
      expect(worthSendingAsNote('hi'), isTrue);
    });

    test('nothing, a space, or a single letter is not', () {
      expect(worthSendingAsNote(null), isFalse);
      expect(worthSendingAsNote(''), isFalse);
      expect(worthSendingAsNote('   '), isFalse);
      expect(worthSendingAsNote('\n\n'), isFalse);
      expect(worthSendingAsNote('x'), isFalse);
    });

    test('it is trimmed and its whitespace collapsed', () {
      // A wall of newlines must not push the rest of an admin's card away.
      expect(cleanSosNote('  driver   is\n\n drunk \n'), 'driver is drunk');
      expect(cleanSosNote('   '), isNull);
      expect(cleanSosNote(null), isNull);
    });

    test('a very long one is cut, not refused', () {
      final long = cleanSosNote('x' * 500);
      expect(long!.length, kSosNoteMaxLength);
    });

    test('an alert carries it back, cleaned', () {
      final alert = SosAlert.fromMap('a1', {
        'userId': 'u1',
        'status': 'active',
        'severity': 'incident',
        'category': 'other',
        'note': '  someone  followed me   ',
      }, toDate: (_) => null);
      expect(alert.category, SosCategory.other);
      expect(alert.note, 'someone followed me');
    });

    test('an alert without one has none', () {
      final alert = SosAlert.fromMap('a2', {
        'userId': 'u1',
        'status': 'active',
      }, toDate: (_) => null);
      expect(alert.note, isNull);
    });
  });
}
