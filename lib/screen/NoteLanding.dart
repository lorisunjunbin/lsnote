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
  static const int _sequenceStep = 1024;

  List<Note> _items = [];
  Note _currentNote = Note();
  Map<String, TextEditingController> _ctrls = {};
  bool _reorderInFlight = false;

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (_reorderInFlight) return;

    final newIdx = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final item = _items.removeAt(oldIndex);
    _items.insert(newIdx, item);

    // Update UI in the same frame as drop to avoid old->new visual jump.
    setState(() {});

    _reorderInFlight = true;
    try {
      await db.renumberNoteSequences(_items, step: _sequenceStep);
    } catch (_) {
      // If persistence fails, reload from DB to recover consistent order.
      await _reloadData(context);
      if (mounted) {
        setState(() {});
      }
    } finally {
      _reorderInFlight = false;
    }
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

          List<Widget> _listTiles = _buildItemList(theme);

          return Scaffold(
              appBar: AppBar(
                titleSpacing: 0,
                title: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
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
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                  color: Colors.transparent, width: 0),
                              borderRadius: BorderRadius.zero),
                          focusedBorder: OutlineInputBorder(
                              borderSide: BorderSide(
                                  color: theme.primaryColorDark, width: 2),
                              borderRadius: BorderRadius.zero),
                          suffixIcon: Icon(Icons.search,
                              color: theme.primaryColorDark))),
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
                  child: Icon(Icons.add,
                      color: Theme.of(context).primaryColorDark),
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
        height: 60,
        shape: CircularNotchedRectangle(),
        color: Theme.of(context).primaryColorLight,
        child: Row(children: <Widget>[
          IconButton(
            tooltip: sl.getText('contentChanged'),
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
              tooltip: sl.getText('confirm2delete'),
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
              tooltip: sl.getText('export_import'),
              icon: const Icon(Icons.settings_backup_restore_rounded),
              color: Theme.of(context).primaryColorDark,
              onPressed: () async =>
                  Navigator.of(context).pushReplacementNamed(Backup.routeName)),
          IconButton(
              tooltip: sl.getText('colorPicker'),
              icon: const Icon(Icons.color_lens_outlined),
              color: Theme.of(context).primaryColorDark,
              onPressed: () {
                showDialog<void>(
                    context: context,
                    builder: (context) {
                      final themeNotifier =
                          Provider.of<ThemeChangeNotifier>(context);
                      final currentPrimary =
                          themeNotifier.getTheme()?.primaryColor ??
                              theme.primaryColor;

                      return AlertDialog(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                          contentPadding:
                              const EdgeInsets.fromLTRB(16, 4, 16, 12),
                          title: Row(
                            children: [
                              Icon(Icons.palette_outlined,
                                  color: theme.primaryColorDark),
                              const SizedBox(width: 8),
                              Text(sl.getText('colorPicker')!),
                            ],
                          ),
                          titleTextStyle: TextStyle(
                              fontSize: 22.0,
                              fontWeight: FontWeight.w700,
                              color: theme.primaryColorDark),
                          content: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: SingleChildScrollView(
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children:
                                    _buildColorList(themeNotifier, currentPrimary),
                              ),
                            ),
                          ),
                          actions: <Widget>[
                            TextButton(
                                child: Text(
                                  sl.getText('colorPickerClose')!,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 17.0,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                })
                          ]);
                    });
              }),
          IconButton(
              tooltip: sl.getText('numberpuzzles'),
              icon: const Icon(Icons.gamepad_outlined),
              color: Theme.of(context).primaryColorDark,
              onPressed: () {
                Navigator.of(context)
                    .pushReplacementNamed(NumberPuzzles.routeName);
              }),
          Spacer(),
          Padding(
            padding: EdgeInsets.only(right: 56),
            child: Center(
              child: Switch(
                  value: switcherProvider.isHiddenDone(),
                  activeThumbColor: Theme.of(context).primaryColorDark,
                  activeTrackColor: Theme.of(context).primaryColorLight,
                  onChanged: (bool value) => setState(() {
                        switcherProvider.setHiddenDone(value);
                        db.setConfig(Config.hiddenDone, value ? '1' : '0');
                      })),
            ),
          )
        ]));
  }

  List<Widget> _buildItemList(ThemeData theme) {
    List<Widget> _listTiles = _items.asMap().entries.map((entry) {
      Note item = entry.value;

      _ctrls.putIfAbsent(
          '${item.id}cblt', () => TextEditingController(text: item.content));

      return Padding(
        key: Key('${item.id}'),
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Card(
          elevation: 2,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: CheckboxListTile(
              activeColor: theme.primaryColorLight,
              checkColor: theme.primaryColorDark,
              key: Key('${item.id}'),
              value: item.isDone,
              title: Row(children: [
                Expanded(
                  child: Text(
                    '${item.title}',
                    style: TextStyle(
                        color: item.isDone
                            ? theme.primaryColorLight
                            : theme.primaryColorDark,
                        fontSize: 20.0,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                SizedBox(width: 6),
                Text(
                  '${item.targetDate.toString().substring(0, 10)}',
                  style: TextStyle(
                      color: item.isDone
                          ? theme.primaryColorLight
                          : theme.primaryColorDark,
                      fontSize: 13.0,
                      fontWeight: FontWeight.w500),
                )
              ]),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextField(
                  key: Key('${item.id}tf'),
                  controller: _ctrls['${item.id}cblt'],
                  keyboardType: TextInputType.multiline,
                  maxLines: null,
                  enabled: !item.isDone,
                  style: TextStyle(
                    color: item.isDone
                        ? theme.primaryColorLight
                        : theme.primaryColorDark,
                    fontSize: 16,
                    height: 1.25,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.fromLTRB(8, 8, 8, 8),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: theme.primaryColorLight,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(8)),
                    disabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(
                          color: theme.primaryColorLight,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(8)),
                    fillColor: item.isDone
                        ? theme.primaryColorLight.withValues(alpha: 0.1)
                        : theme.secondaryHeaderColor,
                    filled: true,
                    focusColor: theme.primaryColorLight,
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: theme.primaryColorDark,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onTap: () => this._currentNote = item,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ),
              onChanged: (bool? newValue) {
                this._currentNote = item;
                setState(() => item.isDone = newValue ?? false);
                db.toggleNoteItem(item);
              }),
        ),
      );
    }).toList();
    return _listTiles;
  }

  List<Widget> _buildColorList(
      ThemeChangeNotifier themeNotifier, Color currentPrimary) {
    final primarySwatchNames = [
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

    return Colors.primaries.map((c) {
      final idx = Colors.primaries.indexOf(c);
      final selected = c.toARGB32() == currentPrimary.toARGB32();

      return InkWell(
        key: Key('${c.toString()}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          themeNotifier.setTheme(ThemeData(
            primarySwatch: c,
            visualDensity: VisualDensity.adaptivePlatformDensity,
          ));
          db.setConfig(Config.primarySwatch, idx.toString());
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? c.shade50 : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? c.shade700 : c.shade200,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                primarySwatchNames[idx],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? c.shade900 : c.shade700,
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_circle, size: 16, color: c.shade700),
              ]
            ],
          ),
        ),
      );
    }).toList();
  }
}
