import 'package:flutter/material.dart';
import 'package:async/async.dart';
import 'package:lorisun_note/screen/NumberPuzzles.dart';
import 'package:provider/provider.dart';

import '../changenotifier/SwitcherChangeNotifier.dart';
import '../changenotifier/ThemeChangeNotifier.dart';
import '../i18n/SimpleLocalizations.dart';
import '../model/Config.dart';
import '../service/NoteAccessSqlite.dart';
import '../model/Note.dart';
import 'Backup.dart';
import 'NoteItem.dart';

class NoteLanding extends StatefulWidget {
  NoteLanding({Key? key, this.title}) : super(key: key);

  static final String routeName = '/NoteLanding';
  final String? title;

  @override
  _NoteLandingState createState() => _NoteLandingState();
}

class _NoteLandingState extends State<NoteLanding> {
  final AsyncMemoizer _memoizer = AsyncMemoizer();

  List<Note> _items = [];
  Note _currentNote = Note();
  Map<String, TextEditingController> _ctrls = {};

  void _onReorder(int oldIndex, int newIndex) {
    final newIdx = newIndex > oldIndex ? newIndex - 1 : newIndex;

    num properSequnce = 0;
    bool isFirst = newIdx == 0;
    bool isLast = newIdx == _items.length - 1;

    if (isFirst) {
      properSequnce = _items[0].sequence! - 500;
    } else if (isLast) {
      properSequnce = _items[_items.length - 1].sequence! + 500;
    } else {
      num pNodeSequence =
          _items[oldIndex < newIndex ? newIdx : newIdx - 1].sequence ?? 0;
      num aNodeSequence =
          _items[oldIndex > newIndex ? newIdx : newIdx + 1].sequence ?? 0;
      properSequnce = (pNodeSequence + aNodeSequence) / 2;
    }

    Note item = _items.removeAt(oldIndex);
    item.sequence = properSequnce;
    _items.insert(newIdx, item);

    db.updateNoteItemSequence(item.id, item.sequence);

    setState(() {});
  }

  void _onBtnPress() {
    Navigator.of(context).pushReplacementNamed(NoteItem.routeName);
  }

  Future<bool> _asyncInit(ctx) async {
    if (_items.isEmpty) {
      await _memoizer.runOnce(() async {
        _updateUI(ctx);
      });
    }
    return true;
  }

  Future<void> _updateUI(ctx) async {
    await _reloadData(ctx);
    setState(() {});
  }

  Future<void> _reloadData(ctx) async {
    final switcherProvider =
        Provider.of<SwitcherChangeNotifier>(ctx, listen: false);

    this._items = await db.getNotes({
      switcherProvider.isHiddenDone() ? ' where isDone=? ' : '':
          switcherProvider.isHiddenDone() ? 0 : null
    });
  }

