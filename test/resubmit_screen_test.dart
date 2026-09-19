/// A rejected driver sees why, and starts from the details they gave.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/features/driver/verification/resubmit_screen.dart';

void main() {
  Future<void> open(WidgetTester tester, Map<String, dynamic> profile) =>
      tester.pumpWidget(MaterialApp(home: ResubmitScreen(profile: profile)));

  testWidgets('shows the reason and the details as they stand', (tester) async {
    await open(tester, {
      'name': 'Juan Dela Cruz',
      'plateNumber': 'ABC-123',
      'bodyNumber': '45',
      'idType': 'voters_id',
      'idNumber': 'V-001',
      'rejectionReason': 'ID photo is blurry',
    });
    expect(find.text('ID photo is blurry'), findsOneWidget);
    expect(find.text('Juan Dela Cruz'), findsOneWidget);
    expect(find.text('ABC-123'), findsOneWidget);
    expect(find.text('45'), findsOneWidget);
    expect(find.text('V-001'), findsOneWidget);
    expect(find.text("Voter's ID"), findsOneWidget);
    expect(find.text('Retake selfie and ID'), findsOneWidget);
  });

  testWidgets('says so when no reason was given', (tester) async {
    await open(tester, {'name': 'Ana'});
    expect(find.textContaining('did not give a reason'), findsOneWidget);
  });

  testWidgets('will not send with a detail missing', (tester) async {
    await open(tester, {'name': 'Ana', 'plateNumber': '', 'bodyNumber': '1', 'idNumber': 'X'});
    await tester.scrollUntilVisible(
      find.text('Send for review'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Send for review'));
    await tester.pump();
    expect(find.text('Enter your plate number'), findsOneWidget);
  });
}
