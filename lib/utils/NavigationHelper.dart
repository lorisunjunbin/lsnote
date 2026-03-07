import 'package:flutter/material.dart';

/// Helper for consistent navigation patterns across screens.
class NavigationHelper {
  /// Navigate to a route by replacing the current one.
  /// Use this for back navigation to avoid stack buildup.
  static void replaceTo(BuildContext context, String routeName) {
    Navigator.popAndPushNamed(context, routeName);
  }

  /// Create a PopScope callback for screens that should navigate
  /// to a specific route when the system back button is pressed.
  static void Function(bool, dynamic) createPopCallback(
    BuildContext context,
    String targetRouteName,
  ) {
    return (didPop, result) {
      if (!didPop) {
        replaceTo(context, targetRouteName);
      }
    };
  }
}

