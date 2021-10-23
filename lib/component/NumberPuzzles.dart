import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../model/GuessItem.dart';
import '../i18n/SimpleLocalizations.dart';
import '../changenotifier/GuessItemChangeNotifier.dart';

class NumberPuzzles extends StatefulWidget {
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

  List<ListTile> _buildList(
      GuessitemChangeNotifier provider, SimpleLocalizations sl) {
    return provider.guessItems
        .map((itm) => ListTile(
              leading: Text(itm.tryAnswer),
              title: Text('${itm.result}'),
              trailing: Text(_buildDescription(provider, sl, itm)),
              contentPadding:
                  EdgeInsets.symmetric(vertical: 0.0, horizontal: 16.0),
              dense: true,
            ))
        .toList();
  }

  void _reset() {
    _ctlrs.forEach((ctr) => ctr.text = '');
    _focusNodes[0].requestFocus();
  }

  bool _validateInput() {
    return _ctlrs.indexWhere((ctl) => ctl.text == null || ctl.text.isEmpty) ==
        -1;
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

  Widget _buildGameTitle(SimpleLocalizations sl, ThemeData theme,
      GuessitemChangeNotifier guessitemPrvider) {
    if (guessitemPrvider.isMatched) {
      int guessTime = guessitemPrvider.guessItems.length;
      String showText = guessTime < 4
          ? sl.getText('amazing')
          : guessTime < 8
              ? sl.getText('awesome')
              : guessTime < 10
                  ? sl.getText('wonderful')
                  : sl.getText('justsoso');
      return Text(showText,
          style: TextStyle(
              fontSize: 30 - guessTime > 10 ? (30 - guessTime) * 1.0 : 10.0,
              color: theme.primaryColorDark,
              fontWeight: FontWeight.w900));
    }
    return Text(sl.getText('numberpuzzles'),
        style: TextStyle(
            fontSize: 21.0,
            color: theme.cursorColor,
            fontWeight: FontWeight.w800));
  }

  String _buildDescription(GuessitemChangeNotifier provider,
          SimpleLocalizations sl, GuessItem itm) =>
      itm.step == 1
          ? '${sl.getText('start')} <${itm.tryTime?.toString().substring(0, 19)}>'
          : '${sl.getText('take')} ${itm.step} ${sl.getText('step')} ${sl.getText('in')} ${itm.duration?.inSeconds.toString()}${sl.getText('second')} <${itm.tryTime?.toString().substring(11, 19)}>';

  Expanded _buildNumberInput(ThemeData theme, TextEditingController ctr,
      FocusNode fn, Function handler) {
    return Expanded(
        child: TextFormField(
      autofocus: true,
      focusNode: fn,
      controller: ctr,
      onChanged: handler,
      onTap: () => ctr.text = '',
      maxLength: 1,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 26.0,
        color: theme.primaryColor,
      ),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        counterText: "",
        contentPadding: EdgeInsets.fromLTRB(20, 0, 20, 0),
      ),
    ));
  }

  @override
  Expanded build(BuildContext context) {
    final sl = SimpleLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final guessitemProvider = Provider.of<GuessitemChangeNotifier>(context);

    return Expanded(
      flex: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
              child: _buildGameTitle(sl, theme, guessitemProvider),
            ),
          ),
          Expanded(
            flex: 1,
            child: Row(
              children: [
                const SizedBox(width: 20),
                _buildNumberInput(
                    theme, _ctlrs[0], _focusNodes[0], (v) => _onChange(0, v)),
                const SizedBox(width: 10),
                _buildNumberInput(
                    theme, _ctlrs[1], _focusNodes[1], (v) => _onChange(1, v)),
                const SizedBox(width: 10),
                _buildNumberInput(
                    theme, _ctlrs[2], _focusNodes[2], (v) => _onChange(2, v)),
                const SizedBox(width: 10),
                _buildNumberInput(
                    theme, _ctlrs[3], _focusNodes[3], (v) => _onChange(3, v)),
                const SizedBox(width: 10),
                MaterialButton(
                  onPressed: () => _guess(guessitemProvider),
                  child: guessitemProvider.isMatched
                      ? Text(sl.getText('win'),
                          style: new TextStyle(
                              fontSize: 21.0,
                              color: theme.cursorColor,
                              fontWeight: FontWeight.w800))
                      : Text(sl.getText('guess'),
                          style: new TextStyle(
                              fontSize: 20.0,
                              color: theme.primaryColorDark,
                              fontWeight: FontWeight.w800)),
                )
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: ListView(
              children: _buildList(guessitemProvider, sl),
            ),
          )
        ],
      ),
    );
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
