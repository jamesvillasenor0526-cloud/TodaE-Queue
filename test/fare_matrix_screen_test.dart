/// The Fare Matrix shows the rates in force, and follows a change to them
/// while it is open. It used to print ₱35 and ₱10/km as fixed text.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/models/fare_rates.dart';
import 'package:toda_equeue_plus/core/services/fare_service.dart';
import 'package:toda_equeue_plus/features/passenger/booking/fare_matrix_screen.dart';

void main() {
  final fare = FareService.instance;
  setUp(() => fare.rates = FareRates.defaults);
  tearDown(() => fare.rates = FareRates.defaults);

  testWidgets('shows the rates in force and follows a change', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: FareMatrixScreen()));
    expect(find.text('₱35.00'), findsOneWidget);
    expect(find.text('₱10.00/km'), findsOneWidget);
    expect(find.text('₱55'), findsOneWidget); // 3 km

    // The dashboard saves new rates while the screen is open.
    fare.rates = const FareRates(minimumFare: 40, ratePerKm: 12);
    await tester.pump();

    expect(find.text('₱40.00'), findsOneWidget);
    expect(find.text('₱12.00/km'), findsOneWidget);
    expect(find.text('₱64'), findsOneWidget); // 3 km: 40 + 2 × 12
    expect(find.text('₱35.00'), findsNothing);
  });
}
