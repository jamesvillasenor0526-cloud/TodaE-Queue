/// What a fare is worked out from when the router cannot be reached.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/services/fare_service.dart';
import 'package:toda_equeue_plus/core/services/routing_service.dart';

void main() {
  test('a fallback distance allows for streets winding', () {
    // A straight line through the blocks undercharged every ride the
    // router could not reach.
    expect(straightLineRoadEstimate(2), closeTo(2.6, 0.001));
    expect(straightLineRoadEstimate(0), 0);
  });

  test('the estimate never comes out shorter than the straight line', () {
    for (final km in [0.2, 1.0, 3.7, 12.4]) {
      expect(straightLineRoadEstimate(km), greaterThanOrEqualTo(km));
    }
  });

  test('the fare follows the distance used', () {
    final fare = FareService.instance;
    // 2 km straight line: ₱35 + ₱10 for the second km...
    expect(fare.calculateFareFromDistance(2), 45);
    // ...against ₱35 + 2 × ₱10 once the winding is allowed for (2.6 km).
    expect(fare.calculateFareFromDistance(straightLineRoadEstimate(2)), 55);
  });

  test('short rides stay at the minimum fare', () {
    expect(FareService.instance.calculateFareFromDistance(0.5), 35);
    expect(
      FareService.instance.calculateFareFromDistance(
        straightLineRoadEstimate(0.5),
      ),
      35,
    );
  });
}
