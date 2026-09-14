/// Decides what a driver should be told aloud, and when.
///
/// Deliberately pure: no plugin, no audio, no clock of its own. It is handed
/// the state of the drive and returns the sentence to speak, or null. Every
/// rule about repetition, priority and silence is therefore testable without
/// a device, which matters because the failure mode of voice guidance is not
/// a crash — it is a phone that will not stop talking at someone driving.
///
/// It never decides anything about the trip. Speaking is an output of the
/// navigation state, never an input to it.
library;

import 'road_report.dart';
import 'navigation_state.dart';

/// Far enough out that a driver can still change lane or slow down.
const double kPrepareMeters = 300;

/// Close enough that "turn left" means now, not soon.
const double kActMeters = 60;

/// How long before the turn each cue should land, at the speed being
/// driven. Distance alone is not enough: 60 m is seven seconds' warning for
/// a tricycle and three and a half for a car on the highway, and the second
/// is too late to act on. Whichever is the greater of the fixed distance
/// and the speed-based one wins, so slow traffic keeps the old behaviour.
const Duration kActLead = Duration(seconds: 8);
const Duration kPrepareLead = Duration(seconds: 35);

/// Added to every lead: a phone does not start speaking the instant it is
/// asked. The engine takes a moment to begin, and the sentence itself takes
/// two or three seconds to say — all of it time the driver is still
/// travelling towards the turn.
const Duration kSpeechLatency = Duration(milliseconds: 2500);

/// The distance at which a cue should be spoken, given the speed.
double cueDistance({
  required double atLeastMeters,
  required Duration lead,
  required double speedMetersPerSecond,
}) {
  final speed = speedMetersPerSecond.isFinite && speedMetersPerSecond > 0
      ? speedMetersPerSecond
      : 0.0;
  final seconds =
      (lead + kSpeechLatency).inMilliseconds / Duration.millisecondsPerSecond;
  final travelled = speed * seconds;
  return travelled > atLeastMeters ? travelled : atLeastMeters;
}

/// A manoeuvre closer than this when first seen gets one announcement, not
/// two. Two cues a second apart on a short link is noise, not guidance.
const double kSingleCueMeters = 120;

/// Nothing is spoken within this of the last utterance, whatever its
/// priority, so cues never talk over each other.
const Duration kMinSpeechGap = Duration(seconds: 5);

/// Reported conditions are called out once each, and only this close.
const double kIncidentWarningMeters = 500;

class VoiceGuide {
  /// Manoeuvres already announced at each range, by [UpcomingTurn.key].
  final Set<String> _prepared = {};
  final Set<String> _acted = {};

  /// Conditions already called out, so a report the driver is crawling
  /// past is not repeated on every GPS fix.
  final Set<String> _warned = {};

  /// Reroutes are announced by reason, not by count — three consecutive
  /// "avoiding reported delays" is one piece of information.
  RerouteReason _lastReroute = RerouteReason.none;

  DateTime? _lastSpokeAt;

  /// Forgets what has been said. Used when a leg changes — arriving at the
  /// pickup and setting off for the destination is a new drive, and the
  /// turns from the last one should be sayable again.
  void reset() {
    _prepared.clear();
    _acted.clear();
    _warned.clear();
    _lastReroute = RerouteReason.none;
    _lastSpokeAt = null;
  }

  /// The next thing to say, or null for silence.
  ///
  /// Silence is the common answer and the correct one: this is called on
  /// every GPS fix.
  String? update({
    required UpcomingTurn? turn,
    required DateTime now,
    RerouteReason reroute = RerouteReason.none,
    List<Incident> ahead = const [],
    double speedMetersPerSecond = 0,
  }) {
    final cue = _choose(
      turn: turn,
      reroute: reroute,
      ahead: ahead,
      now: now,
      speed: speedMetersPerSecond,
    );
    if (cue == null) return null;

    // The gap keeps cues from talking over each other — but not at the cost
    // of the one that matters. "Turn left" held back for a second because
    // something was said four seconds ago arrives after the junction.
    final last = _lastSpokeAt;
    if (!cue.urgent && last != null && now.difference(last) < kMinSpeechGap) {
      return null;
    }
    _lastSpokeAt = now;
    return cue.line;
  }

