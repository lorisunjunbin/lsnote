import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/Note.dart';
import '../service/NoteAccessSqlite.dart';
import '../utils/NavigationHelper.dart';
import 'NoteLanding.dart';

class Backup extends StatefulWidget {
  static final String routeName = '/Backup';

  @override
  _BackupState createState() => _BackupState();
}

class _BackupState extends State<Backup> {
  bool _restoreDisabled = true;
  bool _isJsonValid = false;
  String _jsonStatus = '';
  String? _lastExportedFilePath;
  String? _lastExportedDisplayPath;
  bool _isJsonFormatted = false;

  final _textCtlr = TextEditingController();
  final _editorScrollCtlr = ScrollController();


  @override
  Widget build(BuildContext context) {
    final sl = SimpleLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

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
              onPressed: () => NavigationHelper.replaceTo(
                context,
                NoteLanding.routeName,
              ),
            ),
            title: Text(sl?.getText('export_import') ?? 'Backup'),
            actions: [
              IconButton(
                tooltip: sl?.getText('exportToJSON'),
                icon: const Icon(Icons.file_upload),
                onPressed: () async {
                  await _populateJsonExport();
                }),
              IconButton(
                tooltip: sl?.getText('backupExportToFileTooltip') ?? 'Export to File',
                icon: const Icon(Icons.file_download),
                onPressed: _exportJsonToFile),
              IconButton(
                tooltip: _isJsonFormatted
                    ? (sl?.getText('backupCompressJsonTooltip') ?? 'Compress JSON')
                    : (sl?.getText('backupFormatJsonTooltip') ?? 'Validate & Format JSON'),
                icon: Icon(_isJsonFormatted ? Icons.compress : Icons.auto_fix_high),
                onPressed: _validateAndFormatJson),
              IconButton(
                  tooltip: sl?.getText('importFromJSON'),
                  icon: const Icon(Icons.save_alt),
                  onPressed: _restoreDisabled ? null : _importJson)
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_jsonStatus.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      _jsonStatus,
                      style: TextStyle(
                        color: _isJsonValid
                            ? colorScheme.primary
                            : colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_lastExportedFilePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: InkWell(
                      onLongPress: _copyExportPath,
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_open,
                            size: 14,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '${sl?.getText('backupLastExportedPrefix') ?? 'Last export: '}'
                              '${_getDisplayFileName()}',
                              style: TextStyle(
                                color: colorScheme.primary,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: sl?.getText('backupCopyPathTooltip') ?? 'Copy path',
                            icon: const Icon(Icons.copy, size: 14),
                            onPressed: _copyExportPath,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Scrollbar(
                    controller: _editorScrollCtlr,
                    thumbVisibility: true,
                    child: TextField(
                      controller: _textCtlr,
                      scrollController: _editorScrollCtlr,
                      onChanged: _onEditorChanged,
                      keyboardType: TextInputType.multiline,
                      minLines: null,
                      maxLines: null,
                      expands: true,
                      textCapitalization: TextCapitalization.none,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        color: colorScheme.onSurface,
                      ),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(
                            color: colorScheme.outline,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.zero,
                          borderSide: BorderSide(
                            color: colorScheme.primary,
                            width: 2,
                          ),
                        ),
                        alignLabelWithHint: true,
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                  ),
                )
              ],
            ),
          )),
    );
  }

  String _getDisplayFileName() {
    final path = _lastExportedDisplayPath ?? _lastExportedFilePath ?? '';
    if (path.isEmpty) return '';

    return path.split('/').last;
  }

  void _onEditorChanged(String val) {
    final hasText = val.trim().isNotEmpty;
    setState(() {
      _restoreDisabled = !hasText;
      _jsonStatus = '';
      _isJsonValid = false;
    });
  }

  Future<void> _populateJsonExport() async {
    final notes = await db.getNotesAll();
    final notesInMap = notes.map((e) => e.toJsonMapThin()).toList();
    final formatted = const JsonEncoder.withIndent('  ').convert(notesInMap);
    _textCtlr.text = formatted;
    setState(() {
      _isJsonValid = true;
      _isJsonFormatted = true;
      _restoreDisabled = false;
      _jsonStatus = '${_t('backupValidJsonStatusPrefix', 'Valid JSON. Items ready to import: ')}${notes.length}';
    });
  }

  Future<String?> _pickExportDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: _t('backupChooseFolderDialogTitle', 'Choose folder to save backup'),
    );
    return selected;
  }

  Future<String?> _saveWithSystemDialog(String jsonContent) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final suggestedFileName = 'lsnote_backup_$timestamp.json';

    final path = await FilePicker.platform.saveFile(
      dialogTitle: _t('backupChooseLocationDialogTitle', 'Choose location to save backup'),
      fileName: suggestedFileName,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: Uint8List.fromList(utf8.encode(jsonContent)),
    );

    return path;
  }

  Future<void> _exportJsonToFile() async {
    try {
      String jsonContent = _textCtlr.text.trim();
      if (jsonContent.isEmpty) {
        final notes = await db.getNotesAll();
        final notesInMap = notes.map((e) => e.toJsonMapThin()).toList();
        jsonContent = const JsonEncoder.withIndent('  ').convert(notesInMap);
        _textCtlr.text = jsonContent;
      }

      final selectedDirectory = await _pickExportDirectory();
      if (selectedDirectory == null || selectedDirectory.trim().isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_t('backupExportCancelledNoFolder', 'Export cancelled. No folder selected.'))),
        );
        return;
      }

      String savedPath;
      String displayPath;
      final directory = Directory(selectedDirectory);
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final fileName = 'lsnote_backup_$timestamp.json';
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);

      try {
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        await file.writeAsString(jsonContent, flush: true);
        savedPath = file.path;
        displayPath = file.path;
      } on FileSystemException {
        final fallbackPath = await _saveWithSystemDialog(jsonContent);
        if (fallbackPath == null || fallbackPath.trim().isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_t(
                'backupNoWritePermissionFallbackCancelled',
                'No write permission for selected folder, and fallback save was cancelled.',
              )),
            ),
          );
          return;
        }
        savedPath = fallbackPath;

        if (fallbackPath.startsWith('content://') || fallbackPath.startsWith('file://')) {
          displayPath = '$selectedDirectory/$fileName';
        } else {
          displayPath = fallbackPath;
        }
      }

      if (!mounted) return;
      setState(() {
        _lastExportedFilePath = savedPath;
        _lastExportedDisplayPath = displayPath;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${_t('backupExportedPrefix', 'Exported: ')}${displayPath.split('/').last}'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_t('backupExportFailedPrefix', 'Export failed: ')}$e')),
      );
    }
  }

  /// Validate and format JSON: validate first, then format if valid
  void _validateAndFormatJson() {
    final raw = _textCtlr.text.trim();
    if (raw.isEmpty) {
      _setValidationState(false, _t('backupEditorEmpty', 'Editor is empty.'));
      return;
    }

    try {
      final decoded = const JsonDecoder().convert(raw);
      final notes = _parseNotes(raw);

      if (_isJsonFormatted) {
        final compressed = const JsonEncoder().convert(decoded);
        _textCtlr.text = compressed;
        setState(() {
          _isJsonFormatted = false;
        });
      } else {
        final formatted = const JsonEncoder.withIndent('  ').convert(decoded);
        _textCtlr.text = formatted;
        setState(() {
          _isJsonFormatted = true;
        });
      }

      _setValidationState(
        true,
        '${_t('backupValidJsonStatusPrefix', 'Valid JSON. Items ready to import: ')}${notes.length}',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${_t('backupJsonValidSnackPrefix', 'JSON is valid and formatted. Items: ')}${notes.length}'
            ),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        );
      }
    } catch (e) {
      _setValidationState(false, '${_t('backupInvalidNoteJsonPrefix', 'Invalid note JSON: ')}$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_t('backupJsonInvalidPrefix', 'JSON is invalid: ')}$e'),
            backgroundColor: Theme.of(context).colorScheme.errorContainer,
          ),
        );
      }
    }
  }

  Future<void> _importJson() async {
    final sl = SimpleLocalizations.of(context);
    try {
      final notes = _parseNotes(_textCtlr.text);
      for (final note in notes) {
        await db.addOrUpdateNote(note);
      }

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.zero,
            ),
            title: Text(sl?.getText('messageLabel') ?? 'Message'),
            content: Text((sl?.getText('successImportLabel') ?? 'success') +
                notes.length.toString()),
            actions: <Widget>[
              TextButton(
                child: Text(sl?.getText('noticed') ?? 'OK'),
                onPressed: () => Navigator.of(context).pop())
            ]);
        },
      );
    } catch (e) {
      _setValidationState(false, '${_t('backupImportFailedPrefix', 'Import failed: ')}$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_t('backupImportFailedPrefix', 'Import failed: ')}$e')),
      );
    }
  }

  void _setValidationState(bool valid, String status) {
    setState(() {
      _isJsonValid = valid;
      _restoreDisabled = !valid;
      _jsonStatus = status;
    });
  }

  List<Note> _parseNotes(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      throw FormatException(_t('backupEditorEmpty', 'Editor is empty.'));
    }

    final decoded = const JsonDecoder().convert(trimmed);
    if (decoded is! List) {
      throw FormatException(_t('backupTopLevelArrayRequired', 'Top level JSON must be an array.'));
    }

    final List<Note> notes = [];
    for (var index = 0; index < decoded.length; index++) {
      final item = decoded[index];
      if (item is! Map) {
        throw FormatException(
            '${_t('backupItemNotJsonObjectPrefix', 'Item is not a JSON object. Index: ')}$index');
      }

      final map = Map<String, dynamic>.from(item);
      final id = _asInt(map['i']);
      final title = (map['t'] ?? '').toString();
      final content = (map['c'] ?? '').toString();
      final sequence = _asNum(map['s']) ?? (index * NoteAccessSqlite.sequenceStep);
      final isDone = _asBool(map['d']);
      final tdMillis = _asInt(map['td']);
      final targetDate = DateTime.fromMillisecondsSinceEpoch(
        tdMillis ?? DateTime.now().millisecondsSinceEpoch,
      );

      notes.add(Note(
        id: id,
        title: title,
        content: content,
        sequence: sequence,
        isDone: isDone,
        targetDate: targetDate,
      ));
    }

    return notes;
  }

  int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString());
  }

  num? _asNum(dynamic value) {
    if (value == null) return null;
    if (value is num) return value;
    return num.tryParse(value.toString());
  }

  bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == '1' || normalized == 'true';
    }
    return false;
  }

  @override
  void dispose() {
    _textCtlr.dispose();
    _editorScrollCtlr.dispose();
    super.dispose();
  }

  String _t(String key, String fallback) {
    return SimpleLocalizations.of(context)?.getText(key) ?? fallback;
  }

  Future<void> _copyExportPath() async {
    final fileName = _getDisplayFileName();
    if (fileName.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t('backupNoPathToCopy', 'No export path to copy.'))),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: fileName));

    // Haptic feedback on successful copy
    HapticFeedback.lightImpact();

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_t('backupPathCopied', 'Export path copied.'))),
    );
  }
}
