/// The app's one GPS stream, shared.
///
/// Every part of the app that follows the phone's position — terminal
/// check-in, navigation, SOS, the passenger's own dot, road reports — asks
/// here instead of starting its own stream, saying what it needs. The
/// location plugin can only run one stream and silently ignores the
/// settings of every request after the first (see location_need.dart), so
/// separate requests were not separate at all: whoever asked first set the
/// pace for everyone, and navigation was held to a reading every 5 s.
///
/// The stream runs at the finest need currently open and is restarted when
/// that changes — faster the moment navigation opens, slower again when it
/// closes — and stops when nobody needs it. Callers still ask for location
/// permission themselves before watching.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/location_need.dart';

class LocationHub {
  LocationHub._();
  static final LocationHub instance = LocationHub._();

  final Map<Object, LocationNeed> _needs = {};
  final StreamController<Position> _fixes =
      StreamController<Position>.broadcast();
  StreamSubscription<Position>? _source;
  LocationNeed? _running;

  /// Changes are applied one at a time, in order, so a restart is never
  /// interleaved with another.
  Future<void> _switching = Future.value();

  /// What the stream is running at now, or null when stopped. For tests
  /// and debugging.
  LocationNeed? get running => _running;

  /// Readings for as long as the returned stream is listened to, at least
  /// as often and as finely as [need] asks — possibly more often, when
  /// another part of the app needs more.
  Stream<Position> watch(LocationNeed need) {
    final token = Object();
    StreamSubscription<Position>? relay;
    late final StreamController<Position> out;
    out = StreamController<Position>(
      onListen: () {
        relay = _fixes.stream.listen(out.add, onError: out.addError);
        _needs[token] = need;
        _reconfigure();
      },
      onCancel: () async {
        _needs.remove(token);
        await relay?.cancel();
        _reconfigure();
      },
    );
    return out.stream;
  }

  void _reconfigure() {
    _switching = _switching
        .then((_) async {
          final want = _needs.isEmpty
              ? null
              : LocationNeed.merge(_needs.values);
          if (want == _running && (want == null || _source != null)) return;
          // This is the plugin stream's only listener, so cancelling it makes
          // the plugin forget its settings and take the new ones.
          await _source?.cancel();
          _source = null;
          _running = want;
          if (want == null) return;
          _source = Geolocator.getPositionStream(
            locationSettings: _settings(want),
          ).listen(_fixes.add, onError: _fixes.addError);
        })
        .catchError((Object e) {
          debugPrint('Location stream: $e');
        });
  }

  static LocationSettings _settings(LocationNeed n) =>
      defaultTargetPlatform == TargetPlatform.android
      // Android needs the interval asked for, or it delivers a reading only
      // every 5 s whatever else is set.
      ? AndroidSettings(
          accuracy: n.accuracy,
          distanceFilter: n.distanceFilter,
          intervalDuration: n.interval,
        )
      : LocationSettings(
          accuracy: n.accuracy,
          distanceFilter: n.distanceFilter,
        );
}
