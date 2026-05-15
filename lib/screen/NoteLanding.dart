import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:async/async.dart';
import 'package:lorisun_note/screen/NumberPuzzles.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../changenotifier/SwitcherChangeNotifier.dart';
import '../changenotifier/ThemeChangeNotifier.dart';
import '../i18n/SimpleLocalizations.dart';
import '../model/Config.dart';
import '../service/NoteAccessSqlite.dart';
import '../model/Note.dart';
import 'Backup.dart';
import 'NoteItem.dart';
import '../NoteApp.dart';
import '../service/AiPrompts.dart';
import '../service/McpService.dart';
import '../service/AiService.dart';
import 'AiChat.dart';

class NoteLanding extends StatefulWidget {
  NoteLanding({Key? key, this.title}) : super(key: key);

  static final String routeName = '/NoteLanding';
  final String? title;

  @override
  _NoteLandingState createState() => _NoteLandingState();
}

class _NoteLandingState extends State<NoteLanding>
    with TickerProviderStateMixin {
  final AsyncMemoizer _memoizer = AsyncMemoizer();
  static const int _sequenceStep = 1024;

  List<Note> _items = [];
  Map<String, TextEditingController> _ctrls = {};
  bool _reorderInFlight = false;
  int _currentColorIndex = 0;

  final Map<int, bool> _cardExpandedStates = {};
  final Map<int, List<String>> _undoStacks = {};
  final Map<int, List<String>> _redoStacks = {};
  final Map<int, bool> _isOrganizing = {};
  bool _welcomeRequested = false;
  bool _autoAiColor = false;

  SwitcherChangeNotifier? _switcherProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<SwitcherChangeNotifier>(context, listen: false);
    if (_switcherProvider != provider) {
      _switcherProvider?.removeListener(_onSwitcherChanged);
      _switcherProvider = provider;
      _switcherProvider!.addListener(_onSwitcherChanged);
    }
  }

  void _onSwitcherChanged() {
    _updateUI(context);
  }
  bool _isFiltering = false;
  final List<StreamSubscription> _aiSubs = [];

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingDuration = 0;
  Timer? _recordingTimer;
  bool _isTranscribing = false;
  final Set<int> _removingIds = {};
  final Map<int, AnimationController> _removeAnimations = {};

  void _animateRemoval(int id, Future<void> Function() onComplete) {
    if (_removingIds.contains(id)) return;
    final controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _removeAnimations[id] = controller;
    setState(() => _removingIds.add(id));
    controller.forward().then((_) async {
      if (!mounted) return;
      _removingIds.remove(id);
      _removeAnimations.remove(id);
      controller.dispose();
      await onComplete();
    });
  }

  void _toggleCardExpansion(int noteId) {
    setState(() {
      _cardExpandedStates[noteId] = !(_cardExpandedStates[noteId] ?? false);
    });
  }

  bool get _isAllExpanded {
    if (_items.isEmpty) return false;
    return _items.every((item) => _cardExpandedStates[item.id!] ?? false);
  }

  void _toggleAllCards() {
    if (_isAllExpanded) {
      setState(() {
        for (var item in _items) {
          _cardExpandedStates[item.id!] = false;
        }
      });
    } else {
      setState(() {
        for (var item in _items) {
          _cardExpandedStates[item.id!] = true;
        }
      });
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (_reorderInFlight) return;

    final newIdx = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final item = _items.removeAt(oldIndex);
    _items.insert(newIdx, item);

    setState(() {});

    _reorderInFlight = true;
    try {
      // Only update the affected range [lo, hi]
      final lo = oldIndex < newIdx ? oldIndex : newIdx;
      final hi = oldIndex < newIdx ? newIdx : oldIndex;
      await db.renumberRangeSequences(_items, lo, hi, step: _sequenceStep);
    } catch (_) {
      await _reloadData(context);
      if (mounted) setState(() {});
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
        final parsedIndex = int.tryParse(cfgPrimarySwatch.value ?? '0') ?? 0;
        _currentColorIndex = parsedIndex.clamp(0, AppTheme.themeColorPalette.length - 1);
        final cfgAutoColor = await db.getConfig(Config.autoAiColor);
        _autoAiColor = cfgAutoColor.value == '1';
        _updateUI(ctx);
        _requestWelcome();
        _autoApplyAiColor(ctx);
      });
    }
    return true;
  }

  Future<void> _updateUI(ctx) async {
    await _reloadData(ctx);
    setState(() {});
  }

  void _requestWelcome() async {
    if (_welcomeRequested || !AiService.instance.isReady) return;
    if (AiService.instance.isThinkingModel) return;
    _welcomeRequested = true;

    // Wait briefly for MCP context (weather/holiday) to be fetched
    if (McpService.instance.isEnabled && McpService.instance.contextCache.isEmpty) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (McpService.instance.contextCache.isNotEmpty) break;
      }
    }

    final hour = DateTime.now().hour;
    final timeOfDay = hour < 6
        ? 'late night'
        : hour < 12
            ? 'morning'
            : hour < 18
                ? 'afternoon'
                : 'evening';

    final buffer = StringBuffer();
    final now = DateTime.now();
    final topics = ['food', 'blue sky', 'coffee', 'cats', 'fresh air', 'food', 'music'];
    final topic = topics[now.millisecondsSinceEpoch % topics.length];
    try {
      final sub = AiService.instance
          .completeStream(
        AiPrompts.greeting(topic),
        timeOfDay,
        maxLength: 80,
      )
          .listen(
        (token) {
          buffer.write(token);
        },
        onDone: () {
          final msg = buffer.toString().trim();
          if (msg.isNotEmpty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(child: Text(msg)),
                  ],
                ),
                duration: const Duration(seconds: 4),
                behavior: SnackBarBehavior.floating,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
            );
          }
        },
        onError: (_) {},
      );
      _aiSubs.add(sub);
    } catch (_) {}
  }

  Future<void> _showRecordingSheet() async {
    if (!AiService.instance.isReady || !AiService.instance.isAudioModel) return;
    if (!await _recorder.hasPermission()) return;

    final sl = SimpleLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    await showModalBottomSheet(
      context: context,
      isDismissible: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> toggleRec() async {
              if (_isRecording) {
                _recordingTimer?.cancel();
                final path = await _recorder.stop();
                setSheetState(() {
                  _isRecording = false;
                  _recordingDuration = 0;
                });
                Navigator.of(ctx).pop();
                if (path == null) return;
                _transcribeAndCreateNote(path);
              } else {
                final dir = await getTemporaryDirectory();
                final path =
                    '${dir.path}/voice_landing_${DateTime.now().millisecondsSinceEpoch}.wav';
                await _recorder.start(
                  const RecordConfig(
                    encoder: AudioEncoder.wav,
                    sampleRate: 16000,
                    numChannels: 1,
                  ),
                  path: path,
                );
                setSheetState(() {
                  _isRecording = true;
                  _recordingDuration = 0;
                });
                _recordingTimer =
                    Timer.periodic(const Duration(seconds: 1), (_) {
                  if (mounted) setSheetState(() => _recordingDuration++);
                });
              }
            }

            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sl.getText('aiVoiceToNote') ?? 'Voice to Note',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_isRecording) ...[
                    Icon(Icons.fiber_manual_record,
                        size: 48, color: Colors.red),
                    const SizedBox(height: 12),
                    Text(
                      '${_recordingDuration}s',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w300,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      sl.getText('aiRecording') ?? 'Recording...',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ] else ...[
                    Icon(Icons.mic, size: 48, color: colorScheme.primary),
                    const SizedBox(height: 12),
                    Text(
                      sl.getText('aiRecordHint') ?? 'Tap to record',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton(
                        onPressed: () async {
                          if (_isRecording) {
                            _recordingTimer?.cancel();
                            await _recorder.stop();
                            setState(() {
                              _isRecording = false;
                              _recordingDuration = 0;
                            });
                          }
                          Navigator.of(ctx).pop();
                        },
                        child: Text(sl.getText('cancelLabel') ?? 'Cancel'),
                      ),
                      ElevatedButton.icon(
                        icon: Icon(_isRecording ? Icons.stop : Icons.mic),
                        label: Text(_isRecording
                            ? (sl.getText('aiTranscribing') ?? 'Stop')
                            : (sl.getText('start') ?? 'Start')),
                        onPressed: toggleRec,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _transcribeAndCreateNote(String audioPath) async {
    if (!AiService.instance.isReady) return;
    setState(() => _isTranscribing = true);

    try {
      final transcription = await AiService.instance
          .completeAudio(AiPrompts.landingTranscribe(), audioPath, null);

      if (transcription.trim().isEmpty) return;

      // Use AI to extract title and content
      String title = '';
      String content = transcription.trim();

      final buffer = StringBuffer();
      await AiService.instance
          .completeStream(
            AiPrompts.extractNoteStructure(),
            transcription.trim(),
            maxLength: 200,
          )
          .forEach((token) => buffer.write(token));

      final structured = buffer.toString().trim();
      final titleMatch = RegExp(r'TITLE:\s*(.+)', caseSensitive: false).firstMatch(structured);
      final contentMatch = RegExp(r'CONTENT:\s*([\s\S]+)', caseSensitive: false).firstMatch(structured);
      if (titleMatch != null) title = titleMatch.group(1)!.trim();
      if (contentMatch != null) content = contentMatch.group(1)!.trim();

      // Fallback if parsing failed
      if (title.isEmpty) {
        title = content.length > 20 ? content.substring(0, 20) : content;
      }

      final note = Note(
        title: title,
        content: content,
        targetDate: DateTime.now(),
        sequence: 0,
        isDone: false,
      );
      await db.addNote(note);
      await _updateUI(context);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isTranscribing = false);
      try { File(audioPath).delete(); } catch (_) {}
    }
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
    _switcherProvider?.removeListener(_onSwitcherChanged);
    for (final sub in _aiSubs) {
      sub.cancel();
    }
    _recordingTimer?.cancel();
    _recorder.dispose();
    _ctrls.forEach((key, value) {
      value.dispose();
    });
    for (final controller in _removeAnimations.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(context) {
    final sl = SimpleLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final switcherProvider = Provider.of<SwitcherChangeNotifier>(context);

    return FutureBuilder(
        future: _asyncInit(context),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data == false) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final isEmpty = _items.isEmpty;

          return Scaffold(
              appBar: AppBar(
                titleSpacing: 0,
                title: _buildSearchBar(sl, colorScheme, switcherProvider),
              ),
              body: isEmpty
                  ? _buildEmptyState(colorScheme, sl)
                  : Column(
                      children: [
                        _buildStatsBar(colorScheme, sl),
                        Expanded(
                          child: ReorderableListView.builder(
                            itemCount: _items.length,
                            onReorder: _onReorder,
                            buildDefaultDragHandles: false,
                            proxyDecorator: _proxyDecorator,
                            itemBuilder: (context, index) {
                              return _buildNoteCard(_items[index], index, theme);
                            },
                          ),
                        ),
                      ],
                    ),
              floatingActionButtonLocation:
                  FloatingActionButtonLocation.endFloat,
              floatingActionButton: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (AiService.instance.isReady &&
                      AiService.instance.isAudioModel)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FloatingActionButton(
                        heroTag: 'voice',
                        onPressed: (_isTranscribing) ? null : _showRecordingSheet,
                        elevation: 4,
                        mini: true,
                        backgroundColor: _isRecording
                            ? Colors.red
                            : null,
                        child: _isTranscribing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Icon(_isRecording ? Icons.stop : Icons.mic),
                      ),
                    ),
                  FloatingActionButton(
                    heroTag: 'add',
                    onPressed: _onBtnPress,
                    elevation: 4,
                    mini: true,
                    child: const Icon(Icons.add),
                  ),
                ],
              ),
              bottomNavigationBar:
                  _buildBottomNavigationBar(context, sl!, colorScheme, switcherProvider));
        });
  }

  Widget _buildSearchBar(SimpleLocalizations? sl, ColorScheme colorScheme,
      SwitcherChangeNotifier switcherProvider) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              onChanged: (v) async {
                if (v.isNotEmpty) {
                  _isFiltering = true;
                  _items = await db.getNotes({
                    ' where ( title like ? ': '%$v%',
                    ' or content like ?) ': '%$v%',
                    switcherProvider.isHiddenDone()
                        ? ' and isDone=? '
                        : '': switcherProvider.isHiddenDone() ? 0 : null
                  });
                  setState(() {});
                } else {
                  _isFiltering = false;
                  _updateUI(context);
                }
              },
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: sl?.getText('search'),
                hintStyle: TextStyle(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
                prefixIcon: Icon(Icons.search, color: colorScheme.onSurfaceVariant, size: 20),
                prefixIconConstraints: const BoxConstraints(minWidth: 36),
                suffixIcon: _items.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: colorScheme.onSurfaceVariant, size: 18),
                        onPressed: () {
                          _isFiltering = false;
                          _updateUI(context);
                        },
                      )
                    : null,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
          ),
          if (_items.isNotEmpty)
            IconButton(
              icon: Icon(
                _isAllExpanded ? Icons.unfold_less : Icons.unfold_more,
                color: colorScheme.onSurfaceVariant,
              ),
              tooltip: _isAllExpanded
                  ? (sl?.getText('collapseAll') ?? 'Collapse All')
                  : (sl?.getText('expandAll') ?? 'Expand All'),
              onPressed: _toggleAllCards,
            ),
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

  Widget _buildStatsBar(ColorScheme colorScheme, SimpleLocalizations? sl) {
    final total = _items.length;
    final doneCount = _items.where((n) => n.isDone).length;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final dueToday = _items.where((n) =>
        !n.isDone &&
        n.targetDate != null &&
        n.targetDate!.isAfter(today) &&
        n.targetDate!.isBefore(tomorrow)).length;
    final overdue = _items.where((n) =>
        !n.isDone &&
        n.targetDate != null &&
        n.targetDate!.isBefore(today)).length;

    final isZh = sl?.locale.languageCode == 'zh';
    final parts = <String>[];
    parts.add(isZh == true ? '共 $total 条' : '$total notes');
    if (doneCount > 0) {
      parts.add(isZh == true ? '完成 $doneCount' : '$doneCount done');
    }
    if (dueToday > 0) {
      parts.add(isZh == true ? '今日到期 $dueToday' : '$dueToday due today');
    }
    if (overdue > 0) {
      parts.add(isZh == true ? '已过期 $overdue' : '$overdue overdue');
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          Text(
            parts.join(' · '),
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme, SimpleLocalizations? sl) {
    final icon = _isFiltering ? Icons.search_off : Icons.note_alt_outlined;
    final title = _isFiltering
        ? (sl?.getText('emptySearch') ?? 'No matching notes')
        : (sl?.getText('emptyNotes') ?? 'No notes yet');
    final hint = _isFiltering
        ? (sl?.getText('emptySearchHint') ?? 'Try a different search term')
        : (sl?.getText('emptyNotesHint') ?? 'Tap + to create your first note');
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
              icon,
              size: 60,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hint,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

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

  Widget _buildBottomNavigationBar(BuildContext context, SimpleLocalizations sl,
      ColorScheme colorScheme, SwitcherChangeNotifier switcherProvider) {
    return BottomNavigationBar(
            currentIndex: 0,
            onTap: (index) {
              switch (index) {
                case 0:
                  Navigator.of(context).pushReplacementNamed(Backup.routeName);
                  break;
                case 1:
                  _showColorPickerDialog(context, sl, colorScheme);
                  break;
                case 2:
                  Navigator.of(context).pushReplacementNamed(NumberPuzzles.routeName);
                  break;
                case 3:
                  Navigator.of(context).pushReplacementNamed(AiChat.routeName);
                  break;
              }
            },
            items: [
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
              BottomNavigationBarItem(
                icon: const Icon(Icons.auto_awesome),
                label: sl.getText('aiChat') ?? 'AI',
              ),
            ],
          );
  }

  void _pushSnapshot(int noteId) {
    final ctrl = _ctrls['${noteId}cblt'];
    if (ctrl == null) return;
    _undoStacks.putIfAbsent(noteId, () => []);
    _redoStacks.putIfAbsent(noteId, () => []);
    _undoStacks[noteId]!.add(ctrl.text);
    _redoStacks[noteId]!.clear();
  }

  void _undo(int noteId) {
    final undoStack = _undoStacks[noteId];
    final ctrl = _ctrls['${noteId}cblt'];
    if (undoStack == null || undoStack.isEmpty || ctrl == null) return;
    _redoStacks.putIfAbsent(noteId, () => []);
    _redoStacks[noteId]!.add(ctrl.text);
    setState(() {
      ctrl.text = undoStack.removeLast();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    });
  }

  void _redo(int noteId) {
    final redoStack = _redoStacks[noteId];
    final ctrl = _ctrls['${noteId}cblt'];
    if (redoStack == null || redoStack.isEmpty || ctrl == null) return;
    _undoStacks.putIfAbsent(noteId, () => []);
    _undoStacks[noteId]!.add(ctrl.text);
    setState(() {
      ctrl.text = redoStack.removeLast();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    });
  }

  void _organizeNoteContent(Note item) {
    if (!AiService.instance.isReady) return;
    final ctrl = _ctrls['${item.id}cblt'];
    if (ctrl == null || ctrl.text.trim().isEmpty) return;

    _pushSnapshot(item.id!);
    setState(() => _isOrganizing[item.id!] = true);

    final rawText = ctrl.text.trim();
    final buffer = StringBuffer();
    try {
      final sub = AiService.instance
          .completeStream(
        AiPrompts.landingOrganize(),
        rawText,
      )
          .listen(
        (token) {
          buffer.write(token);
          if (mounted) {
            setState(() {
              ctrl.text = AiService.stripThinkingTags(buffer.toString());
              ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
            });
          }
        },
        onDone: () {
          if (mounted) setState(() => _isOrganizing[item.id!] = false);
        },
        onError: (_) {
          if (mounted) setState(() => _isOrganizing[item.id!] = false);
        },
      );
      _aiSubs.add(sub);
    } catch (_) {
      if (mounted) setState(() => _isOrganizing[item.id!] = false);
    }
  }

  Future<void> _handleCardSave(Note item, SimpleLocalizations sl) async {
    final contentCtrl = _ctrls['${item.id}cblt'];
    if (contentCtrl == null) return;
    final newTitle = _ctrls['${item.id}title']?.text ?? item.title ?? '';
    final newContent = contentCtrl.value.text;
    final updated = Note(
      id: item.id,
      title: newTitle,
      content: newContent,
      sequence: item.sequence,
      isDone: item.isDone,
      targetDate: item.targetDate,
    );
    await db.updateNote(updated);
    await _updateUI(context);
    _showMessageDialog(
        sl.getText('contentChanged')!,
        [newTitle, '', newContent],
        sl.getText('noticed')!);
  }

  Future<void> _handleCardCopy(Note item, SimpleLocalizations sl) async {
    final content = _ctrls['${item.id}cblt']?.value.text ?? item.content ?? '';
    await Clipboard.setData(ClipboardData(text: content));
  }

  Future<void> _handleCardDelete(Note item, SimpleLocalizations sl) async {
    if (item.isDone) {
      showDialog<void>(
          context: context,
          builder: (dialogCtx) {
            return AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                title: Text(sl.getText('confirm')!),
                content: SingleChildScrollView(
                  child: ListBody(
                    children: [
                      Text(sl.getText('confirm2delete')!),
                      Text('${item.title!}')
                    ],
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    child: Text(sl.getText('cancelLabel') ?? 'Cancel'),
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                  ),
                  TextButton(
                      child: Text(sl.getText('confirmYes')!),
                      onPressed: () {
                        Navigator.of(dialogCtx).pop();
                        _animateRemoval(item.id!, () async {
                          await db.deleteNoteItem(item);
                          await _updateUI(context);
                        });
                      })
                ]);
          });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sl.getText('markDoneBeforeDelete') ?? 'Mark as done before deleting'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static const List<String> _colorNamesZh = [
    '红', '粉', '紫', '深紫', '靛蓝', '蓝', '浅蓝', '青',
    '青绿', '绿', '浅绿', '黄绿', '黄', '琥珀', '橙', '深橙',
    '雾霾蓝', '薄荷绿', '烟粉', '石板灰',
  ];
  static const List<String> _colorNamesEn = [
    'Red', 'Pink', 'Purple', 'Deep Purple', 'Indigo', 'Blue', 'Light Blue', 'Cyan',
    'Teal', 'Green', 'Light Green', 'Lime', 'Yellow', 'Amber', 'Orange', 'Deep Orange',
    'Mist Blue', 'Mint', 'Smoky Pink', 'Slate',
  ];

  void _showColorPickerDialog(BuildContext context, SimpleLocalizations sl,
      ColorScheme colorScheme) {
    final isZh = sl.locale.languageCode == 'zh';
    showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              final currentColor = AppTheme.themeColorPalette[_currentColorIndex];
              final currentScheme = ColorScheme.fromSeed(seedColor: currentColor);
              return AlertDialog(
                  backgroundColor: currentScheme.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  contentPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  title: Row(
                    children: [
                      Icon(Icons.palette_rounded, color: currentScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        sl.getText('colorPicker')!,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: currentScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                  content: SizedBox(
                    width: 350,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          alignment: WrapAlignment.center,
                          children: List.generate(AppTheme.themeColorPalette.length, (index) {
                            final color = AppTheme.themeColorPalette[index];
                            final isSelected = index == _currentColorIndex;
                            final luminance = color.computeLuminance();
                            final checkColor = luminance > 0.5 ? Colors.black87 : Colors.white;
                            final colorName = isZh ? _colorNamesZh[index] : _colorNamesEn[index];
                            return Tooltip(
                              message: colorName,
                              preferBelow: false,
                              child: InkWell(
                                onTap: () {
                                  HapticFeedback.lightImpact();
                                  final themeNotifier = Provider.of<ThemeChangeNotifier>(dialogContext, listen: false);
                                  themeNotifier.setTheme(AppTheme.getLightTheme(color));
                                  db.setConfig(Config.primarySwatch, index.toString());
                                  setDialogState(() {
                                    _currentColorIndex = index;
                                  });
                                  setState(() {});
                                  _showAiColorCompliment(color);
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
                                          ? currentScheme.primary
                                          : color.withValues(alpha: 0.3),
                                      width: isSelected ? 3 : 1,
                                    ),
                                    boxShadow: isSelected
                                        ? [
                                            BoxShadow(
                                              color: color.withValues(alpha: 0.4),
                                              blurRadius: 8,
                                              spreadRadius: 1,
                                            )
                                          ]
                                        : null,
                                  ),
                                  child: isSelected
                                      ? Icon(Icons.check_rounded,
                                          color: checkColor, size: 24)
                                      : null,
                                ),
                              ),
                            );
                          }),
                        ),
                      ],
                    ),
                  ),
                  actionsAlignment: MainAxisAlignment.spaceBetween,
                  actions: <Widget>[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 30,
                          width: 50,
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: Switch(
                              value: _autoAiColor,
                              onChanged: (v) {
                                db.setConfig(Config.autoAiColor, v ? '1' : '0');
                                setDialogState(() => _autoAiColor = v);
                                setState(() {});
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (AiService.instance.isReady && !AiService.instance.isThinkingModel)
                          TextButton.icon(
                            icon: Icon(Icons.auto_awesome, size: 16, color: currentScheme.primary),
                            label: Text(
                              sl.getText('aiRecommendColor') ?? 'AI Recommend',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: currentScheme.primary,
                              ),
                            ),
                            onPressed: () => _aiRecommendColor(dialogContext, setDialogState),
                          ),
                        TextButton(
                            child: Text(
                              sl.getText('colorPickerClose')!,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                color: currentScheme.primary,
                              ),
                            ),
                            onPressed: () {
                              Navigator.of(dialogContext).pop();
                            }),
                      ],
                    ),
                  ]);
            },
          );
        });
  }

  void _showAiColorCompliment(Color color) async {
    if (!AiService.instance.isReady) return;
    if (AiService.instance.isThinkingModel) return;

    final colorNames = {
      Colors.red: 'Red/红色',
      Colors.pink: 'Pink/粉色',
      Colors.purple: 'Purple/紫色',
      Colors.deepPurple: 'Deep Purple/深紫色',
      Colors.indigo: 'Indigo/靛蓝色',
      Colors.blue: 'Blue/蓝色',
      Colors.lightBlue: 'Light Blue/浅蓝色',
      Colors.cyan: 'Cyan/青色',
      Colors.teal: 'Teal/青绿色',
      Colors.green: 'Green/绿色',
      Colors.lightGreen: 'Light Green/浅绿色',
      Colors.lime: 'Lime/黄绿色',
      Colors.yellow: 'Yellow/黄色',
      Colors.amber: 'Amber/琥珀色',
      Colors.orange: 'Orange/橙色',
      Colors.deepOrange: 'Deep Orange/深橙色',
      const Color(0xFF6B8FA3): 'Mist Blue/雾霾蓝',
      const Color(0xFF7ECEC0): 'Mint/薄荷绿',
      const Color(0xFFD4A5A5): 'Smoky Pink/烟粉',
      const Color(0xFF708090): 'Slate/石板灰',
    };
    final colorName = colorNames[color] ?? color.toString();

    final buffer = StringBuffer();
    try {
      final sub = AiService.instance
          .completeStream(
            AiPrompts.colorCompliment(colorName),
            colorName,
            maxLength: 60,
          )
          .listen(
        (token) {
          buffer.write(token);
        },
        onDone: () {
          final text = buffer.toString().trim();
          if (text.isNotEmpty && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(text),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
              ),
            );
          }
        },
        onError: (_) {},
      );
      _aiSubs.add(sub);
    } catch (_) {}
  }

  void _aiRecommendColor(BuildContext dialogContext, void Function(void Function()) setDialogState) async {
    if (!AiService.instance.isReady) return;

    final mcpCtx = McpService.instance.contextCache;
    final colorNames = [
      'red', 'pink', 'purple', 'deepPurple', 'indigo', 'blue',
      'lightBlue', 'cyan', 'teal', 'green', 'lightGreen', 'lime',
      'yellow', 'amber', 'orange', 'deepOrange',
      'mistBlue', 'mint', 'smokyPink', 'slate',
    ];

    final buffer = StringBuffer();
    try {
      await AiService.instance
          .completeStream(
            AiPrompts.recommendColor(mcpCtx, colorNames),
            'recommend',
            maxLength: 30,
          )
          .forEach((token) => buffer.write(token));

      final result = buffer.toString().trim().toLowerCase();
      final matchIndex = colorNames.indexWhere((name) => result.contains(name.toLowerCase()));
      if (matchIndex >= 0 && matchIndex < AppTheme.themeColorPalette.length) {
        final color = AppTheme.themeColorPalette[matchIndex];
        final themeNotifier = Provider.of<ThemeChangeNotifier>(dialogContext, listen: false);
        themeNotifier.setTheme(AppTheme.getLightTheme(color));
        db.setConfig(Config.primarySwatch, matchIndex.toString());
        setDialogState(() {
          _currentColorIndex = matchIndex;
        });
        setState(() {});
      }
    } catch (_) {}
  }

  void _autoApplyAiColor(BuildContext ctx) async {
    if (!_autoAiColor) return;
    if (!AiService.instance.isReady) {
      if (AiService.instance.state != AiServiceState.loading) return;
      while (AiService.instance.state == AiServiceState.loading) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (!AiService.instance.isReady) return;
    }
    if (AiService.instance.isThinkingModel) return;

    if (McpService.instance.isEnabled && McpService.instance.contextCache.isEmpty) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (McpService.instance.contextCache.isNotEmpty) break;
      }
    }

    final mcpCtx = McpService.instance.contextCache;
    final colorNames = [
      'red', 'pink', 'purple', 'deepPurple', 'indigo', 'blue',
      'lightBlue', 'cyan', 'teal', 'green', 'lightGreen', 'lime',
      'yellow', 'amber', 'orange', 'deepOrange',
      'mistBlue', 'mint', 'smokyPink', 'slate',
    ];

    final buffer = StringBuffer();
    try {
      await AiService.instance
          .completeStream(
            AiPrompts.recommendColor(mcpCtx, colorNames),
            'recommend',
            maxLength: 30,
          )
          .forEach((token) => buffer.write(token));

      final result = buffer.toString().trim().toLowerCase();
      final matchIndex = colorNames.indexWhere((name) => result.contains(name.toLowerCase()));
      if (matchIndex >= 0 && matchIndex < AppTheme.themeColorPalette.length && mounted) {
        final color = AppTheme.themeColorPalette[matchIndex];
        final themeNotifier = Provider.of<ThemeChangeNotifier>(ctx, listen: false);
        themeNotifier.setTheme(AppTheme.getLightTheme(color));
        db.setConfig(Config.primarySwatch, matchIndex.toString());
        setState(() => _currentColorIndex = matchIndex);
      }
    } catch (_) {}
  }

  Future<void> _showAiAssistSheet(
      Note item, SimpleLocalizations sl, ColorScheme colorScheme) async {
    final content = _ctrls['${item.id}cblt']?.value.text ?? item.content ?? '';
    if (content.isEmpty) return;

    String? aiResult;
    bool isLoading = false;
    bool sheetClosed = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void safeSetState(VoidCallback fn) {
              if (!sheetClosed) setSheetState(fn);
            }

            Future<void> runAction(String systemPrompt) async {
              if (!AiService.instance.isReady) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(sl.getText('aiModelNotReady') ??
                            'Please configure AI model in AI settings')),
                  );
                }
                return;
              }
              if (isLoading) return;
              safeSetState(() {
                isLoading = true;
                aiResult = '';
              });

              try {
                final completer = Completer<void>();
                final sub = AiService.instance
                    .completeStream(systemPrompt, content)
                    .listen(
                  (token) {
                    safeSetState(() {
                      aiResult = AiService.stripThinkingTags(
                          (aiResult ?? '') + token);
                    });
                  },
                  onDone: () {
                    safeSetState(() => isLoading = false);
                    if (!completer.isCompleted) completer.complete();
                  },
                  onError: (e) {
                    safeSetState(() {
                      aiResult = 'Error: $e';
                      isLoading = false;
                    });
                    if (!completer.isCompleted) completer.complete();
                  },
                  cancelOnError: true,
                );
                _aiSubs.add(sub);
                await completer.future;
              } catch (e) {
                safeSetState(() {
                  aiResult = 'Error: $e';
                  isLoading = false;
                });
              }
            }

            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollCtl) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      sl.getText('aiAssist') ?? 'AI Assist',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _aiActionChip(
                          sl.getText('aiSummarize') ?? 'Summarize',
                          Icons.summarize,
                          colorScheme,
                          isLoading,
                          () => runAction(AiPrompts.summarize()),
                        ),
                        _aiActionChip(
                          sl.getText('aiPolish') ?? 'Polish',
                          Icons.auto_fix_high,
                          colorScheme,
                          isLoading,
                          () => runAction(AiPrompts.improveGrammar()),
                        ),
                        _aiActionChip(
                          sl.getText('aiTranslate') ?? 'Translate',
                          Icons.translate,
                          colorScheme,
                          isLoading,
                          () => runAction(AiPrompts.translate),
                        ),
                        _aiActionChip(
                          sl.getText('aiContinue') ?? 'Continue',
                          Icons.edit_note,
                          colorScheme,
                          isLoading,
                          () => runAction(AiPrompts.landingContinue()),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: scrollCtl,
                        child: isLoading && (aiResult == null || aiResult!.isEmpty)
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(32),
                                  child: CircularProgressIndicator(
                                    color: colorScheme.primary,
                                  ),
                                ),
                              )
                            : SelectableText(
                                aiResult ?? '',
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                      ),
                    ),
                    if (aiResult != null && aiResult!.isNotEmpty && !isLoading)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            icon: const Icon(Icons.find_replace, size: 18),
                            label: Text(sl.getText('aiReplace') ?? 'Replace'),
                            onPressed: () {
                              _ctrls['${item.id}cblt']?.text = aiResult!;
                              Navigator.of(ctx).pop();
                            },
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(sl.getText('aiAppend') ?? 'Append'),
                            onPressed: () {
                              final current =
                                  _ctrls['${item.id}cblt']?.text ?? '';
                              _ctrls['${item.id}cblt']?.text =
                                  '$current\n\n$aiResult';
                              Navigator.of(ctx).pop();
                            },
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      sheetClosed = true;
    });
  }

  Widget _aiActionChip(String label, IconData icon, ColorScheme colorScheme,
      bool disabled, VoidCallback onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: disabled ? null : onTap,
    );
  }

  Widget _formatButton(IconData icon, String tooltip, VoidCallback onTap, ColorScheme colorScheme) {
    return IconButton(
      icon: Icon(icon, size: 18),
      color: colorScheme.onSurfaceVariant,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
      onPressed: onTap,
    );
  }

  void _insertAtCursor(TextEditingController ctrl, String text) {
    final selection = ctrl.selection;
    final baseOffset = selection.isValid ? selection.baseOffset : ctrl.text.length;
    final newText = ctrl.text.replaceRange(
      baseOffset, selection.isValid ? selection.extentOffset : baseOffset, text);
    ctrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: baseOffset + text.length),
    );
    setState(() {});
  }

  Widget _buildSwipeBackground({
    required Alignment alignment,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      color: color.withValues(alpha: 0.15),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Icon(icon, color: color, size: 28),
    );
  }

  Future<bool> _confirmSwipeDelete(Note item, SimpleLocalizations sl) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Text(sl.getText('confirm')!),
          content: SingleChildScrollView(
            child: ListBody(
              children: [
                Text(sl.getText('confirm2delete')!),
                Text('${item.title!}'),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text(sl.getText('cancelLabel') ?? 'Cancel'),
              onPressed: () => Navigator.of(dialogCtx).pop(false),
            ),
            TextButton(
              child: Text(sl.getText('confirmYes')!),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Widget _buildNoteCard(Note item, int index, ThemeData theme) {
    final sl = SimpleLocalizations.of(context)!;
    final colorScheme = theme.colorScheme;

      _ctrls.putIfAbsent(
          '${item.id}cblt', () => TextEditingController(text: item.content));
      _ctrls.putIfAbsent(
          '${item.id}title', () => TextEditingController(text: item.title));

      final isExpanded = _cardExpandedStates[item.id!] ?? false;

      Widget card = Padding(
        padding: const EdgeInsets.symmetric(vertical: 0),
        child: Card(
          elevation: 0,
          color: item.isDone || isExpanded
              ? colorScheme.surfaceContainerLowest
              : colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            side: isExpanded
                ? BorderSide(
                    color: colorScheme.primary.withValues(alpha: 0.8),
                    width: 1.0,
                  )
                : !item.isDone
                    ? BorderSide(
                        color: colorScheme.primary.withValues(alpha: 0.55),
                        width: 0.35,
                      )
                    : BorderSide.none,
              borderRadius: BorderRadius.zero,
            ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 4,
              vertical: isExpanded ? 4 : 1,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isExpanded) ...[
                  Padding(
                    padding: EdgeInsets.zero,
                    child: Checkbox(
                      value: item.isDone,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (bool? newValue) {
                        setState(() => item.isDone = newValue ?? false);
                        db.toggleNoteItem(item);
                        final sp = Provider.of<SwitcherChangeNotifier>(
                            context, listen: false);
                        if (sp.isHiddenDone() && newValue == true) {
                          _animateRemoval(item.id!, () async {
                            await _updateUI(context);
                          });
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 0),
                ],
                Expanded(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => _toggleCardExpansion(item.id!),
                              child: Row(
                                children: [
                                  if (item.isPinned && !isExpanded)
                                    Icon(
                                      Icons.push_pin,
                                      size: 14,
                                      color: colorScheme.primary,
                                    ),
                                  Icon(
                                    isExpanded
                                        ? Icons.expand_more
                                        : Icons.chevron_right,
                                    color: isExpanded ? colorScheme.primary : colorScheme.onSurfaceVariant,
                                    size: 24,
                                  ),
                                  const SizedBox(width: 4),
                                  if (isExpanded)
                                    Expanded(
                                      child: TextField(
                                        controller: _ctrls['${item.id}title'],
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: item.isDone
                                              ? colorScheme.onSurfaceVariant
                                              : colorScheme.onSurface,
                                        ),
                                        decoration: InputDecoration(
                                          isDense: true,
                                          border: InputBorder.none,
                                          contentPadding: const EdgeInsets.symmetric(
                                              horizontal: 4, vertical: 4),
                                          filled: true,
                                          fillColor: colorScheme.surfaceContainerLowest,
                                          enabledBorder: const OutlineInputBorder(
                                            borderSide: BorderSide.none,
                                            borderRadius: BorderRadius.zero,
                                          ),
                                          focusedBorder: OutlineInputBorder(
                                            borderSide: BorderSide(
                                              color: colorScheme.primary,
                                              width: 1.5,
                                            ),
                                            borderRadius: BorderRadius.zero,
                                          ),
                                        ),
                                        textCapitalization: TextCapitalization.sentences,
                                      ),
                                    )
                                  else
                                    Expanded(
                                      child: Text(
                                        '${item.title}',
                                        style: TextStyle(
                                          color: item.isDone
                                              ? colorScheme.onSurfaceVariant
                                              : colorScheme.onSurface,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (isExpanded) const SizedBox(width: 5),
                          if (item.targetDate != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4, right: 4),
                              child: Text(
                                item.targetDate!.year == DateTime.now().year
                                    ? '${item.targetDate.toString().substring(5, 10)}'
                                    : '${item.targetDate.toString().substring(0, 10)}',
                                style: TextStyle(
                                  color: item.targetDate!.isAfter(DateTime.now())
                                      ? const Color(0xFF66BB6A)
                                      : colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: ReorderableDragStartListener(
                              index: index,
                              child: Icon(
                                Icons.drag_handle,
                                color: colorScheme.onSurfaceVariant,
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (isExpanded) ...[
                        const SizedBox(height: 6),
                        TextField(
                          key: Key('${item.id}tf'),
                          controller: _ctrls['${item.id}cblt'],
                          keyboardType: TextInputType.multiline,
                          maxLines: null,
                          style: TextStyle(
                            color: item.isDone
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.onSurface,
                            fontSize: 14,
                            height: 1.4,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.all(8),
                            filled: true,
                            fillColor: colorScheme.surfaceContainerLowest,
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
                          textCapitalization: TextCapitalization.sentences,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 0, bottom: 0),
                          child: Builder(builder: (_) {
                            final text = _ctrls['${item.id}cblt']?.text ?? '';
                            final chars = text.length;
                            final lines = text.isEmpty ? 0 : text.split('\n').length;
                            return Row(
                              children: [
                                Text(
                                  '$chars chars · $lines lines',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                  ),
                                ),
                              ],
                            );
                          }),
                        ),
                        Wrap(
                          spacing: 4,
                          runSpacing: 0,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            IconButton(
                              icon: Icon(Icons.copy_outlined, size: 18),
                              color: colorScheme.onSurfaceVariant,
                              tooltip: sl.getText('copyTooltip') ?? 'Copy',
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                              onPressed: () => _handleCardCopy(item, sl),
                            ),
                            IconButton(
                              icon: Icon(Icons.save_outlined, size: 18),
                              color: colorScheme.primary,
                              tooltip: sl.getText('saveTooltip') ?? 'Save',
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                              onPressed: () => _handleCardSave(item, sl),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, size: 18),
                              color: item.isDone
                                  ? colorScheme.error
                                  : colorScheme.onSurfaceVariant,
                              tooltip: sl.getText('confirm2delete') ?? 'Delete',
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                              onPressed: () => _handleCardDelete(item, sl),
                            ),
                            IconButton(
                              icon: Icon(Icons.auto_awesome, size: 18),
                              color: colorScheme.primary,
                              tooltip: sl.getText('aiAssist') ?? 'AI Assist',
                              padding: EdgeInsets.zero,
                              constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                              onPressed: () => _showAiAssistSheet(item, sl, colorScheme),
                            ),
                            if (AiService.instance.isReady) ...[
                              IconButton(
                                icon: (_isOrganizing[item.id] == true)
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : Icon(Icons.auto_fix_high, size: 18),
                                color: colorScheme.tertiary,
                                tooltip: sl.getText('aiOrganize') ?? 'AI Organize',
                                padding: EdgeInsets.zero,
                                constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                                onPressed: (_isOrganizing[item.id] == true)
                                    ? null
                                    : () => _organizeNoteContent(item),
                              ),
                            ],
                            if ((_undoStacks[item.id]?.isNotEmpty ?? false) ||
                                (_redoStacks[item.id]?.isNotEmpty ?? false)) ...[
                              IconButton(
                                icon: Icon(Icons.undo, size: 16),
                                color: (_undoStacks[item.id]?.isNotEmpty ?? false)
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.outlineVariant,
                                padding: EdgeInsets.zero,
                                constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                                onPressed: (_undoStacks[item.id]?.isNotEmpty ?? false)
                                    ? () => _undo(item.id!)
                                    : null,
                              ),
                              IconButton(
                                icon: Icon(Icons.redo, size: 16),
                                color: (_redoStacks[item.id]?.isNotEmpty ?? false)
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.outlineVariant,
                                padding: EdgeInsets.zero,
                                constraints: BoxConstraints(minWidth: 28, minHeight: 24),
                                onPressed: (_redoStacks[item.id]?.isNotEmpty ?? false)
                                    ? () => _redo(item.id!)
                                    : null,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final controller = _removeAnimations[item.id];
      if (_removingIds.contains(item.id) && controller != null) {
        final slideAnimation = Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(-1.0, 0.0),
        ).animate(CurvedAnimation(parent: controller, curve: Curves.easeIn));
        final fadeAnimation = Tween<double>(
          begin: 1.0,
          end: 0.0,
        ).animate(CurvedAnimation(parent: controller, curve: Curves.easeIn));
        return SizedBox(
          key: Key('${item.id}'),
          child: SlideTransition(
            position: slideAnimation,
            child: FadeTransition(opacity: fadeAnimation, child: card),
          ),
        );
      }

      return Dismissible(
        key: Key('${item.id}'),
        direction: isExpanded
            ? DismissDirection.none
            : DismissDirection.horizontal,
        background: _buildSwipeBackground(
          alignment: Alignment.centerLeft,
          color: Colors.amber,
          icon: item.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
        ),
        secondaryBackground: _buildSwipeBackground(
          alignment: Alignment.centerRight,
          color: Colors.red,
          icon: Icons.delete_outline,
        ),
        confirmDismiss: (direction) async {
          if (direction == DismissDirection.endToStart) {
            if (!item.isDone) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(sl.getText('markDoneBeforeDelete') ?? 'Mark as done before deleting'),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
              return false;
            }
            return await _confirmSwipeDelete(item, sl);
          } else {
            setState(() => item.isPinned = !item.isPinned);
            db.toggleNotePinned(item);
            await _updateUI(context);
            return false;
          }
        },
        onDismissed: (direction) {
          if (direction == DismissDirection.endToStart) {
            db.deleteNoteItem(item);
            _updateUI(context);
          }
        },
        child: card,
      );
  }
}
