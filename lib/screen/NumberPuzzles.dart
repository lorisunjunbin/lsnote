import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lorisun_note/screen/NoteLanding.dart';
import '../utils/NavigationHelper.dart';
import 'package:provider/provider.dart';

import '../model/GuessItem.dart';
import '../i18n/SimpleLocalizations.dart';
import '../changenotifier/GuessItemChangeNotifier.dart';
import '../service/AiPrompts.dart';
import '../service/AiService.dart';

class NumberPuzzles extends StatefulWidget {
  static final String routeName = '/NumberPuzzles';

  @override
  _NumberPuzzlesState createState() => _NumberPuzzlesState();
}

class _NumberPuzzlesState extends State<NumberPuzzles> with TickerProviderStateMixin {
  List<String> _digits = ['', '', '', ''];
  int _currentIndex = 0;
  bool _easyMode = false;
  late AnimationController _titleAnimCtrl;

  @override
  void initState() {
    super.initState();
    _titleAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  int _emptyClickCount = 0;
  static const int _resetClickThreshold = 3;

  String _aiHint = '';
  bool _isHintLoading = false;
  String _aiComment = '';
  final List<StreamSubscription> _aiSubs = [];

  void _onDigitTap(String digit) {
    setState(() {
      // Dedup: clear any other slot that already has this digit
      for (int i = 0; i < 4; i++) {
        if (_digits[i] == digit) {
          _digits[i] = '';
        }
      }
      _digits[_currentIndex] = digit;
      // Advance to next empty slot
      for (int i = 1; i <= 4; i++) {
        final next = (_currentIndex + i) % 4;
        if (_digits[next].isEmpty) {
          _currentIndex = next;
          return;
        }
      }
      // All filled, stay at current
    });
  }

  void _onBackspace() {
    setState(() {
      if (_digits[_currentIndex].isNotEmpty) {
        _digits[_currentIndex] = '';
      } else if (_currentIndex > 0) {
        _currentIndex--;
        _digits[_currentIndex] = '';
      }
    });
  }

  void _onSlotTap(int index) {
    setState(() => _currentIndex = index);
  }

  void _requestHint(GuessitemChangeNotifier provider) {
    if (!AiService.instance.isReady || _isHintLoading) return;
    if (AiService.instance.isThinkingModel) return;

    final history = provider.guessItems
        .map((itm) => '${itm.tryAnswer} → ${itm.result}')
        .join('\n');

    setState(() {
      _isHintLoading = true;
      _aiHint = '';
    });

    final buffer = StringBuffer();
    try {
      final sub = AiService.instance
          .completeStream(
        AiPrompts.gameHint(),
        history,
        maxLength: 60,
      )
          .listen(
        (token) {
          buffer.write(token);
          if (mounted) setState(() => _aiHint = buffer.toString());
        },
        onDone: () {
          if (mounted) setState(() => _isHintLoading = false);
        },
        onError: (_) {
          if (mounted) setState(() { _aiHint = ''; _isHintLoading = false; });
        },
      );
      _aiSubs.add(sub);
    } catch (_) {
      if (mounted) setState(() { _aiHint = ''; _isHintLoading = false; });
    }
  }

  void _requestWinComment(GuessitemChangeNotifier provider) {
    if (!AiService.instance.isReady) return;
    if (AiService.instance.isThinkingModel) return;

    final guessCount = provider.guessItems.length;
    final firstTime = provider.guessItems.first.tryTime;
    final lastTime = provider.guessItems.last.tryTime;
    final totalSeconds = (lastTime != null && firstTime != null)
        ? lastTime.difference(firstTime).inSeconds
        : 0;

    final buffer = StringBuffer();
    try {
      final sub = AiService.instance
          .completeStream(
        AiPrompts.gameWin(),
        '$guessCount guesses, ${totalSeconds}s',
        maxLength: 60,
      )
          .listen(
        (token) {
          buffer.write(token);
          if (mounted) setState(() => _aiComment = buffer.toString());
        },
        onError: (_) {},
      );
      _aiSubs.add(sub);
    } catch (_) {}
  }

  void _guess(GuessitemChangeNotifier provider) {
    if (provider.isMatched) {
      provider.reset();
      _reset();
      _clearEmptyClickCount();
    } else if (_validateInput()) {
      provider.addGuessItem(_digits.join());
      _clearEmptyClickCount();
      if (provider.isMatched) {
        _requestWinComment(provider);
      } else {
        _reset();
      }
    } else {
      _handleEmptyGuess(provider);
    }
  }

  void _handleEmptyGuess(GuessitemChangeNotifier provider) {
    setState(() {
      _emptyClickCount++;
      if (_emptyClickCount >= _resetClickThreshold) {
        provider.reset();
        _reset();
        _clearEmptyClickCount();
      }
    });
  }

  void _clearEmptyClickCount() {
    if (_emptyClickCount > 0) {
      setState(() {
        _emptyClickCount = 0;
      });
    }
  }

  Color _getDigitColor(String tryAnswer, int index, GuessitemChangeNotifier provider) {
    if (!_easyMode || provider.correctAnswer.isEmpty) {
      return Theme.of(context).colorScheme.onSurface;
    }
    if (tryAnswer[index] == provider.correctAnswer[index]) {
      return const Color(0xFF66BB6A);
    }
    if (provider.correctAnswer.contains(tryAnswer[index])) {
      return const Color(0xFFFFA726);
    }
    return Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.35);
  }

