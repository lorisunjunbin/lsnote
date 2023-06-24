import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lorisun_note/model/GuessItem.dart';

class GuessitemChangeNotifier with ChangeNotifier {
  String _correctAnswer = '';
  List<GuessItem> _guessItems = [];

  List<GuessItem> get guessItems => _guessItems;

  String get correctAnswer => _correctAnswer;

  bool get isMatched =>
      _guessItems.indexWhere((itm) => itm.tryAnswer == _correctAnswer) >= 0;

  Future<void> reset() async {
    _correctAnswer = '';
    _guessItems.clear();
    notifyListeners();
  }

  Future<void> addGuessItem(String tryAnswer) async {
    if (_correctAnswer == null || _correctAnswer.isEmpty) {
      _generateAnswer(tryAnswer);
    }
    if (_isDifferentWithLast(tryAnswer)) {
      int currentStep = _guessItems.length + 1;
      _guessItems.insert(
          0,
          GuessItem(
              tryTime: DateTime.now(),
              tryAnswer: tryAnswer,
              result: _generateResult(tryAnswer),
              step: currentStep,
              duration: _guessItems.length > 0
                  ? Duration(
                      milliseconds: DateTime.now().millisecondsSinceEpoch -
                          _guessItems.last.tryTime!.millisecondsSinceEpoch)
                  : Duration(milliseconds: 0)));
    }

    notifyListeners();
  }

  bool _isDifferentWithLast(tryAnswer) {
    if (guessItems.isEmpty) {
      return true;
    }
    return guessItems[0].tryAnswer != tryAnswer;
  }

  int _randomIntInRange({int min = 0, int max = 9}) {
    return (Random().nextDouble() * (max - min + 1) + min).floor();
  }

  void _generateAnswer(String tryAnswer) {
    do {
      for (int i = 0; i < 4; i++) {
        String nextNumber;
        do {
          nextNumber = _randomIntInRange().toString();
        } while (_correctAnswer.contains(nextNumber));
        _correctAnswer += nextNumber;
      }
      //print('CorrectAnswer: $_correctAnswer');
    } while (tryAnswer == _correctAnswer);
  }

  String _generateResult(String tryAnswer) {
    int aCount = 0, bCount = 0;
    for (int i = 0; i < 4; i++) {
      for (int j = 0; j < 4; j++) {
        if (_correctAnswer[i] == tryAnswer[j]) {
          if (i == j)
            aCount++;
          else
            bCount++;
        }
      }
    }
    return '${aCount}A${bCount}B';
  }
}
