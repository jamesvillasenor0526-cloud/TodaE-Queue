/// What the Android back button should do on a screen with tabs.
///
/// The home screens ignored it entirely: on the first tab nothing happened
/// at all, and on any other tab the app closed outright — a driver checking
/// their history lost the app instead of returning to the queue.
///
/// Pure, so the awkward part — "press back again to exit" — is tested
/// without a device.
library;

enum BackAction {
  /// Not on the first tab: back goes there, as it does in most apps.
  toFirstTab,

  /// On the first tab, and the first press: say that another closes it.
  warn,

  /// A second press soon after the warning: close the app.
  exit,
}

/// How long a warning counts for. Long enough to read, short enough that a
/// back press minutes later is not treated as confirmation.
const Duration kBackAgainWindow = Duration(seconds: 3);

/// What a back press means, given which [tabIndex] is showing and when back
/// was last pressed.
BackAction backAction({
  required int tabIndex,
  required DateTime? lastBackAt,
  required DateTime now,
  Duration window = kBackAgainWindow,
}) {
  if (tabIndex != 0) return BackAction.toFirstTab;
  if (lastBackAt != null && now.difference(lastBackAt) <= window) {
    return BackAction.exit;
  }
  return BackAction.warn;
}
