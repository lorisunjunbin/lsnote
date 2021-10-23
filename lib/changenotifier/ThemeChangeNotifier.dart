import 'package:flutter/material.dart';

class ThemeChangeNotifier with ChangeNotifier {
  ThemeData _td;

  ThemeData getTheme() => _td;

  Future<void> setTheme(ThemeData themeData) async {
    _td = themeData;
    notifyListeners();
  }
}
