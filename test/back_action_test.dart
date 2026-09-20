/// What the back button does on the home screens.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/core/models/back_action.dart';

void main() {
  final now = DateTime(2026, 9, 20, 8, 0);

  test('on another tab, back goes to the first tab', () {
    // It used to close the app outright: a driver checking their history
    // lost the app instead of returning to the queue.
    for (final tab in [1, 2, 3]) {
      expect(
        backAction(tabIndex: tab, lastBackAt: null, now: now),
        BackAction.toFirstTab,
      );
    }
  });

  test('on the first tab, the first press only warns', () {
    expect(
      backAction(tabIndex: 0, lastBackAt: null, now: now),
      BackAction.warn,
    );
  });

  test('a second press soon after closes the app', () {
    expect(
      backAction(
        tabIndex: 0,
        lastBackAt: now.subtract(const Duration(seconds: 2)),
        now: now,
      ),
      BackAction.exit,
    );
  });

  test('a press long after the warning starts over', () {
    // Back pressed absent-mindedly minutes later is not confirmation.
    expect(
      backAction(
        tabIndex: 0,
        lastBackAt: now.subtract(const Duration(minutes: 5)),
        now: now,
      ),
      BackAction.warn,
    );
  });

  test('a warning on the first tab does not close it from another tab', () {
    expect(
      backAction(
        tabIndex: 2,
        lastBackAt: now.subtract(const Duration(seconds: 1)),
        now: now,
      ),
      BackAction.toFirstTab,
    );
  });
}
