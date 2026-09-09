/// Copy this file to `api_keys.dart` and paste your key in.
///
/// `api_keys.dart` is gitignored, so your key is never committed. The app
/// builds and runs without it — routing simply falls back to OSRM, which
/// needs no key but has no live traffic and returns no alternatives.
///
/// Get a key free at https://developer.tomtom.com — no credit card. The
/// free tier allows 2,500 routing requests a day.
class ApiKeys {
  const ApiKeys._();

  /// TomTom Routing API key, or empty to stay on OSRM.
  static const String tomTom = '';
}
