import 'package:flutter/material.dart';

class SwitcherChangeNotifier with ChangeNotifier {
  bool _hiddeDone = true;

  bool isHiddenDone() => _hiddeDone;

  Future<void> setHiddenDone(bool hidde) async {
    _hiddeDone = hidde;
    notifyListeners();
  }
}
