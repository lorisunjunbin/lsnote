class GuessItem {
  final String tryAnswer;
  final String result;
  final DateTime tryTime;
  final int step;
  final Duration duration;

  GuessItem(
      {this.tryAnswer, this.result, this.tryTime, this.step, this.duration});
}
