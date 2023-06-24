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

  List<ListTile> _buildList(
      GuessitemChangeNotifier provider, SimpleLocalizations sl) {
    return provider.guessItems
        .map((itm) => ListTile(
              leading: Text(itm.tryAnswer ?? ""),
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

  Widget _buildGameTitle(SimpleLocalizations sl, ThemeData theme,
      GuessitemChangeNotifier guessitemPrvider) {
    if (guessitemPrvider.isMatched) {
      int guessTime = guessitemPrvider.guessItems.length;
      String showText = guessTime < 4
          ? sl.getText('amazing')!
          : guessTime < 8
              ? sl.getText('awesome')!
              : guessTime < 10
                  ? sl.getText('wonderful')!
                  : sl.getText('justsoso')!;
      return Text(showText,
          style: TextStyle(
            fontSize: 30 - guessTime > 10 ? (30 - guessTime) * 1.0 : 10.0,
            color: theme.primaryColorDark,
            fontWeight: FontWeight.bold,
          ));
    }
    return Text(sl.getText('numberpuzzles')!,
        style: TextStyle(
            fontSize: 21.0,
            color: theme.hoverColor,
            fontWeight: FontWeight.w800));
  }

  String _buildDescription(GuessitemChangeNotifier provider,
          SimpleLocalizations sl, GuessItem itm) =>
      itm.step == 1
          ? '${sl.getText('start')} <${itm.tryTime?.toString().substring(0, 19)}>'
          : '${sl.getText('take')} ${itm.step} ${sl.getText('step')} ${sl.getText('in')} ${itm.duration?.inSeconds.toString()}${sl.getText('second')} <${itm.tryTime?.toString().substring(11, 19)}>';

  Expanded _buildNumberInput(ThemeData theme, TextEditingController ctr,
      FocusNode fn, ValueChanged<String> handler) {
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
        fontSize: 24.0,
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

  void _back2Home(BuildContext context) {
    Navigator.popAndPushNamed(context, NoteLanding.routeName);
  }

  @override
  Widget build(context) {
    final sl = SimpleLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final guessitemProvider = Provider.of<GuessitemChangeNotifier>(context);

    return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded),
            onPressed: () => _back2Home(context),
          ),
          elevation: 2.0,
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 40, 0, 40),
                child: _buildGameTitle(sl!, theme, guessitemProvider),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 16),
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
                const SizedBox(width: 8),
                MaterialButton(
                  onPressed: () => _guess(guessitemProvider),
                  child: guessitemProvider.isMatched
                      ? Text(sl.getText('win') ?? '',
                          style: new TextStyle(
                              fontSize: 18.0,
                              color: theme.primaryColorLight,
                              fontWeight: FontWeight.w800))
                      : Text(sl.getText('guess') ?? '',
                          style: new TextStyle(
                              fontSize: 18.0,
                              color: theme.primaryColorDark,
                              fontWeight: FontWeight.w800)),
                )
              ],
            ),
            Expanded(
              flex: 2,
              child: ListView(
                children: _buildList(guessitemProvider, sl),
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