  /// Priority order: why the route changed, then the manoeuvre at hand, then
  /// the one coming, then conditions. A driver mid-turn does not need to
  /// hear about traffic half a kilometre away.
  ({String line, bool urgent})? _choose({
    required UpcomingTurn? turn,
    required RerouteReason reroute,
    required List<Incident> ahead,
    required DateTime now,
    required double speed,
  }) {
    if (reroute != RerouteReason.none && reroute != _lastReroute) {
      _lastReroute = reroute;
      final line = switch (reroute) {
        // Not "closed": this also fires for a confirmed accident or a
        // fallen tree, and telling a driver the road is shut when it has a
        // crash on it is a small lie they will notice.
        RerouteReason.roadBlocked => 'Road blocked ahead. Taking a new route.',
        RerouteReason.fasterRoute => 'Taking a faster route.',
        RerouteReason.offRoute => 'Recalculating.',
        RerouteReason.none => null,
      };
      if (line != null) return (line: line, urgent: true);
    }
    if (reroute == RerouteReason.none) _lastReroute = RerouteReason.none;

    if (turn != null) {
      final key = turn.key;
      // How far out each cue belongs at this speed, never nearer than the
      // fixed distances.
      final act = cueDistance(
        atLeastMeters: kActMeters,
        lead: kActLead,
        speedMetersPerSecond: speed,
      );
      final prepare = cueDistance(
        atLeastMeters: kPrepareMeters,
        lead: kPrepareLead,
        speedMetersPerSecond: speed,
      );

      if (turn.metersAway <= act) {
        if (_acted.add(key)) {
          // A manoeuvre reached without ever being prepared for was already
          // close when it appeared; mark it so nothing announces it late.
          _prepared.add(key);
          // The cue a driver has to act on: never held back for the gap.
          return (line: _spoken(turn.step), urgent: true);
        }
      } else if (turn.metersAway <= prepare) {
        if (!_acted.contains(key) && _prepared.add(key)) {
          // Too close to be worth two separate cues: say it once, plainly,
          // and let the act cue stay silent.
          if (turn.metersAway <= kSingleCueMeters) {
            _acted.add(key);
            return (line: _spoken(turn.step), urgent: true);
          }
          return (
            line:
                'In ${spokenDistance(turn.metersAway)}, '
                '${_lowerFirst(_spoken(turn.step))}',
            urgent: false,
          );
        }
      }
    }

    for (final incident in ahead) {
      final key = _incidentKey(incident);
      if (_warned.contains(key)) continue;
      // Unverified single reports are not worth interrupting a driver for;
      // they are on the map, and the map is enough for a maybe.
      if (incident.statusAt(now) == IncidentStatus.reported) continue;
      _warned.add(key);
      return (line: '${incident.type.label} reported ahead.', urgent: false);
    }

    return null;
  }

  /// Prefers the router's own phrasing, which names roads correctly, but
  /// strips the trailing full stop so cues read as one sentence.
  String _spoken(NavStep step) {
    final text = step.instruction.trim();
    return text.endsWith('.') ? text : '$text.';
  }

  String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  /// Groups by type and a ~100 m cell, since [Incident] has no id of its own
  /// and is rebuilt from the report stream on every tick.
  String _incidentKey(Incident i) =>
      '${i.type.name}@${i.location.latitude.toStringAsFixed(3)},'
      '${i.location.longitude.toStringAsFixed(3)}';
}

/// A distance a person would say out loud.
///
/// "In 287 meters" is how a machine talks; rounding is what makes it sound
/// like an instruction rather than a readout.
String spokenDistance(double meters) {
  if (meters >= 1000) {
    final km = meters / 1000;
    final rounded = (km * 2).round() / 2;
    return rounded == rounded.roundToDouble()
        ? '${rounded.round()} kilometers'
        : '$rounded kilometers';
  }
  if (meters >= 500) return '${(meters / 100).round() * 100} meters';
  // Never rounds down to "in 0 meters", which would be nonsense spoken aloud.
  final nearest = (meters / 50).round() * 50;
  return '${nearest < 50 ? 50 : nearest} meters';
}
