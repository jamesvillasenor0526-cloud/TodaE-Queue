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
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/fare_rates.dart';
import 'fare_service.dart';

class FareSettingsService {
  static final FareSettingsService instance = FareSettingsService._();
  FareSettingsService._();

  static const String _prefKey = 'fare_rates';

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('settings').doc('fare');

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  /// Applies what was last saved on this phone, then follows the document.
  ///
  /// Called at startup. Never throws: a fare has to be quotable even when
  /// everything about this fails.
  Future<void> start() async {
    await _loadCached();
    _sub?.cancel();
    _sub = _doc.snapshots().listen(
      (snap) {
        if (!snap.exists) return; // nothing saved yet: defaults stand
        final rates = FareRates.fromMap(snap.data());
        _apply(rates);
        unawaited(_cache(rates));
      },
      onError: (Object e) {
        // Offline, or rules refused the read. Whatever was cached stands.
        debugPrint('Fare rates: could not follow the setting: $e');
      },
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

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
