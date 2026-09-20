/// Keeps the fare rates on this phone up to date.
///
/// Read from `settings/fare`, which only a super admin may write (see the
/// security rules), and kept on the phone so a driver with no signal still
/// quotes the fare that was in force the last time they had one. Order of
/// preference: the live document, then what was last saved here, then the
/// built-in defaults. A fare is always quotable.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fare_rates.dart';
import 'notification_service.dart';
import 'fare_service.dart';

class FareSettingsService {
  static final FareSettingsService instance = FareSettingsService._();
  FareSettingsService._();

  static const String _prefKey = 'fare_rates';

  /// The last change to the rates, for whatever wants to tell the person
  /// about it — a passenger who books at the old price and is charged the
  /// new one has every right to feel cheated, so the app says so instead.
  /// Cleared once shown.
  final ValueNotifier<String?> announcement = ValueNotifier(null);

  /// Nothing is announced for the first rates a phone loads: that is not a
  /// change, it is simply what fares cost.
  bool _loaded = false;

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('settings').doc('fare');

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;
  StreamSubscription<User?>? _authSub;

  /// Applies what was last saved on this phone, then follows the document
  /// for as long as someone is signed in.
  ///
  /// Called at startup. Never throws: a fare has to be quotable even when
  /// everything about this fails.
  ///
  /// Following sign-in rather than starting once matters. Only signed-in
  /// users may read the setting, and this runs before anyone is: on a fresh
  /// install, or whenever the sign-in had not been restored yet, the first
  /// read was refused, the listener stopped for good, and that phone went
  /// on quoting the old rates for the rest of the session however often the
  /// dashboard changed them.
  Future<void> start() async {
    await _loadCached();
    await _authSub?.cancel();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        _unfollow();
      } else {
        _follow();
      }
    });
  }

  void _follow() {
    _unfollow();
    _sub = _doc.snapshots().listen(
      (snap) {
        if (!snap.exists) return; // nothing saved yet: defaults stand
        final rates = FareRates.fromMap(snap.data());
        final before = FareService.instance.rates;
        _apply(rates);
        unawaited(_cache(rates));
        if (!_loaded) {
          _loaded = true;
          return;
        }
        final what = fareChangeSummary(before, rates);
        if (what.isEmpty) return; // the same numbers, saved again
        announcement.value = what;
        unawaited(
          NotificationService.instance.showNotification(
            title: 'Fares have changed',
            body: '$what. The new fare applies to your next booking.',
          ),
        );
      },
      onError: (Object e) {
        // Offline, or rules refused the read. Whatever was cached stands;
        // the next sign-in follows it again.
        debugPrint('Fare rates: could not follow the setting: $e');
      },
    );
  }

  void _unfollow() {
    _sub?.cancel();
    _sub = null;
  }

  Future<void> stop() async {
    await _authSub?.cancel();
    _authSub = null;
    _unfollow();
  }

  /// Marks the last change as told, so it is not shown twice.
  void announced() => announcement.value = null;

  void _apply(FareRates rates) {
    // A document that somehow holds nonsense is ignored rather than used:
    // fromMap has already replaced any bad field, so this only guards a
    // wholly unusable result.
    if (!rates.isUsable) return;
    FareService.instance.rates = rates;
  }

  Future<void> _loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKey);
      if (raw == null) return;
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        _apply(FareRates.fromMap(decoded));
      }
    } catch (e) {
      debugPrint('Fare rates: no usable cached rates ($e)');
    }
  }

  Future<void> _cache(FareRates rates) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, json.encode(rates.toMap()));
    } catch (e) {
      // The rates still apply for this run; they are simply not kept.
      debugPrint('Fare rates: could not save them for next time ($e)');
    }
  }
}
