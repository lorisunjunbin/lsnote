import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lorisun_note/screen/NoteLanding.dart';
import 'package:provider/provider.dart';

import '../model/GuessItem.dart';
import '../i18n/SimpleLocalizations.dart';
import '../changenotifier/GuessItemChangeNotifier.dart';

class NumberPuzzles extends StatefulWidget {
  static final String routeName = '/NumberPuzzles';

  @override
  _NumberPuzzlesState createState() => _NumberPuzzlesState();
}

class _NumberPuzzlesState extends State<NumberPuzzles> {
  final _ctlrs = [
    TextEditingController(),
    TextEditingController(),
    TextEditingController(),
    TextEditingController()
  ];

  final _focusNodes = [FocusNode(), FocusNode(), FocusNode(), FocusNode()];

  void _guess(GuessitemChangeNotifier provider) {
    if (provider.isMatched) {
      provider.reset();
      _reset();
    } else if (_validateInput()) {
      provider.addGuessItem(_ctlrs.map((ctl) => ctl.text).toList().join());
      if (!provider.isMatched) {
        _reset();
      }
    }
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
      // 解析结果，例如 "0A2B" 表示 0个位置正确，2个数字正确但位置错误
      final result = itm.result ?? '';
      final aCount = _extractCount(result, 'A');
      final bCount = _extractCount(result, 'B');

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
            // 猜测的数字
            Expanded(
              flex: 2,
              child: Text(
                itm.tryAnswer ?? '',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 4,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            // 结果显示 (A和B)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _getResultColor(provider, itm, context),
                borderRadius: BorderRadius.zero,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (aCount > 0)
                    Text(
                      '${aCount}A',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  if (aCount > 0 && bCount > 0) const SizedBox(width: 8),
                  if (bCount > 0)
                    Text(
                      '${bCount}B',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  if (aCount == 0 && bCount == 0)
                    Text(
                      '0A0B',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // 描述信息
            Expanded(
              flex: 3,
              child: Text(
                _buildDescription(provider, sl, itm),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }).toList();
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
    _ctlrs.forEach((ctr) => ctr.text = '');
    _focusNodes[0].requestFocus();
  }

  bool _validateInput() {
    return _ctlrs.indexWhere((ctl) => ctl.text.isEmpty) == -1;
  }

  void _onChange(int c, String v) {
    _ctlrs.forEach((ctl) {
      if (ctl.text == v) {
        ctl.text = '';
      }
    });
    _ctlrs[c].text = v;
    if (_ctlrs[c].text.isNotEmpty) {
      if (c < 3)
        _focusNodes[c + 1].requestFocus();
      else
        _focusNodes[0].requestFocus();
    }
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
      return Text(showText,
          style: TextStyle(
            fontSize: 30 - guessTime > 10 ? (30 - guessTime) * 1.0 : 10.0,
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ));
    }
    return Text(sl?.getText('numberpuzzles') ?? 'Number Puzzles',
        style: TextStyle(
            fontSize: 21.0,
            color: theme.colorScheme.onSurface,
            fontWeight: FontWeight.w800));
  }

  String _buildDescription(GuessitemChangeNotifier provider,
          SimpleLocalizations? sl, GuessItem itm) =>
      itm.step == 1
          ? '${sl?.getText('start') ?? 'Start'} <${itm.tryTime?.toString().substring(0, 19)}>'
          : '${sl?.getText('take') ?? 'Take'} ${itm.step} ${sl?.getText('step') ?? 'steps'} ${sl?.getText('in') ?? 'in'} ${itm.duration?.inSeconds.toString()}${sl?.getText('second') ?? 's'} <${itm.tryTime?.toString().substring(11, 19)}>';

  Widget _buildNumberInput(ThemeData theme, TextEditingController ctr,
      FocusNode fn, ValueChanged<String> handler) {
    final colorScheme = theme.colorScheme;
    return Expanded(
      child: TextFormField(
        autofocus: true,
        focusNode: fn,
        controller: ctr,
        onChanged: handler,
        onTap: () => ctr.text = '',
        maxLength: 1,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 28.0,
          color: colorScheme.onSurface,
        ),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          counterText: "",
          contentPadding: EdgeInsets.zero,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.zero,
            borderSide: BorderSide(
              color: colorScheme.primary,
              width: 2,
            ),
          ),
        ),
      ),
    );
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

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _back2Home(context),
        ),
        elevation: 0,
        title: Text(sl?.getText('numberpuzzles') ?? 'Number Puzzles'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 游戏标题
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: _buildGameTitle(sl, theme, guessitemProvider),
            ),
          ),
          // 数字输入和猜测按钮
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: colorScheme.surfaceContainerLow,
            child: Row(
              children: [
                _buildNumberInput(
                    theme, _ctlrs[0], _focusNodes[0], (v) => _onChange(0, v)),
                const SizedBox(width: 8),
                _buildNumberInput(
                    theme, _ctlrs[1], _focusNodes[1], (v) => _onChange(1, v)),
                const SizedBox(width: 8),
                _buildNumberInput(
                    theme, _ctlrs[2], _focusNodes[2], (v) => _onChange(2, v)),
                const SizedBox(width: 8),
                _buildNumberInput(
                    theme, _ctlrs[3], _focusNodes[3], (v) => _onChange(3, v)),
                const SizedBox(width: 12),
                Expanded(
                  flex: 0,
                  child: FilledButton(
                    onPressed: () => _guess(guessitemProvider),
                    style: FilledButton.styleFrom(
                      backgroundColor: guessitemProvider.isMatched
                          ? colorScheme.primary
                          : colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                    child: Text(
                      guessitemProvider.isMatched
                          ? (sl?.getText('win') ?? 'WIN')
                          : (sl?.getText('guess') ?? 'GUESS'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 猜测历史列表
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.only(top: 12),
              children: _buildGuessList(guessitemProvider, sl),
            ),
          )
        ],
      ));
  }

  @override
  void dispose() {
    for (TextEditingController ctlr in _ctlrs) {
      ctlr.dispose();
    }
    for (FocusNode fn in _focusNodes) {
      fn.dispose();
    }
    super.dispose();
  }
}
