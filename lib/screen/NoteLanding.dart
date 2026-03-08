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
import '../NoteApp.dart';

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
  int _currentColorIndex = 0;

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (_reorderInFlight) return;

    final newIdx = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final item = _items.removeAt(oldIndex);
    _items.insert(newIdx, item);

    setState(() {});

    _reorderInFlight = true;
    try {
      await db.renumberNoteSequences(_items, step: _sequenceStep);
    } catch (_) {
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
        final cfgPrimarySwatch = await db.getConfig(Config.primarySwatch);
        _currentColorIndex = int.parse(cfgPrimarySwatch.value!);
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
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(title),
            content: SingleChildScrollView(
                child: ListBody(
              children: msgs.map((msg) => Text(msg)).toList(),
            )),
            actions: <Widget>[
              TextButton(
                  style: TextButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
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
    final colorScheme = theme.colorScheme;
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
          final isEmpty = _listTiles.isEmpty;

          return Scaffold(
              appBar: AppBar(
                titleSpacing: 0,
                title: _buildSearchBar(sl, colorScheme, switcherProvider),
              ),
              body: isEmpty
                  ? _buildEmptyState(colorScheme, sl)
                  : ReorderableListView(
                        onReorder: _onReorder,
                        buildDefaultDragHandles: false,
                        proxyDecorator: _proxyDecorator,
                        children: _listTiles,
                      ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endFloat,
              floatingActionButton: FloatingActionButton(
                onPressed: _onBtnPress,
                elevation: 4,
                mini: true,
                child: const Icon(Icons.add),
              ),
              bottomNavigationBar:
                  _buildBottomNavigationBar(context, sl!, colorScheme, switcherProvider));
        });
  }

  /// Material 3 搜索框
  Widget _buildSearchBar(SimpleLocalizations? sl, ColorScheme colorScheme,
      SwitcherChangeNotifier switcherProvider) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Expanded(
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
                hintText: sl?.getText('search'),
                hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
                prefixIcon: Icon(Icons.search, color: colorScheme.onSurfaceVariant),
                suffixIcon: _items.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: colorScheme.onSurfaceVariant),
                        onPressed: () {
                          _updateUI(context);
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
          ),
          // 隐藏已完成开关
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Transform.scale(
              scale: 0.8,
              child: Switch(
                value: switcherProvider.isHiddenDone(),
                onChanged: (bool value) {
                  setState(() {
                    switcherProvider.setHiddenDone(value);
                    db.setConfig(Config.hiddenDone, value ? '1' : '0');
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 空状态页面
  Widget _buildEmptyState(ColorScheme colorScheme, SimpleLocalizations? sl) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.note_alt_outlined,
              size: 60,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            sl?.getText('emptyNotes') ?? 'No notes yet',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            sl?.getText('emptyNotesHint') ?? 'Tap + to create your first note',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 拖拽代理装饰器
  Widget _proxyDecorator(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final animValue = Curves.easeInOut.transform(animation.value);
        return Transform.scale(
          scale: 1.0 + (animValue * 0.05),
          child: Opacity(
            opacity: 0.9,
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  /// Material 3 底部导航栏
  Widget _buildBottomNavigationBar(BuildContext context, SimpleLocalizations sl,
      ColorScheme colorScheme, SwitcherChangeNotifier switcherProvider) {
    return BottomNavigationBar(
            currentIndex: 0,
            onTap: (index) {
              switch (index) {
                case 0: // Save
                  _handleSave(sl);
                  break;
                case 1: // Delete
                  _handleDelete(sl);
                  break;
                case 2: // Backup
                  Navigator.of(context).pushReplacementNamed(Backup.routeName);
                  break;
                case 3: // Theme
                  _showColorPickerDialog(context, sl, colorScheme);
                  break;
                case 4: // Game
                  Navigator.of(context).pushReplacementNamed(NumberPuzzles.routeName);
                  break;
              }
            },
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.save_rounded),
                label: sl.getText('contentChanged') ?? 'Save',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.delete_rounded),
                label: sl.getText('confirm2delete') ?? 'Delete',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.backup_rounded),
                label: sl.getText('export_import') ?? 'Backup',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.palette_rounded),
                label: sl.getText('colorPicker') ?? 'Theme',
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.gamepad_rounded),
                label: sl.getText('numberpuzzles') ?? 'Game',
              ),
            ],
          );
  }

  /// 处理保存操作
  Future<void> _handleSave(SimpleLocalizations sl) async {
    if (_currentNote.id != null &&
        _ctrls.containsKey('${_currentNote.id}cblt')) {
      await db.updateNoteItemContent(
          _currentNote.id!, _ctrls['${_currentNote.id}cblt']!.value.text);
      _showMessageDialog(
          sl.getText('contentChanged')!,
          [
            '${_currentNote.title}',
            '',
            _ctrls['${_currentNote.id}cblt']!.value.text,
          ],
          sl.getText('noticed')!);
    }
  }

  /// 处理删除操作
  Future<void> _handleDelete(SimpleLocalizations sl) async {
    if (_currentNote.isDone) {
      showDialog<void>(
          context: context,
          builder: (context) {
            return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
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
  }

  /// 显示颜色选择器对话框
  void _showColorPickerDialog(BuildContext context, SimpleLocalizations sl,
      ColorScheme colorScheme) {
    showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  title: Row(
                    children: [
                      Icon(Icons.palette_rounded, color: colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        sl.getText('colorPicker')!,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  content: SizedBox(
                    width: 350,
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      alignment: WrapAlignment.center,
                      children: List.generate(Colors.primaries.length, (index) {
                        final color = Colors.primaries[index];
                        final isSelected = index == _currentColorIndex;
                        return InkWell(
                          onTap: () {
                            final themeNotifier = Provider.of<ThemeChangeNotifier>(dialogContext, listen: false);
                            themeNotifier.setTheme(AppTheme.getLightTheme(color));
                            db.setConfig(Config.primarySwatch, index.toString());
                            setDialogState(() {
                              _currentColorIndex = index;
                            });
                            setState(() {});
                          },
                          borderRadius: BorderRadius.circular(16),
                          child: AnimatedContainer(
                            width: 48,
                            height: 48,
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? colorScheme.onSurface
                                    : Colors.transparent,
                                width: 3,
                              ),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: color.withValues(alpha: 0.5),
                                        blurRadius: 12,
                                        spreadRadius: 2,
                                      )
                                    ]
                                  : null,
                            ),
                            child: isSelected
                                ? Icon(Icons.check_rounded,
                                    color: Colors.white, size: 24)
                                : null,
                          ),
                        );
                      }),
                    ),
                  ),
                  actions: <Widget>[
                    TextButton(
                        child: Text(
                          sl.getText('colorPickerClose')!,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                        })
                  ]);
            },
          );
        });
  }

  List<Widget> _buildItemList(ThemeData theme) {
    final colorScheme = theme.colorScheme;

    List<Widget> _listTiles = _items.asMap().entries.map((entry) {
      Note item = entry.value;

      _ctrls.putIfAbsent(
          '${item.id}cblt', () => TextEditingController(text: item.content));

      return Padding(
        key: Key('${item.id}'),
        padding: const EdgeInsets.symmetric(vertical: 0),
        child: Card(
          elevation: 0,
          color: item.isDone
              ? colorScheme.surfaceContainerLowest
              : colorScheme.surfaceContainerLow,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 复选框
                Padding(
                  padding: EdgeInsets.zero,
                  child: Checkbox(
                    value: item.isDone,
                    onChanged: (bool? newValue) {
                      _currentNote = item;
                      setState(() => item.isDone = newValue ?? false);
                      db.toggleNoteItem(item);
                    },
                  ),
                ),
                const SizedBox(width: 4),
                // 内容区域
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 标题和日期行
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${item.title}',
                              style: TextStyle(
                                color: item.isDone
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.onSurface,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${item.targetDate.toString().substring(0, 10)}',
                              style: TextStyle(
                                color: colorScheme.onPrimaryContainer,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          // 拖拽手柄
                          Padding(
                            padding: const EdgeInsets.only(left: 8, top: 4),
                            child: ReorderableDragStartListener(
                              index: entry.key,
                              child: Icon(
                                Icons.drag_handle_rounded,
                                color: colorScheme.onSurfaceVariant,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 内容输入框
                      TextField(
                        key: Key('${item.id}tf'),
                        controller: _ctrls['${item.id}cblt'],
                        keyboardType: TextInputType.multiline,
                        maxLines: null,
                        style: TextStyle(
                          color: item.isDone
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.onSurface,
                          fontSize: 15,
                          height: 1.4,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(8),
                          filled: true,
                          fillColor: item.isDone
                              ? colorScheme.surfaceContainerHighest
                              : colorScheme.surface,
                          enabledBorder: const OutlineInputBorder(
                            borderSide: BorderSide.none,
                            borderRadius: BorderRadius.zero,
                          ),
                          disabledBorder: const OutlineInputBorder(
                            borderSide: BorderSide.none,
                            borderRadius: BorderRadius.zero,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: BorderSide(
                              color: colorScheme.primary,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.zero,
                          ),
                        ),
                        onTap: () => _currentNote = item,
                        textCapitalization: TextCapitalization.sentences,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
    return _listTiles;
  }
}
