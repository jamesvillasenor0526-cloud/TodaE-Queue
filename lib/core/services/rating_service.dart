/// Trip ratings, and the driver's own summary of them.
///
/// A rating is written by the passenger with the trip's own id, so the same
/// trip cannot be rated twice — two trips in the database were, because the
/// old dialog saved the rating, then failed on the next step and was sent
/// again.
///
/// That next step was the passenger writing the driver's average into the
/// *driver's* profile, which the rules refuse: people may only edit their
/// own profile. So every rating ended in "Failed", and no driver's average
/// has ever updated. The driver's own app keeps it in step instead, which
/// it is allowed to do, and the ratings themselves stay the record.
library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// The average (to one decimal) and count of [ratings], counting a trip
/// once: two ratings for one trip are the same trip's, not two opinions.
///
/// Where a trip was rated twice — the old dialog could save a rating and
/// then fail, and be sent again — the trip counts once, at the average of
/// what was left, so the answer does not depend on which the database hands
/// back first.
({double average, int count}) ratingSummary(
  Iterable<({String? bookingId, num rating})> ratings,
) {
  final perTrip = <String, List<num>>{};
  final looseRatings = <num>[];
  for (final r in ratings) {
    final id = r.bookingId;
    if (id == null || id.isEmpty) {
      looseRatings.add(r.rating);
    } else {
      (perTrip[id] ??= []).add(r.rating);
    }
  }
  final all = <num>[
    for (final trip in perTrip.values)
      trip.reduce((a, b) => a + b) / trip.length,
    ...looseRatings,
  ];
  if (all.isEmpty) return (average: 0, count: 0);
  final mean = all.reduce((a, b) => a + b) / all.length;
  return (average: double.parse(mean.toStringAsFixed(1)), count: all.length);
}

class RatingService {
  RatingService._();
  static final RatingService instance = RatingService._();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  ({double average, int count})? _written;

  /// Keeps the signed-in driver's `averageRating` and `totalRatings` in step
  /// with the ratings passengers have left them. Safe to call repeatedly.
  void syncMyAverage() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || _sub != null) return;
    final users = FirebaseFirestore.instance.collection('users');
    _sub = FirebaseFirestore.instance
        .collection('ratings')
        .where('driverId', isEqualTo: uid)
        .snapshots()
        .listen((snap) async {
          final summary = ratingSummary([
            for (final d in snap.docs)
              if (d.data()['rating'] case final num r)
                (bookingId: d.data()['bookingId'] as String?, rating: r),
          ]);
          if (summary == _written || summary.count == 0) return;
          try {
            final current = await users.doc(uid).get();
            final data = current.data();
            if (data != null &&
                (data['averageRating'] as num?)?.toDouble() ==
                    summary.average &&
                (data['totalRatings'] as num?)?.toInt() == summary.count) {
              _written = summary;
              return; // already says this
            }
            await users.doc(uid).update({
              'averageRating': summary.average,
              'totalRatings': summary.count,
            });
            _written = summary;
          } catch (e) {
            debugPrint('Ratings: could not update my average: $e');
          }
        }, onError: (Object e) => debugPrint('Ratings listener stopped: $e'));
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _written = null;
  }
}
