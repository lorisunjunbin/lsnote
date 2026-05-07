import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/ChatMessage.dart';
import '../model/Note.dart';
import '../service/AiService.dart';
import '../service/NoteAccessSqlite.dart';
import '../utils/NavigationHelper.dart';
import 'NoteLanding.dart';

class AiChat extends StatefulWidget {
  static final String routeName = '/AiChat';

  @override
  _AiChatState createState() => _AiChatState();
}

class _AiChatState extends State<AiChat> {
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final List<ChatMessage> _messages = [];
  Note? _attachedNote;
  bool _isStreaming = false;
  String? _pendingImagePath;
  LiteLmConversation? _conversation;

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingDuration = 0;
  Timer? _recordingTimer;

  @override
  void initState() {
    super.initState();
    _checkModelReady();
  }

  void _checkModelReady() async {
    if (AiService.instance.isReady) return;
    if (AiService.instance.state == AiServiceState.loading) {
      while (AiService.instance.state == AiServiceState.loading) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recorder.dispose();
    _conversation?.dispose();
    _inputCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (!AiService.instance.isReady) return;
    if (!AiService.instance.isAudioModel) {
      _showAudioModelHint();
      return;
    }

    if (_isRecording) {
      _recordingTimer?.cancel();
      final path = await _recorder.stop();
      if (path == null || !mounted) return;
      setState(() {
        _isRecording = false;
        _recordingDuration = 0;
      });
      _sendAudioMessage(path);
    } else {
      if (!await _recorder.hasPermission()) return;
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/voice_chat_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      setState(() {
        _isRecording = true;
        _recordingDuration = 0;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingDuration++);
      });
    }
  }

  Future<void> _sendAudioMessage(String audioPath) async {
    if (_isStreaming) return;
    if (!AiService.instance.isReady) return;

    final sl = SimpleLocalizations.of(context)!;
    setState(() {
      _messages.add(ChatMessage(
        role: 'user',
        content: sl.getText('aiVoiceMessage') ?? 'Voice Message',
        audioPath: audioPath,
      ));
      _isStreaming = true;
    });
    _scrollToBottom();

    final assistantMsg = ChatMessage(role: 'assistant', content: '');
    setState(() => _messages.add(assistantMsg));

    try {
      final systemPrompt =
          '${AiService.instance.contextInfo} You are a helpful assistant. Transcribe the audio accurately and respond to the user.';
      final response = await AiService.instance.completeAudio(
        systemPrompt,
        audioPath,
        null,
      );
      setState(() {
        _messages[_messages.length - 1] = ChatMessage(
          role: 'assistant',
          content: response,
          timestamp: assistantMsg.timestamp,
        );
      });
    } catch (e) {
      setState(() {
        _messages[_messages.length - 1] = ChatMessage(
          role: 'assistant',
          content: 'Error: $e',
          timestamp: assistantMsg.timestamp,
        );
      });
    } finally {
      setState(() => _isStreaming = false);
    }
    _scrollToBottom();
  }

