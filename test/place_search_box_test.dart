/// Tests for the search box on the pick-up and destination maps.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:toda_equeue_plus/core/models/place_search.dart';
import 'package:toda_equeue_plus/features/shared/map/place_search_box.dart';

const _market = PlaceHit(
  name: 'Baliwag Public Market',
  where: 'Poblacion, Baliwag',
  at: LatLng(14.9526801, 120.9013686),
);

/// A stand-in for the map's search, recording what it was asked.
class _Searches {
  final List<String> asked = [];
  List<PlaceHit> answer = const [_market];

  Future<List<PlaceHit>> call(String query, LatLng near) async {
    asked.add(query);
    return answer;
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Searches searches, {
  void Function(PlaceHit)? onPicked,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlaceSearchBox(
          near: const LatLng(14.954, 120.901),
          onPicked: onPicked ?? (_) {},
          search: searches.call,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a couple of letters are not searched for', (tester) async {
    final searches = _Searches();
    await _pump(tester, searches);
    await tester.enterText(find.byType(TextField), 'ba');
    await tester.pump(const Duration(seconds: 2));
    expect(searches.asked, isEmpty);
  });

  testWidgets('searching waits for a pause in typing', (tester) async {
    final searches = _Searches();
    await _pump(tester, searches);
    await tester.enterText(find.byType(TextField), 'bal');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), 'baliw');
    await tester.pump(const Duration(milliseconds: 200));
    expect(searches.asked, isEmpty, reason: 'still typing');
    await tester.pump(kSearchPause);
    await tester.pumpAndSettle();
    // One search, for what was actually typed.
    expect(searches.asked, ['baliw']);
  });

  testWidgets('a found place is listed and can be picked', (tester) async {
    final searches = _Searches();
    PlaceHit? picked;
    await _pump(tester, searches, onPicked: (p) => picked = p);
    await tester.enterText(find.byType(TextField), 'market');
    await tester.pump(kSearchPause);
    await tester.pumpAndSettle();

    expect(find.text('Baliwag Public Market'), findsOneWidget);
    expect(find.text('Poblacion, Baliwag'), findsOneWidget);

    await tester.tap(find.text('Baliwag Public Market'));
    await tester.pumpAndSettle();
    expect(picked, _market);
    // The list closes and the box is empty, ready for the next search.
    expect(find.text('Baliwag Public Market'), findsNothing);
  });

  testWidgets('finding nothing says so, and suggests tapping the map', (
    tester,
  ) async {
    final searches = _Searches()..answer = const [];
    await _pump(tester, searches);
    await tester.enterText(find.byType(TextField), 'nowhere at all');
    await tester.pump(kSearchPause);
    await tester.pumpAndSettle();
    expect(find.textContaining('No places found'), findsOneWidget);
  });

  testWidgets('clearing the box clears the results', (tester) async {
    final searches = _Searches();
    await _pump(tester, searches);
    await tester.enterText(find.byType(TextField), 'market');
    await tester.pump(kSearchPause);
    await tester.pumpAndSettle();
    expect(find.text('Baliwag Public Market'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Baliwag Public Market'), findsNothing);
    expect(find.textContaining('No places found'), findsNothing);
  });
}
