/// Loads the town outline the app serves, once, from the bundled asset.
///
/// The outline is small (a few kilobytes) and never changes at runtime, so it
/// is read on first use and kept. A failure to read it is not fatal: the area
/// stays unusable, and an unusable area means no trip is ever treated as out
/// of town — the app keeps working at town fares.
library;

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import '../models/service_area.dart';

class ServiceAreaService {
  static final ServiceAreaService instance = ServiceAreaService._();
  ServiceAreaService._();

  static const String assetPath = 'assets/baliwag_boundary.json';

  /// Empty until [load] finishes; safe to read at any time.
  ServiceArea area = const ServiceArea(name: 'Baliwag', outline: []);

  Future<void>? _loading;

  /// Reads the outline if it has not been read yet.
  Future<ServiceArea> load() {
    final existing = _loading;
    if (existing != null) return existing.then((_) => area);
    final started = _read();
    _loading = started;
    return started.then((_) => area);
  }

  Future<void> _read() async {
    try {
      final body = await rootBundle.loadString(assetPath);
      area = ServiceArea.fromJson(body);
    } catch (_) {
      // Left unusable on purpose: see the note at the top of the file.
    }
  }

  /// Whether a destination lies outside town, and what that costs, measured
  /// from the terminal the trip starts at.
  ///
  /// Returns [OutOfTown.none] before the outline has loaded.
  OutOfTown check({required LatLng destination, required LatLng terminal}) =>
      outOfTownFor(area: area, destination: destination, terminal: terminal);

  /// For tests: use this outline instead of the bundled one.
  void useForTest(ServiceArea replacement) {
    area = replacement;
    _loading = Future.value();
  }
}