  void _showAudioModelHint() {
    final sl = SimpleLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sl.getText('aiAudioNotSupported') ??
              'Current model does not support audio. Switch to an audio model?',
          style: TextStyle(color: colorScheme.onPrimaryContainer),
        ),
        backgroundColor: colorScheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: sl.getText('aiSwitchModel') ?? 'Switch',
          onPressed: () async {
            final audioModel = AiService.availableModels.firstWhere(
                (m) => m.supportsAudio,
                orElse: () => AiService.availableModels[0]);
            await for (final _ in AiService.instance.switchModel(audioModel)) {}
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  Future<void> _sendMessage() async {
    final text = _inputCtl.text.trim();
    final imagePath = _pendingImagePath;

    if (text.isEmpty && imagePath == null) return;
    if (_isStreaming) return;
    if (!AiService.instance.isReady) return;

    try {
      _conversation ??= await AiService.instance.createChatConversation(
        systemInstruction: _attachedNote != null
            ? 'The user has shared a note for context:\nTitle: ${_attachedNote!.title}\nContent: ${_attachedNote!.content}\n\nHelp the user with questions about this note.'
            : null,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
      return;
    }

    final sl = SimpleLocalizations.of(context)!;
    setState(() {
      _messages.add(ChatMessage(
        role: 'user',
        content: text.isNotEmpty
            ? text
            : (sl.getText('aiImageAnalyze') ?? 'Analyze image'),
        imagePath: imagePath,
      ));
      _isStreaming = true;
      _pendingImagePath = null;
    });
    _inputCtl.clear();
    _scrollToBottom();

    final assistantMsg = ChatMessage(role: 'assistant', content: '');
    setState(() => _messages.add(assistantMsg));

    if (imagePath != null) {
      try {
        final userText = text.isNotEmpty ? text : null;
        final systemPrompt =
            '${AiService.instance.contextInfo} You are a helpful assistant. Analyze the image and respond to the user.';
        final response = await AiService.instance.completeMultimodal(
          systemPrompt,
          imagePath,
          userText,
        );
        setState(() {
          _messages[_messages.length - 1] = ChatMessage(
            role: 'assistant',
            content: response,
            timestamp: assistantMsg.timestamp,
          );
        });
      } catch (e) {
        setState(() {
          _messages[_messages.length - 1] = ChatMessage(
            role: 'assistant',
            content: 'Error: $e',
            timestamp: assistantMsg.timestamp,
          );
        });
      } finally {
        setState(() => _isStreaming = false);
      }
    } else {
      try {
        final buffer = StringBuffer();
        await for (final token in _conversation!.sendMessageStream(text)) {
          buffer.write(token.text);
          setState(() {
            _messages[_messages.length - 1] = ChatMessage(
              role: 'assistant',
              content: buffer.toString(),
              timestamp: assistantMsg.timestamp,
            );
          });
          _scrollToBottom();
        }
      } catch (e) {
        setState(() {
          _messages[_messages.length - 1] = ChatMessage(
            role: 'assistant',
            content: 'Error: $e',
            timestamp: assistantMsg.timestamp,
          );
        });
      } finally {
        setState(() => _isStreaming = false);
      }
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtl.hasClients) {
        _scrollCtl.animateTo(
          _scrollCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _pickImage() async {
    if (!AiService.instance.isReady) return;
    if (!AiService.instance.isVisionModel) {
      _showVisionModelHint();
      return;
    }
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

    setState(() => _pendingImagePath = image.path);
  }

  void _showVisionModelHint() {
    final sl = SimpleLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sl.getText('aiVisionNotSupported') ??
              'Current model does not support images. Switch to a vision model?',
          style: TextStyle(color: colorScheme.onPrimaryContainer),
        ),
        backgroundColor: colorScheme.primaryContainer,
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: sl.getText('aiSwitchModel') ?? 'Switch',
          onPressed: () async {
            final visionModel = AiService.availableModels.firstWhere(
                (m) => m.supportsVision,
                orElse: () => AiService.availableModels[0]);
            await for (final _ in AiService.instance.switchModel(visionModel)) {}
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  void _clearChat() {
    _conversation?.dispose();
    _conversation = null;
    setState(() {
      _messages.clear();
      _attachedNote = null;
    });
  }

  Future<void> _showNotePickerDialog() async {
    final notes = await db.getNotesAll();
    if (!mounted) return;

    final sl = SimpleLocalizations.of(context)!;

    showDialog<Note>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(sl.getText('aiSelectNote') ?? 'Select a note'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: notes.length,
            itemBuilder: (ctx, i) => ListTile(
              title: Text(notes[i].title ?? ''),
              subtitle: Text(
                notes[i].content ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.of(ctx).pop(notes[i]),
            ),
          ),
        ),
      ),
    ).then((note) {
      if (note != null) {
        _conversation?.dispose();
        _conversation = null;
        setState(() => _attachedNote = note);
      }
    });
  }

  Future<void> _showSettingsDialog() async {
    final sl = SimpleLocalizations.of(context)!;
    String selectedBackend = AiService.instance.backend;
    String selectedLanguage = AiService.instance.language;
    bool isInitializing = false;
    bool isDownloading = false;
    double downloadProgress = 0.0;
    String? downloadError;
    StreamSubscription<double>? downloadSub;
    String modelSizeText = '';
    bool showModelList = false;

    final recommendedModel = await AiService.getRecommendedModel();
    final deviceRamGB = await AiService.getDeviceRamGB();
    final downloadedModels = await AiService.instance.getDownloadedModels();
    final downloadedFileNames = downloadedModels.map((m) => m.fileName).toSet();

    final urlCtl = TextEditingController();

    final bytes = await AiService.instance.modelFileSize;
    if (bytes > 0) {
      final gb = bytes / (1024 * 1024 * 1024);
      modelSizeText = '${gb.toStringAsFixed(2)} GB';
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final hasModel = AiService.instance.modelPath.isNotEmpty;

          Widget buildModelListItem(AiModelInfo model) {
            final isRecommended = model == recommendedModel;
            final isCurrentModel = hasModel &&
                AiService.instance.modelPath.endsWith(model.fileName);
            final isDownloaded = downloadedFileNames.contains(model.fileName);
            final insufficientRam =
                deviceRamGB != null && deviceRamGB < model.minRamGB;

            Widget trailing;
            if (isCurrentModel) {
              trailing = Text(sl.getText('aiModelReady') ?? 'In use',
                  style: const TextStyle(fontSize: 10, color: Colors.green));
            } else if (isDownloaded) {
              trailing = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.swap_horiz, size: 20),
                    tooltip: sl.getText('aiSwitchModel') ?? 'Switch',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: (isDownloading || isInitializing)
                        ? null
                        : () async {
                            setDialogState(() => isInitializing = true);
                            await AiService.instance.activateModel(model);
                            final newBytes =
                                await AiService.instance.modelFileSize;
                            final gb = newBytes / (1024 * 1024 * 1024);
                            setDialogState(() {
                              isInitializing = false;
                              modelSizeText = '${gb.toStringAsFixed(2)} GB';
                              showModelList = false;
                            });
                          },
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        size: 18, color: Colors.red[400]),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: (isDownloading || isInitializing)
                        ? null
                        : () async {
                            final confirm = await showDialog<bool>(
                              context: ctx,
                              builder: (c) => AlertDialog(
                                title: Text(
                                    sl.getText('confirm') ?? 'Pls confirm'),
                                content: Text(
                                    '${sl.getText('aiDeleteModelConfirm') ?? 'Delete model'}: ${model.name}?'),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(c).pop(false),
                                    child: Text(sl.getText('cancelLabel') ??
                                        'Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(c).pop(true),
                                    child: Text(
                                        sl.getText('confirmYes') ?? 'YES'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await AiService.instance.deleteModelFile(model);
                              downloadedFileNames.remove(model.fileName);
                              final newBytes =
                                  await AiService.instance.modelFileSize;
                              final gb = newBytes > 0
                                  ? newBytes / (1024 * 1024 * 1024)
                                  : 0.0;
                              setDialogState(() {
                                modelSizeText = gb > 0
                                    ? '${gb.toStringAsFixed(2)} GB'
                                    : '';
                              });
                            }
                          },
                  ),
                ],
              );
            } else {
              trailing = Icon(Icons.download_outlined, size: 20,
                  color: insufficientRam ? Colors.orange[700] : null);
            }

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                dense: true,
                leading: Icon(
                  isCurrentModel
                      ? Icons.check_circle
                      : isDownloaded
                          ? Icons.smart_toy
                          : Icons.smart_toy_outlined,
                  color: isCurrentModel
                      ? Colors.green
                      : isDownloaded
                          ? Theme.of(ctx).colorScheme.primary
                          : null,
                  size: 24,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(model.name,
                          style: const TextStyle(fontSize: 13)),
                    ),
                    if (isRecommended) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(ctx).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '★ ${sl.getText('aiRecommended') ?? 'Recommended'}',
                          style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(ctx).colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  insufficientRam
                      ? '${model.size} · ≥${model.minRamGB}GB RAM · ${sl.getText('aiRamInsufficient') ?? 'Insufficient RAM'}'
                      : '${model.size} · ≥${model.minRamGB}GB RAM',
                  style: TextStyle(
                    fontSize: 11,
                    color: insufficientRam ? Colors.orange[700] : null,
                  ),
                ),
                trailing: trailing,
                onTap: (isDownloading || isInitializing || isCurrentModel || isDownloaded)
                    ? null
                    : () async {
                        if (insufficientRam) {
                          final proceed = await showDialog<bool>(
                            context: ctx,
                            builder: (c) => AlertDialog(
                              title: Text(
                                  sl.getText('aiRamInsufficient') ?? 'Insufficient RAM'),
                              content: Text(
                                  sl.getText('aiRamWarning') ?? 'This model may run slowly or fail to load on this device. Continue?'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(c).pop(false),
                                  child: Text(sl.getText('cancelLabel') ??
                                      'Cancel'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(c).pop(true),
                                  child: Text(sl.getText('confirmYes') ?? 'YES'),
                                ),
                              ],
                            ),
                          );
                          if (proceed != true) return;
                        }

                        WakelockPlus.enable();
                        setDialogState(() {
                          isDownloading = true;
                          downloadProgress = 0.0;
                          downloadError = null;
                        });

                        downloadSub = AiService.instance.downloadModel(model).listen(
                          (progress) {
                            setDialogState(
                                () => downloadProgress = progress);
                          },
                          onDone: () async {
                            WakelockPlus.disable();
                            downloadedFileNames.add(model.fileName);
                            setDialogState(() {
                              isDownloading = false;
                              isInitializing = true;
                            });
                            await AiService.instance
                                .initialize(backend: selectedBackend);
                            final newBytes =
                                await AiService.instance.modelFileSize;
                            final gb = newBytes / (1024 * 1024 * 1024);
                            setDialogState(() {
                              isInitializing = false;
                              modelSizeText =
                                  '${gb.toStringAsFixed(2)} GB';
                              showModelList = false;
                            });
                          },
                          onError: (e) {
                            WakelockPlus.disable();
                            setDialogState(() {
                              isDownloading = false;
                              downloadError = e.toString();
                            });
                          },
                        );
                      },
                ),
              );
          }

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text(sl.getText('aiSettings') ?? 'AI Settings'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Device RAM info
                  if (deviceRamGB != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.memory, size: 16),
                          const SizedBox(width: 8),
                          Text(
                            '${sl.getText('aiDeviceRam') ?? 'Device RAM'}: ${deviceRamGB.toStringAsFixed(1)} GB',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),

                  // Current model info
                  if (hasModel && !isDownloading && !showModelList) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.smart_toy_outlined),
                      title: Text(AiService.instance.modelPath.split('/').last,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(modelSizeText),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.swap_horiz, size: 16),
                        label: Text(
                          sl.getText('aiSwitchModel') ?? 'Switch Model',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: (isInitializing || isDownloading)
                            ? null
                            : () => setDialogState(() => showModelList = true),
                      ),
                    ),
                  ],

                  // Model list
                  if (!hasModel || showModelList) ...[
                    if (showModelList)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          sl.getText('aiSelectModel') ?? 'Select a model',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ...AiService.availableModels.map(buildModelListItem),
                    const SizedBox(height: 12),
                    // Custom URL (advanced)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text(
                        sl.getText('aiCustomUrl') ?? 'Custom URL',
                        style: const TextStyle(fontSize: 12),
                      ),
                      children: [
                        TextField(
                          controller: urlCtl,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            hintText:
                                'https://huggingface.co/.../xxx.litertlm?download=true',
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.download, size: 16),
                            label: Text(
                                sl.getText('aiDownloadModel') ??
                                    'Download Model',
                                style: const TextStyle(fontSize: 12)),
                            onPressed: (isInitializing || isDownloading)
                                ? null
                                : () {
                                    final url = urlCtl.text.trim();
                                    if (url.isEmpty) return;
                                    final fileName = Uri.parse(url)
                                        .pathSegments
                                        .last
                                        .split('?')
                                        .first;
                                    final model = AiModelInfo(
                                      name: fileName,
                                      fileName: fileName,
                                      downloadUrl: url,
                                      size: '',
                                      minRamGB: 0,
                                    );
                                    WakelockPlus.enable();
                                    setDialogState(() {
                                      isDownloading = true;
                                      downloadProgress = 0.0;
                                      downloadError = null;
                                    });

                                    final stream = hasModel
                                        ? AiService.instance.switchModel(model)
                                        : AiService.instance
                                            .downloadModel(model);

                                    downloadSub = stream.listen(
                                      (progress) {
                                        setDialogState(
                                            () => downloadProgress = progress);
                                      },
                                      onDone: () async {
                                        WakelockPlus.disable();
                                        setDialogState(() {
                                          isDownloading = false;
                                          isInitializing = true;
                                        });
                                        await AiService.instance.initialize(
                                            backend: selectedBackend);
                                        final newBytes = await AiService
                                            .instance.modelFileSize;
                                        final gb =
                                            newBytes / (1024 * 1024 * 1024);
                                        setDialogState(() {
                                          isInitializing = false;
                                          modelSizeText =
                                              '${gb.toStringAsFixed(2)} GB';
                                          showModelList = false;
                                        });
                                      },
                                      onError: (e) {
                                        WakelockPlus.disable();
                                        setDialogState(() {
                                          isDownloading = false;
                                          downloadError = e.toString();
                                        });
                                      },
                                    );
                                  },
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            icon: const Icon(Icons.open_in_new, size: 14),
                            label: Text(
                              sl.getText('aiBrowseModels') ??
                                  'Browse available models',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onPressed: () {
                              launchUrl(
                                Uri.parse(
                                    'https://huggingface.co/models?library=litert-lm'),
                                mode: LaunchMode.externalApplication,
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Select local file
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: Text(
                            sl.getText('aiSelectModel') ?? 'Select Local File',
                            style: const TextStyle(fontSize: 12)),
                        onPressed: (isInitializing || isDownloading)
                            ? null
                            : () async {
                                final result =
                                    await FilePicker.platform.pickFiles(
                                  type: FileType.any,
                                );
                                if (result != null &&
                                    result.files.single.path != null) {
                                  setDialogState(() => isInitializing = true);
                                  await AiService.instance.initialize(
                                    modelPath: result.files.single.path!,
                                    backend: selectedBackend,
                                  );
                                  final newBytes =
                                      await AiService.instance.modelFileSize;
                                  final gb = newBytes / (1024 * 1024 * 1024);
                                  setDialogState(() {
                                    isInitializing = false;
                                    modelSizeText =
                                        '${gb.toStringAsFixed(2)} GB';
                                    showModelList = false;
                                  });
                                }
                              },
                      ),
                    ),
                  ],

                  // Progress bar
                  if (isDownloading) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: downloadProgress),
                    const SizedBox(height: 8),
                    Text(
                      '${(downloadProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],

                  if (downloadError != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      downloadError!,
                      style: TextStyle(fontSize: 11, color: Colors.red[700]),
                    ),
                  ],
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: selectedBackend,
                    decoration: InputDecoration(
                      labelText: sl.getText('aiBackend') ?? 'Backend',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'gpu', child: Text('GPU')),
                      DropdownMenuItem(value: 'cpu', child: Text('CPU')),
                    ],
                    onChanged: (isInitializing || isDownloading)
                        ? null
                        : (value) {
                            if (value != null) {
                              selectedBackend = value;
                            }
                          },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: selectedLanguage,
                    decoration: InputDecoration(
                      labelText: sl.getText('aiOutputLanguage') ?? 'AI Language',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'zh', child: Text('中文')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        selectedLanguage = value;
                        AiService.instance.setLanguage(value);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  if (isInitializing)
                    const Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('Loading model...'),
                      ],
                    ),
                  if (!isInitializing && !isDownloading) _buildStatusRow(sl),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: (isInitializing || isDownloading)
                    ? null
                    : () {
                        downloadSub?.cancel();
                        WakelockPlus.disable();
                        Navigator.of(ctx).pop();
                        setState(() {});
                      },
                child: Text(sl.getText('confirmLabel') ?? 'OK'),
              ),
            ],
          );
        },
      ),
    );
    urlCtl.dispose();
  }

  Widget _buildStatusRow(SimpleLocalizations sl) {
    final state = AiService.instance.state;
    IconData icon;
    Color color;
    String text;

    switch (state) {
      case AiServiceState.ready:
        icon = Icons.check_circle;
        color = Colors.green;
        text = sl.getText('aiModelReady') ?? 'Model ready';
        break;
      case AiServiceState.error:
        icon = Icons.error;
        color = Colors.red;
        text = sl.getText('aiModelError') ?? 'Model failed to load';
        break;
      case AiServiceState.loading:
        icon = Icons.hourglass_empty;
        color = Colors.orange;
        text = sl.getText('aiModelLoading') ?? 'Loading...';
        break;
      case AiServiceState.uninitialized:
        icon = Icons.info_outline;
        color = Colors.grey;
        text = sl.getText('aiModelNotSet') ?? 'Not configured';
        break;
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 12)),
        ),
      ],
    );
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
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () =>
                NavigationHelper.replaceTo(context, NoteLanding.routeName),
          ),
          title: Text(sl.getText('aiChat') ?? 'AI'),
          actions: [
            IconButton(
              icon: Icon(
                Icons.attach_file,
                color: _attachedNote != null
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              tooltip: sl.getText('aiAttachNote') ?? 'Attach Note',
              onPressed: _showNotePickerDialog,
            ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: sl.getText('aiSettings') ?? 'Settings',
              onPressed: _showSettingsDialog,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: sl.getText('aiClearChat') ?? 'Clear',
              onPressed: _clearChat,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_attachedNote != null)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: colorScheme.primaryContainer.withValues(alpha: 0.3),
                child: Row(
                  children: [
                    Icon(Icons.description_outlined,
                        size: 16, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${sl.getText('aiNoteContext') ?? 'Note attached'}: ${_attachedNote!.title}',
                        style: TextStyle(
                            fontSize: 12, color: colorScheme.primary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        _conversation?.dispose();
                        _conversation = null;
                        setState(() => _attachedNote = null);
                      },
                      child: Icon(Icons.close,
                          size: 16, color: colorScheme.primary),
                    ),
                  ],
                ),
              ),
            if (!AiService.instance.isReady)
              GestureDetector(
                onTap: AiService.instance.state == AiServiceState.loading
                    ? null
                    : _showSettingsDialog,
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: AiService.instance.state == AiServiceState.loading
                      ? colorScheme.primaryContainer.withValues(alpha: 0.3)
                      : colorScheme.errorContainer.withValues(alpha: 0.3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (AiService.instance.state == AiServiceState.loading) ...[
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        AiService.instance.state == AiServiceState.loading
                            ? (sl.getText('aiModelLoading') ?? 'Loading model...')
                            : (sl.getText('aiConfigurePrompt') ?? 'Tap settings to select a model file'),
                        style: TextStyle(
                          fontSize: 12,
                          color: AiService.instance.state == AiServiceState.loading
                              ? colorScheme.primary
                              : colorScheme.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.auto_awesome,
                              size: 48,
                              color: colorScheme.onSurfaceVariant),
                          const SizedBox(height: 16),
                          Text(
                            sl.getText('aiInputHint') ?? 'Ask anything...',
                            style: TextStyle(
                                color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtl,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) =>
                          _buildMessageBubble(_messages[i], colorScheme),
                    ),
            ),
            _buildInputBar(colorScheme, sl),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, ColorScheme colorScheme) {
    final isUser = msg.role == 'user';
    final isThinking = !isUser && msg.content.isEmpty && _isStreaming;
    final sl = SimpleLocalizations.of(context)!;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? colorScheme.primary
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.audioPath != null) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mic,
                      size: 16,
                      color: isUser
                          ? colorScheme.onPrimary
                          : colorScheme.onSurface),
                  const SizedBox(width: 6),
                  Text(
                    sl.getText('aiVoiceMessage') ?? 'Voice Message',
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: isUser
                          ? colorScheme.onPrimary.withValues(alpha: 0.8)
                          : colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              if (msg.content.isNotEmpty) const SizedBox(height: 8),
            ],
            if (msg.imagePath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(msg.imagePath!),
                  width: 200,
                  fit: BoxFit.cover,
                ),
              ),
              if (msg.content.isNotEmpty) const SizedBox(height: 8),
            ],
            if (isThinking)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    sl.getText('aiThinking') ?? 'Thinking...',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              )
            else if (msg.content.isNotEmpty)
              SelectableText(
                msg.content,
                style: TextStyle(
                  color:
                      isUser ? colorScheme.onPrimary : colorScheme.onSurface,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_pendingImagePath != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(_pendingImagePath!),
                    width: 60,
                    height: 60,
                    fit: BoxFit.cover,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: colorScheme.onSurfaceVariant),
                  onPressed: () =>
                      setState(() => _pendingImagePath = null),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            border: Border(
              top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: (_isStreaming || !AiService.instance.isReady)
                    ? null
                    : _pickImage,
                icon: Icon(Icons.image, color: colorScheme.primary),
              ),
              if (_isRecording)
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.fiber_manual_record,
                            size: 12, color: Colors.red),
                        const SizedBox(width: 8),
                        Text(
                          '${_recordingDuration}s',
                          style: TextStyle(
                            color: colorScheme.onErrorContainer,
                            fontSize: 14,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          sl.getText('aiRecording') ?? 'Recording...',
                          style: TextStyle(
                            color: colorScheme.onErrorContainer,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              else
                Expanded(
                  child: TextField(
                    controller: _inputCtl,
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: sl.getText('aiInputHint') ?? 'Ask anything...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              if (AiService.instance.isReady && AiService.instance.isAudioModel)
                IconButton(
                  onPressed: _isStreaming ? null : _toggleRecording,
                  icon: Icon(
                    _isRecording ? Icons.stop : Icons.mic,
                    color: _isRecording ? Colors.red : colorScheme.primary,
                  ),
                ),
              IconButton(
                onPressed: (_isStreaming || !AiService.instance.isReady || _isRecording)
                    ? null
                    : _sendMessage,
                icon: _isStreaming
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.primary,
                        ),
                      )
                    : Icon(Icons.send, color: colorScheme.primary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
