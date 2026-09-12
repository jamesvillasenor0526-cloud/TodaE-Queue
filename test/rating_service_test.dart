import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/services/rating_service.dart';

({String? bookingId, num rating}) r(String? trip, num stars) =>
    (bookingId: trip, rating: stars);

void main() {
  test('no ratings is not a zero-star driver', () {
    final s = ratingSummary(const []);
    expect(s.count, 0);
    expect(s.average, 0);
  });

  test('the average is to one decimal place', () {
    final s = ratingSummary([r('a', 5), r('b', 4), r('c', 4)]);
    expect(s.count, 3);
    expect(s.average, 4.3);
  });

  test('a trip rated twice counts once, at the average of the two', () {
    // Two trips in the database were rated twice by the old dialog. Which
    // of the pair the database returns first must not change the answer.
    final s = ratingSummary([r('a', 5), r('a', 1), r('b', 5)]);
    expect(s.count, 2);
    expect(s.average, 4); // (3 + 5) / 2
    expect(ratingSummary([r('a', 1), r('a', 5), r('b', 5)]), s);
  });

  test('old ratings with no trip id still count', () {
    final s = ratingSummary([r(null, 4), r('', 2), r('b', 3)]);
    expect(s.count, 3);
    expect(s.average, 3);
  });

  test('one rating is that rating', () {
    final s = ratingSummary([r('a', 5)]);
    expect(s.count, 1);
    expect(s.average, 5);
  });
}