  Future<void> _showMessageDialog(
      String title, List<String> msgs, String buttonTxt) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // user must tap button!
      builder: (context) {
        return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
                child: ListBody(
              children: msgs.map((msg) => Text(msg)).toList(),
            )),
            actions: <Widget>[
              TextButton(
                  child: Text(buttonTxt),
                  onPressed: () => Navigator.of(context).pop())
            ]);
      },
    );
  }

  @override
  void dispose() {
    _ctrls.forEach((key, value) {
      value.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(context) {
    final sl = SimpleLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final switcherProvider = Provider.of<SwitcherChangeNotifier>(context);

    switcherProvider.addListener(() {
      _updateUI(context);
    });

    return FutureBuilder(
        future: _asyncInit(context),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data == false) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          List<CheckboxListTile> _listTiles = _buildItemList(theme);

          return Scaffold(
              appBar: AppBar(
                title: SizedBox(
                  height: 40,
                  child: TextField(
                      onChanged: (v) async {
                        if (v.isNotEmpty) {
                          _items = await db.getNotes({
                            ' where ( title like ? ': '%$v%',
                            ' or content like ?) ': '%$v%',
                            switcherProvider.isHiddenDone()
                                ? ' and isDone=? '
                                : '': switcherProvider.isHiddenDone() ? 0 : null
                          });
                          setState(() {});
                        } else {
                          _updateUI(context);
                        }
                      },
                      decoration: InputDecoration(
                          hintStyle: TextStyle(color: theme.primaryColorDark),
                          hintText: sl?.getText('search'),
                          focusColor: theme.primaryColorLight,
                          border: InputBorder.none,
                          filled: true,
                          fillColor: theme.primaryColorLight,
                          contentPadding: EdgeInsets.all(10),
                          enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                  color: theme.primaryColorLight, width: 1.0),
                              borderRadius: BorderRadius.circular(10)),
                          focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                  color: theme.primaryColorLight, width: 1.0),
                              borderRadius: BorderRadius.circular(10)),
                          suffixIcon: Icon(Icons.search))),
                ),
              ),
              body: Container(
                child: ReorderableListView(
                  onReorder: _onReorder,
                  children: _listTiles,
                ),
              ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endDocked,
              floatingActionButton: Container(
                height: 50.0,
                width: 50.0,
                child: FloatingActionButton(
                  backgroundColor: Theme.of(context).primaryColorLight,
                  onPressed: _onBtnPress,
                  child: Icon(Icons.add, color: Theme.of(context).primaryColorDark),
                ),
              ),
              // This trailing comma makes auto-formatting nicer for build methods.
              bottomNavigationBar:
                  _buildBottomAppBar(context, sl!, theme, switcherProvider));
        });
  }

  BottomAppBar _buildBottomAppBar(BuildContext context, SimpleLocalizations sl,
      ThemeData theme, SwitcherChangeNotifier switcherProvider) {
    return BottomAppBar(
        height: 66,
        shape: CircularNotchedRectangle(),
        color: Theme.of(context).primaryColorLight,
        child: Row(children: <Widget>[
          IconButton(
            color: Theme.of(context).primaryColorDark,
            icon: Icon(Icons.save_sharp),
            onPressed: () async {
              if (_currentNote.id != null &&
                  _ctrls.containsKey('${_currentNote.id}cblt')) {
                await db.updateNoteItemContent(_currentNote.id!,
                    _ctrls['${_currentNote.id}cblt']!.value.text);
                _showMessageDialog(
                    sl.getText('contentChanged')!,
                    [
                      '${_currentNote.title}',
                      '',
                      _ctrls['${_currentNote.id}cblt']!.value.text,
                    ],
                    sl.getText('noticed')!);
              }
            },
          ),
          IconButton(
              icon: const Icon(Icons.delete_sharp),
              color: Theme.of(context).primaryColorDark,
              onPressed: () {
                if (this._currentNote.isDone) {
                  showDialog<void>(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                            title: Text(sl.getText('confirm')!),
                            content: SingleChildScrollView(
                              child: ListBody(
                                children: [
                                  Text(sl.getText('confirm2delete')!),
                                  Text('${_currentNote.title!}')
                                ],
                              ),
                            ),
                            actions: <Widget>[
                              TextButton(
                                  child: Text(sl.getText('confirmYes')!),
                                  onPressed: () {
                                    db.deleteNoteItem(this._currentNote);
                                    Navigator.of(context).pop();
                                    _updateUI(context);
                                  })
                            ]);
                      });
                }
              }),
          IconButton(
              icon: const Icon(Icons.import_export_sharp),
              color: Theme.of(context).primaryColorDark,
              onPressed: () async =>
                  Navigator.of(context).pushReplacementNamed(Backup.routeName)),
          IconButton(
              icon: const Icon(Icons.color_lens_outlined),
              color: Theme.of(context).primaryColorDark,
              onPressed: () {
                showDialog<void>(
                    context: context,
                    builder: (context) {
                      final themeNotifier =
                          Provider.of<ThemeChangeNotifier>(context);
                      return AlertDialog(
                          title: Text(sl.getText('colorPicker')!),
                          titleTextStyle: TextStyle(
                              fontSize: 25.0,
                              fontWeight: FontWeight.bold,
                              color: theme.primaryColorDark),
                          content: SingleChildScrollView(
                              child: ListBody(
                            children: _buildColorList(themeNotifier),
                          )),
                          actions: <Widget>[
                            TextButton(
                                child: Text(sl.getText('colorPickerClose')!,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 20.0,
                                    )),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                })
                          ]);
                    });
              }),
          IconButton(
              icon: const Icon(Icons.gamepad_outlined),
              color: Theme.of(context).primaryColorDark,
              onPressed: () {
                Navigator.of(context)
                    .pushReplacementNamed(NumberPuzzles.routeName);
              }),
          Switch(
              value: switcherProvider.isHiddenDone(),
              activeColor: Theme.of(context).primaryColorDark,
              inactiveTrackColor: Theme.of(context).primaryColorLight,



              onChanged: (bool value) => setState(() {
                    switcherProvider.setHiddenDone(value);
                    db.setConfig(Config.hiddenDone, value ? '1' : '0');
                  }))
        ]));
  }

  List<CheckboxListTile> _buildItemList(ThemeData theme) {
    List<CheckboxListTile> _listTiles = _items.map((item) {
      _ctrls.putIfAbsent(
          '${item.id}cblt', () => TextEditingController(text: item.content));

      return CheckboxListTile(
          activeColor: theme.primaryColorLight,
          checkColor: theme.primaryColorDark,
          key: Key('${item.id}'),
          value: item.isDone,
          title: Row(children: [
            Text(
              '${item.title}',
              style: TextStyle(
                  color: theme.primaryColorDark,
                  fontSize: 20.0,
                  fontWeight: FontWeight.bold),
            ),
            Spacer(),
            Text(
              '${item.targetDate.toString().substring(0, 10)}',
              style: TextStyle(
                  color: theme.primaryColorLight,
                  fontSize: 8.0,
                  fontWeight: FontWeight.normal),
            )
          ]),
          subtitle: TextField(
            key: Key('${item.id}tf'),
            controller: _ctrls['${item.id}cblt'],
            keyboardType: TextInputType.multiline,
            maxLines: null,
            decoration: InputDecoration(
              border: InputBorder.none,
              contentPadding: EdgeInsets.fromLTRB(8, 20, 0, 0),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                color: theme.primaryColorLight,
                width: 1, //宽度为5
              )),

              fillColor: theme.secondaryHeaderColor,
              filled: true,

              // contentPadding: EdgeInsets.all(10),
              focusColor: theme.primaryColorLight,
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(
                  color: theme.primaryColorDark,
                  width: 1, //宽度为5
                ),
                borderRadius: BorderRadius.all(
                  Radius.circular(8),
                ),
              ),
            ),
            onTap: () => this._currentNote = item,
            textCapitalization: TextCapitalization.sentences,
          ),
          onChanged: (bool? newValue) {
            this._currentNote = item;
            setState(() => item.isDone = newValue ?? false);
            db.toggleNoteItem(item);
          });
    }).toList();
    return _listTiles;
  }

  List<MaterialButton> _buildColorList(themeNotifier) {
    final _primarySwatchNames = [
      'red',
      'pink',
      'purple',
      'deepPurple',
      'indigo',
      'blue',
      'lightBlue',
      'cyan',
      'teal',
      'green',
      'lightGreen',
      'lime',
      'yellow',
      'amber',
      'orange',
      'deepOrange',
      'brown',
      'blueGrey',
    ];

    return Colors.primaries
        .map(
          (c) => MaterialButton(
              key: Key('${c.toString()}'),
              onPressed: () {
                themeNotifier.setTheme(ThemeData(
                  primarySwatch: c,
                  visualDensity: VisualDensity.adaptivePlatformDensity,
                ));
                db.setConfig(Config.primarySwatch,
                    Colors.primaries.indexOf(c).toString());
              },
              child: Text(_primarySwatchNames[Colors.primaries.indexOf(c)],
                  style: new TextStyle(
                    fontSize: 24.0,
                    color: c,
                  ))),
        )
        .toList();
  }
}
