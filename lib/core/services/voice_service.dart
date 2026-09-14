/// Speaks navigation guidance aloud.
///
/// The thin, untestable half of voice guidance: it owns the platform
/// text-to-speech engine and the driver's mute preference, and nothing else.
/// Every decision about *what* to say and *when* lives in
/// [VoiceGuide], which is pure and covered by tests.
///
/// Failing to speak is never treated as an error worth surfacing. A phone
/// with no TTS engine installed, or a driver on a call, should lose the
/// voice and keep the navigation.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VoiceService extends ChangeNotifier {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  static const _prefKey = 'voice_guidance_enabled';

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _enabled = true;

  /// Whether the driver wants to hear guidance. Persisted, because a driver
  /// who muted it yesterday should not be talked at again this morning.
  bool get enabled => _enabled;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
    } catch (_) {
      // Preferences unavailable: fall back to on, which is the setting a
      // driver who has never touched it expects.
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    if (!value) await stop();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {
      // The setting still applies for this drive even if it cannot be saved.
    }
  }

  Future<void> _prepare() async {
    if (_ready) return;
    // en-US rather than the device locale: the road names come back from the
    // router in English, and a Filipino voice reading them is harder to
    // follow than an English one, not easier.
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    // Interrupting a half-spoken instruction with the next one is worse than
    // waiting; the guide already spaces cues out.
    await _tts.awaitSpeakCompletion(true);
    _ready = true;
  }

  /// Readies the engine before anything needs saying.
  ///
  /// The first utterance otherwise carries the cost of starting the
  /// text-to-speech engine — most of a second on a modest phone — and that
  /// second is spent driving towards the turn being announced. Called when
  /// navigation opens, so the first cue is as prompt as the rest.
  Future<void> warmUp() async {
    if (!_enabled) return;
    try {
      await _prepare();
    } catch (e) {
      debugPrint('Voice guidance could not be readied: $e');
    }
  }

  /// Says [line], if voice is on. Silent no-op otherwise.
  Future<void> speak(String line) async {
    if (!_enabled || line.trim().isEmpty) return;
    try {
      await _prepare();
      await _tts.speak(line);
    } catch (e) {
      // No engine, no audio focus, or the platform refused. The driver still
      // has the route on screen.
      debugPrint('Voice guidance unavailable: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing was playing, or the engine is gone. Either way, silence.
    }
  }
}
