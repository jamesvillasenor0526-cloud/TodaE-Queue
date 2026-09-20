/// Makes the Android back button behave on a screen with tabs.
///
/// Back returns to the first tab, and on the first tab it asks for a second
/// press before closing the app — so nobody loses the app by reaching for
/// back out of habit.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models/back_action.dart';

class HomeBackScope extends StatefulWidget {
  const HomeBackScope({
    super.key,
    required this.tabIndex,
    required this.onFirstTab,
    required this.child,
  });

  /// Which tab is showing.
  final int tabIndex;

  /// Called to move back to the first tab.
  final VoidCallback onFirstTab;

  final Widget child;

  @override
  State<HomeBackScope> createState() => _HomeBackScopeState();
}

class _HomeBackScopeState extends State<HomeBackScope> {
  DateTime? _lastBack;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Never popped by the system: this is the root screen, and what back
      // should do here depends on which tab is showing.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final action = backAction(
          tabIndex: widget.tabIndex,
          lastBackAt: _lastBack,
          now: DateTime.now(),
        );
        switch (action) {
          case BackAction.toFirstTab:
            widget.onFirstTab();
          case BackAction.warn:
            _lastBack = DateTime.now();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Press back again to close the app'),
                duration: kBackAgainWindow,
              ),
            );
          case BackAction.exit:
            SystemNavigator.pop();
        }
      },
      child: widget.child,
    );
  }
}
