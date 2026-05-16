import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/Note.dart';
import '../service/AiPrompts.dart';
import '../service/AiService.dart';
import '../service/NoteAccessSqlite.dart';
import '../utils/NavigationHelper.dart';
import 'NoteLanding.dart';

class NoteItem extends StatefulWidget {
  static final String routeName = '/NoteItem';

  @override
  _NoteItemState createState() => _NoteItemState();
}

class _NoteItemState extends State<NoteItem>
    with SingleTickerProviderStateMixin {
  static DateTime? _datetime = DateTime.now().add(const Duration(days: 1));
  late final TextEditingController _titleCtl;
  late final TextEditingController _contentCtl;
  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;
  bool _isAiProcessing = false;
  bool _isRecording = false;
  int _recordingDuration = 0;
  final AudioRecorder _recorder = AudioRecorder();
  String? _recordingPath;
  String? _cachedImagePath;
  String? _lastRecordingPath;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  StreamSubscription? _playerStateSub;
  StreamSubscription? _aiStreamSub;

  @override
  void initState() {
    super.initState();
    _titleCtl = TextEditingController();
    _contentCtl = TextEditingController();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    SchedulerBinding.instance.addPostFrameCallback((_) {
      _animationController.forward();
    });

    _contentCtl.addListener(_onContentChanged);
    _waitForModelReady();
  }

  bool _contentWasEmpty = true;

  void _onContentChanged() {
    final isEmpty = _contentCtl.text.trim().isEmpty;
    if (isEmpty != _contentWasEmpty) {
      _contentWasEmpty = isEmpty;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _aiStreamSub?.cancel();
    _playerStateSub?.cancel();
    _recorder.dispose();
    _audioPlayer.dispose();
    _contentCtl.removeListener(_onContentChanged);
    _contentCtl.dispose();
    _titleCtl.dispose();
    _animationController.dispose();
    if (_lastRecordingPath != null) {
      try { File(_lastRecordingPath!).delete(); } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sl = SimpleLocalizations.of(context)!;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: NavigationHelper.createPopCallback(
        context,
        NoteLanding.routeName,
      ),
      child: Scaffold(
        backgroundColor: colorScheme.surface,
        appBar: _buildAppBar(context, sl, colorScheme),
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: SlideTransition(
            position: _slideAnimation,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDatepickerCard(colorScheme, sl),
                  const SizedBox(height: 16),
                  _buildNoteTitleTextField(colorScheme, sl),
                  const SizedBox(height: 16),
                  _buildNoteDetailTextField(colorScheme, sl),
                  const SizedBox(height: 24),
                  _buildSaveButton(colorScheme, sl),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
      BuildContext context, SimpleLocalizations sl, ColorScheme colorScheme) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => NavigationHelper.replaceTo(
          context,
          NoteLanding.routeName,
        ),
      ),
      elevation: 0,
      scrolledUnderElevation: 1,
      title: Text(
        sl.getText('addNote') ?? 'New Note',
        style: const TextStyle(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildDatepickerCard(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.zero,
      child: InkWell(
        onTap: () => _showDatePicker(sl, colorScheme),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.zero,
                ),
                child: Icon(
                  Icons.calendar_month,
                  color: colorScheme.onPrimaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sl.getText('targetDate') ?? 'Target Date',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _datetime != null
                          ? _formatDate(_datetime!)
                          : (sl.getText('targetDateNone') ?? 'Not set'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _datetime != null
                            ? colorScheme.onSurface
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (_datetime != null)
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: colorScheme.onSurfaceVariant),
                  onPressed: () => setState(() => _datetime = null),
                )
              else
                Icon(
                  Icons.chevron_right,
                  color: colorScheme.onSurfaceVariant,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDatePicker(SimpleLocalizations sl, ColorScheme colorScheme) {
    showDatePicker(
      context: context,
      initialDate: _datetime ?? DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.parse("2020-01-01"),
      lastDate: DateTime.parse("2030-12-31"),
      cancelText: sl.getText('cancelLabel'),
      confirmText: sl.getText('confirmLabel'),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: colorScheme,
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.primary,
              ),
            ),
          ),
          child: child!,
        );
      },
    ).then((value) {
      if (value != null) {
        setState(() {
          _datetime = value;
        });
      }
    });
  }

  String _formatDate(DateTime date) {
    final months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Widget _buildNoteTitleTextField(ColorScheme colorScheme, SimpleLocalizations sl) {
    return TextField(
      controller: _titleCtl,
      keyboardType: TextInputType.text,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      decoration: InputDecoration(
        hintText: sl.getText('titleLabel') ?? 'Title',
        hintStyle: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
        ),
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
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.zero,
          borderSide: BorderSide(
            color: colorScheme.error,
            width: 2,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
    );
  }

  Widget _buildNoteDetailTextField(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _contentCtl,
          keyboardType: TextInputType.multiline,
          maxLines: null,
          minLines: 8,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(
            fontSize: 15,
            height: 1.5,
            color: colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            hintText: sl.getText('contentLabel') ?? 'Content',
            hintStyle: TextStyle(
              color: colorScheme.onSurfaceVariant,
            ),
            alignLabelWithHint: true,
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
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
        if (AiService.instance.isReady) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildAiChip(sl, 'aiOrganize', Icons.auto_fix_high, _organizeContent),
              _buildAiChip(sl, 'aiPolish', Icons.brush, _polishContent),
              _buildAiChip(sl, 'aiContinue', Icons.edit_note, _continueContent),
              _buildAiChip(sl, 'aiTranslate', Icons.translate, _translateContent),
              if (AiService.instance.isVisionModel)
                ActionChip(
                  avatar: _isAiProcessing
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.photo_camera, size: 14),
                  label: Text(sl.getText('aiPhotoToNote') ?? 'Photo to Note',
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _isAiProcessing ? null : _photoToNote,
                ),
              if (AiService.instance.isAudioModel)
                ActionChip(
                  avatar: _isRecording
                      ? const Icon(Icons.stop, size: 14, color: Colors.red)
                      : (_isAiProcessing
                          ? const SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.mic, size: 14)),
                  label: Text(
                      _isRecording
                          ? '${_recordingDuration}s'
                          : (sl.getText('aiVoiceToNote') ?? 'Voice to Note'),
                      style: const TextStyle(fontSize: 11)),
                  onPressed: _isAiProcessing ? null : _toggleRecording,
              ),
            ],
          ),
          if (_cachedImagePath != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant, width: 0.5),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(File(_cachedImagePath!), width: 56, height: 56, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(sl.getText('aiPhotoToNote') ?? 'Photo to Note',
                        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
                  ),
                  ActionChip(
                    avatar: _isAiProcessing
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 14),
                    label: Text(sl.getText('aiReanalyze') ?? 'Re-analyze', style: const TextStyle(fontSize: 11)),
                    onPressed: _isAiProcessing ? null : _showReanalyzePrompt,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _cachedImagePath = null),
                  ),
                ],
              ),
            ),
          ],
          if (_lastRecordingPath != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant, width: 0.5),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      _isPlaying ? Icons.stop_circle : Icons.play_circle,
                      color: colorScheme.primary,
                      size: 32,
                    ),
                    onPressed: _togglePlayback,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      sl.getText('aiVoiceToNote') ?? 'Voice to Note',
                      style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _audioPlayer.stop();
                      setState(() {
                        _lastRecordingPath = null;
                        _isPlaying = false;
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ] else if (AiService.instance.state == AiServiceState.loading) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                sl.getText('aiModelLoading') ?? 'Loading model...',
                style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _waitForModelReady() async {
    if (AiService.instance.isReady) return;
    if (AiService.instance.state == AiServiceState.loading) {
      while (AiService.instance.state == AiServiceState.loading) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (mounted) setState(() {});
    }
  }

  Widget _buildAiChip(SimpleLocalizations sl, String key, IconData icon, VoidCallback onTap) {
    return ActionChip(
      avatar: _isAiProcessing
          ? const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon, size: 14),
      label: Text(sl.getText(key) ?? key, style: const TextStyle(fontSize: 11)),
      onPressed: (_isAiProcessing || _contentCtl.text.trim().isEmpty)
          ? null
          : onTap,
    );
  }

  void _runAiAction(String systemPrompt, {int maxLength = 1000}) {
    if (!AiService.instance.isReady) return;
    final rawText = _contentCtl.text.trim();
    if (rawText.isEmpty) return;

    setState(() => _isAiProcessing = true);

    final effectiveMax = (rawText.length * 2).clamp(200, maxLength);
    final buffer = StringBuffer();
    _aiStreamSub?.cancel();
    _aiStreamSub = AiService.instance
        .completeStreamNoThink(systemPrompt, rawText,
            maxLength: effectiveMax)
        .listen(
      (token) {
        buffer.write(token);
        if (mounted) {
          setState(() => _contentCtl.text = buffer.toString());
          _contentCtl.selection = TextSelection.collapsed(
              offset: _contentCtl.text.length);
        }
      },
      onDone: () {
        if (mounted) setState(() => _isAiProcessing = false);
      },
      onError: (_) {
        if (mounted) setState(() => _isAiProcessing = false);
      },
    );
  }

  void _organizeContent() {
    _runAiAction(AiPrompts.organize());
  }

  void _polishContent() {
    _runAiAction(AiPrompts.polish());
  }

  void _continueContent() {
    _runAiAction(AiPrompts.continueWriting());
  }

  void _translateContent() {
    _runAiAction(AiPrompts.translate);
  }

  void _photoToNote() async {
    if (!AiService.instance.isReady) return;
    final sl = SimpleLocalizations.of(context)!;

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: Text(sl.getText('aiCamera') ?? 'Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(sl.getText('aiGallery') ?? 'Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picker = ImagePicker();
    final XFile? image = await picker.pickImage(
        source: source, imageQuality: 85, maxWidth: 1024);
    if (image == null) return;

    setState(() => _isAiProcessing = true);

    try {
      final result = await AiService.instance.completeMultimodal(
        AiPrompts.imageToNote(),
        image.path,
        null,
      );
      if (mounted) {
        setState(() {
          _cachedImagePath = image.path;
          _contentCtl.text = result;
          _contentCtl.selection =
              TextSelection.collapsed(offset: result.length);
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _isAiProcessing = false);
  }

  void _showReanalyzePrompt() {
    final promptCtl = TextEditingController(
      text: 'Analyze this image and generate well-structured note content.',
    );
    final sl = SimpleLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom,
          left: 16, right: 16, top: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: promptCtl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: sl.getText('aiEditPrompt') ?? 'Edit prompt',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: Text(sl.getText('aiRunPrompt') ?? 'Run'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _runReanalyze(promptCtl.text);
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _runReanalyze(String prompt) async {
    if (!AiService.instance.isReady || _cachedImagePath == null) return;
    setState(() => _isAiProcessing = true);
    try {
      final result = await AiService.instance.completeMultimodal(
        '$prompt ${AiService.instance.contextInfo}',
        _cachedImagePath!,
        null,
      );
      if (mounted) {
        setState(() {
          _contentCtl.text = result;
          _contentCtl.selection = TextSelection.collapsed(offset: result.length);
        });
      }
    } catch (_) {}
    if (mounted) setState(() => _isAiProcessing = false);
  }

  void _toggleRecording() async {
    if (!AiService.instance.isReady) return;

    if (_isRecording) {
      final path = await _recorder.stop();
      setState(() {
        _isRecording = false;
        _recordingDuration = 0;
      });
      if (path == null) return;
      setState(() {
        _isAiProcessing = true;
        _lastRecordingPath = path;
      });
      try {
        final result = await AiService.instance.completeAudio(
          AiPrompts.transcribeAudio(),
          path,
          null,
        );
        if (mounted) {
          final existing = _contentCtl.text;
          _contentCtl.text =
              existing.isEmpty ? result : '$existing\n$result';
          _contentCtl.selection =
              TextSelection.collapsed(offset: _contentCtl.text.length);
        }
      } catch (_) {}
      if (mounted) setState(() => _isAiProcessing = false);
    } else {
      if (!await _recorder.hasPermission()) return;
      final dir = await getTemporaryDirectory();
      _recordingPath =
          '${dir.path}/voice_note_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _recordingPath!,
      );
      setState(() {
        _isRecording = true;
        _recordingDuration = 0;
      });
      _tickRecordingDuration();
    }
  }

  void _tickRecordingDuration() async {
    while (_isRecording && mounted) {
      await Future.delayed(const Duration(seconds: 1));
      if (_isRecording && mounted) {
        setState(() => _recordingDuration++);
      }
    }
  }

  void _togglePlayback() async {
    if (_lastRecordingPath == null) return;
    if (_isPlaying) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _isPlaying = false);
    } else {
      try {
        await _audioPlayer.setFilePath(_lastRecordingPath!);
        setState(() => _isPlaying = true);
        _audioPlayer.play();
        _playerStateSub?.cancel();
        _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
          if (state.processingState == ProcessingState.completed && mounted) {
            setState(() => _isPlaying = false);
          }
        });
      } catch (_) {
        if (mounted) setState(() => _isPlaying = false);
      }
    }
  }


  Widget _buildSaveButton(ColorScheme colorScheme, SimpleLocalizations sl) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        icon: const Icon(Icons.save, size: 20),
        label: Text(
          sl.getText('saveLabel') ?? 'Save',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          elevation: 0,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
          ),
        ),
        onPressed: () => _handleSave(sl, colorScheme),
      ),
    );
  }

  void _handleSave(SimpleLocalizations sl, ColorScheme colorScheme) async {
    if (_titleCtl.value.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: colorScheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  sl.getText('titleRequired') ?? 'Title is required',
                  style: TextStyle(color: colorScheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: colorScheme.primaryContainer,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.zero,
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      );
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(colorScheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Saving...',
              style: TextStyle(color: colorScheme.onPrimaryContainer),
            ),
          ],
        ),
        duration: const Duration(milliseconds: 800),
        behavior: SnackBarBehavior.floating,
        backgroundColor: colorScheme.primaryContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
        ),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    );

    final sequence = -DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.addNote(Note(
      title: _titleCtl.value.text,
      content: _contentCtl.value.text,
      sequence: sequence,
      isDone: false,
      targetDate: _datetime,
    ));

    await Future.delayed(const Duration(milliseconds: 300));
    NavigationHelper.replaceTo(context, NoteLanding.routeName);

    setState(() {
      _datetime = DateTime.now().add(const Duration(days: 1));
    });
  }
}
