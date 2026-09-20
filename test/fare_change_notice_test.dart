/// The in-app notice that fares changed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/services/fare_settings_service.dart';
import 'package:toda_equeue_plus/widgets/fare_change_notice.dart';

void main() {
  final fares = FareSettingsService.instance;
  tearDown(fares.announced);

  Future<void> open(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: FareChangeNotice())),
  );

  testWidgets('nothing is shown until the rates change', (tester) async {
    fares.announced();
    await open(tester);
    expect(find.text('Fares have changed'), findsNothing);
  });

  testWidgets('says what changed, and goes when dismissed', (tester) async {
    await open(tester);
    fares.announcement.value = 'base fare ₱35 → ₱40';
    await tester.pump();

    expect(find.text('Fares have changed'), findsOneWidget);
    expect(
      find.textContaining('base fare ₱35 → ₱40'),
      findsOneWidget,
      reason: 'the person can see what moved, not just that something did',
    );
    expect(find.textContaining('next booking'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('Fares have changed'), findsNothing);
  });
}