  List<Widget> _buildGuessList(
      GuessitemChangeNotifier provider, SimpleLocalizations? sl) {
    if (provider.guessItems.isEmpty) {
      return [
        Center(
          child: Text(
            sl?.getText('guessHint') ?? 'Enter 4 digits and press GUESS',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }

    return provider.guessItems.reversed.map((itm) {
      final result = itm.result ?? '';
      final aCount = _extractCount(result, 'A');
      final bCount = _extractCount(result, 'B');
      final tryAnswer = itm.tryAnswer ?? '';

      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: provider.isMatched && provider.guessItems.last == itm
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.zero,
          border: Border.all(
            color: provider.isMatched && provider.guessItems.last == itm
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // Guessed number with per-digit coloring
            Expanded(
              flex: 2,
              child: Row(
                children: List.generate(4, (i) {
                  return Padding(
                    padding: EdgeInsets.only(right: i < 3 ? 6 : 0),
                    child: Text(
                      tryAnswer.length > i ? tryAnswer[i] : '',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: tryAnswer.length > i
                            ? _getDigitColor(tryAnswer, i, provider)
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  );
                }),
              ),
            ),
            // Result display (A and B)
            InkWell(
              onTap: () => _showResultDialog(context, aCount, bCount, sl),
              borderRadius: BorderRadius.zero,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: _getResultColor(provider, itm, context),
                  borderRadius: BorderRadius.zero,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${aCount}A',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${bCount}B',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Timestamp info
            Expanded(
              flex: 2,
              child: Text(
                _buildDescription(provider, sl, itm),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  void _showResultDialog(BuildContext context, int aCount, int bCount, SimpleLocalizations? sl) {
    String _numberToKey(int n) {
      switch (n) {
        case 0: return 'Zero';
        case 1: return 'One';
        case 2: return 'Two';
        case 3: return 'Three';
        case 4: return 'Four';
        case 5: return 'Five';
        case 6: return 'Six';
        case 7: return 'Seven';
        case 8: return 'Eight';
        case 9: return 'Nine';
        case 10: return 'Ten';
        default: return '';
      }
    }

    String _getNumberText(int count) {
      if (count > 10) return count.toString();
      final key = 'guessResult${_numberToKey(count)}';
      return sl?.getText(key) ?? count.toString();
    }

    String aText = _getNumberText(aCount);
    String bText = _getNumberText(bCount);

    String explanation = '''
$aText ${sl?.getText('resultCorrectPosition') ?? 'numbers correct in both position and value'} ($aCount A)
$bText ${sl?.getText('resultCorrectValue') ?? 'numbers correct but in wrong position'} ($bCount B)
''';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.info_outline,
              color: Theme.of(context).colorScheme.primary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              sl?.getText('resultDialogTitle') ?? 'Result Explanation',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          explanation,
          style: TextStyle(
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(sl?.getText('okButton') ?? 'OK'),
          ),
        ],
      ),
    );
  }

  int _extractCount(String result, String char) {
    final idx = result.indexOf(char);
    if (idx > 0) {
      final numStr = result.substring(idx - 1, idx);
      return int.tryParse(numStr) ?? 0;
    }
    return 0;
  }

  Color _getResultColor(GuessitemChangeNotifier provider, GuessItem itm, BuildContext context) {
    if (provider.isMatched && provider.guessItems.last == itm) {
      return Theme.of(context).colorScheme.primary;
    }
    final result = itm.result ?? '';
    final aCount = _extractCount(result, 'A');
    if (aCount == 4) {
      return Theme.of(context).colorScheme.primary;
    } else if (aCount >= 2) {
      return Theme.of(context).colorScheme.secondaryContainer;
    } else {
      return Theme.of(context).colorScheme.surfaceContainerHighest;
    }
  }

  void _reset() {
    setState(() {
      _digits = ['', '', '', ''];
      _currentIndex = 0;
      _aiHint = '';
      _aiComment = '';
    });
  }

  bool _validateInput() {
    return _digits.every((d) => d.isNotEmpty);
  }

  Widget _buildGameTitle(SimpleLocalizations? sl, ThemeData theme,
      GuessitemChangeNotifier guessitemPrvider) {
    if (guessitemPrvider.isMatched) {
      int guessTime = guessitemPrvider.guessItems.length;
      String showText = guessTime < 4
          ? sl?.getText('amazing') ?? 'Amazing!'
          : guessTime < 8
              ? sl?.getText('awesome') ?? 'Awesome!'
              : guessTime < 10
                  ? sl?.getText('wonderful') ?? 'Wonderful!'
                  : sl?.getText('justsoso') ?? 'Keep trying!';
      final spaced = showText.characters.join(' ');
      return AnimatedBuilder(
        animation: _titleAnimCtrl,
        builder: (context, child) {
          return ShaderMask(
            shaderCallback: (bounds) {
              return LinearGradient(
                colors: [
                  const Color(0xFFFF6B6B),
                  const Color(0xFFFFD93D),
                  const Color(0xFF6BCB77),
                  const Color(0xFF4D96FF),
                  const Color(0xFFFF6B6B),
                ],
                stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
                begin: Alignment(-1.0 + 2.0 * _titleAnimCtrl.value, 0),
                end: Alignment(1.0 + 2.0 * _titleAnimCtrl.value, 0),
              ).createShader(bounds);
            },
            child: Text(spaced,
                style: TextStyle(
                  fontSize: 26,
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                )),
          );
        },
      );
    }
    final title = sl?.getText('numberpuzzles') ?? 'Number Puzzles';
    final spaced = title.characters.join(' ');
    return AnimatedBuilder(
      animation: _titleAnimCtrl,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.tertiary,
                theme.colorScheme.secondary,
                theme.colorScheme.primary,
              ],
              stops: const [0.0, 0.33, 0.66, 1.0],
              begin: Alignment(-1.0 + 2.0 * _titleAnimCtrl.value, 0),
              end: Alignment(1.0 + 2.0 * _titleAnimCtrl.value, 0),
            ).createShader(bounds);
          },
          child: Text(spaced,
              style: const TextStyle(
                fontSize: 26.0,
                color: Colors.white,
                fontWeight: FontWeight.w900,
                letterSpacing: 4,
              )),
        );
      },
    );
  }

  String _buildDescription(GuessitemChangeNotifier provider,
          SimpleLocalizations? sl, GuessItem itm) {
    final timeStr = itm.tryTime?.toString().substring(11, 19) ?? '';
    if (itm.step == 1) {
      return timeStr;
    } else {
      final seconds = itm.duration?.inSeconds ?? 0;
      return '#${itm.step}·${seconds}s·$timeStr';
    }
  }

  Widget _buildDigitSlot(int index, ColorScheme colorScheme) {
    final isActive = _currentIndex == index;
    final hasValue = _digits[index].isNotEmpty;
    return GestureDetector(
      onTap: () => _onSlotTap(index),
      child: Container(
        height: 60,
        decoration: BoxDecoration(
          color: isActive
              ? colorScheme.surface
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isActive
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.2),
            width: isActive ? 2 : 1,
          ),
          boxShadow: isActive
              ? [BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.15),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                )]
              : [BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                )],
        ),
        alignment: Alignment.center,
        child: Text(
          _digits[index],
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.bold,
            color: hasValue ? colorScheme.onSurface : Colors.transparent,
          ),
        ),
      ),
    );
  }

  Widget _buildNumberPad(ColorScheme colorScheme, GuessitemChangeNotifier provider, SimpleLocalizations? sl) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 40),
      color: colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(5, (i) => _buildPadKey('${i + 1}', colorScheme)),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ...List.generate(4, (i) => _buildPadKey('${i + 6}', colorScheme)),
              _buildPadKey('0', colorScheme),
              _buildBackspaceKey(colorScheme),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Switch(
                value: _easyMode,
                onChanged: (v) => setState(() => _easyMode = v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              Text(
                'Easy',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: () => _guess(provider),
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: Text(
                      provider.isMatched
                          ? (sl?.getText('start') ?? 'Start')
                          : (sl?.getText('guess') ?? 'GUESS'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
              if (AiService.instance.isReady &&
                  !AiService.instance.isThinkingModel &&
                  !provider.isMatched &&
                  provider.guessItems.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  icon: _isHintLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lightbulb_outline),
                  onPressed:
                      _isHintLoading ? null : () => _requestHint(provider),
                  tooltip: sl?.getText('aiHint') ?? 'Hint',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPadKey(String digit, ColorScheme colorScheme) {
    final isUsed = _digits.contains(digit);
    return GestureDetector(
      onTap: () => _onDigitTap(digit),
      child: Container(
        width: 54,
        height: 50,
        decoration: BoxDecoration(
          color: isUsed
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          digit,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: isUsed
                ? colorScheme.onPrimaryContainer
                : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _buildBackspaceKey(ColorScheme colorScheme) {
    return GestureDetector(
      onTap: _onBackspace,
      child: Container(
        width: 54,
        height: 50,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.backspace_outlined,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  String _getResetHintText(SimpleLocalizations? sl, int clickCount) {
    final remaining = _resetClickThreshold - clickCount;
    if (sl?.locale.languageCode == 'zh') {
      return '再点击 $remaining 次重新开始';
    }
    return 'Tap $remaining more time${remaining > 1 ? 's' : ''} to restart';
  }

  void _back2Home(BuildContext context) {
    Navigator.popAndPushNamed(context, NoteLanding.routeName);
  }

  @override
  Widget build(context) {
    final sl = SimpleLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final guessitemProvider = Provider.of<GuessitemChangeNotifier>(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: NavigationHelper.createPopCallback(
        context,
        NoteLanding.routeName,
      ),
      child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _back2Home(context),
        ),
        elevation: 0,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Game title
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: _buildGameTitle(sl, theme, guessitemProvider),
            ),
          ),
          // AI hint display
          if (_aiHint.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(Icons.lightbulb, size: 16, color: colorScheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_aiHint,
                        style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onTertiaryContainer)),
                  ),
                  GestureDetector(
                    onTap: () => setState(() => _aiHint = ''),
                    child: Icon(Icons.close,
                        size: 16, color: colorScheme.onTertiaryContainer),
                  ),
                ],
              ),
            ),
          // Input slots
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerLow,
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(child: _buildDigitSlot(0, colorScheme)),
                const SizedBox(width: 10),
                Expanded(child: _buildDigitSlot(1, colorScheme)),
                const SizedBox(width: 10),
                Expanded(child: _buildDigitSlot(2, colorScheme)),
                const SizedBox(width: 10),
                Expanded(child: _buildDigitSlot(3, colorScheme)),
              ],
            ),
          ),
          // AI win comment
          if (guessitemProvider.isMatched && _aiComment.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(_aiComment,
                  style: TextStyle(
                      fontSize: 13, color: colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center),
            ),
          // Guess history list
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 12),
              children: _buildGuessList(guessitemProvider, sl),
            ),
          ),
          // Reset hint
          if (_emptyClickCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: colorScheme.surfaceContainerLow,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.info_outline, size: 16, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    _getResetHintText(sl, _emptyClickCount),
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          // Number pad at bottom
          _buildNumberPad(colorScheme, guessitemProvider, sl),
        ],
      )),
    );
  }

  @override
  void dispose() {
    _titleAnimCtrl.dispose();
    for (final sub in _aiSubs) {
      sub.cancel();
    }
    super.dispose();
  }
}
