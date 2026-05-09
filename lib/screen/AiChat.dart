import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/ChatMessage.dart';
import '../model/Note.dart';
import '../service/AiPrompts.dart';
import '../service/AiService.dart';
import '../service/McpService.dart';
import '../service/NoteAccessSqlite.dart';
import '../utils/NavigationHelper.dart';
import '../utils/MarkdownParser.dart';
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
  bool _conversationHasTools = false;
  StreamSubscription? _streamSub;

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingDuration = 0;
  Timer? _recordingTimer;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingAudioPath;
  final Map<String, bool> _expandedAudioTranscripts = {};

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
    _streamSub?.cancel();
    _conversation?.dispose();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _audioPlayer.dispose();
    _inputCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording() async {
    if (!AiService.instance.isReady) return;

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

  void _toggleAudioPlayback(String audioPath) async {
    if (_playingAudioPath == audioPath) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _playingAudioPath = null);
    } else {
      try {
        await _audioPlayer.setFilePath(audioPath);
        setState(() => _playingAudioPath = audioPath);
        _audioPlayer.play();
        _audioPlayer.playerStateStream.listen((state) {
          if (state.processingState == ProcessingState.completed && mounted) {
            setState(() => _playingAudioPath = null);
          }
        });
      } catch (_) {
        if (mounted) setState(() => _playingAudioPath = null);
      }
    }
  }

  Future<void> _sendAudioMessage(String audioPath) async {
    if (_isStreaming) return;
    if (!AiService.instance.isReady) return;

    final userMsgIndex = _messages.length;
    setState(() {
      _messages.add(ChatMessage(
        role: 'user',
        content: '',
        audioPath: audioPath,
      ));
      _isStreaming = true;
    });
    _scrollToBottom();

    final assistantMsg = ChatMessage(role: 'assistant', content: '');
    setState(() => _messages.add(assistantMsg));

    try {
      final response = await AiService.instance.completeAudio(
        AiPrompts.chatAudio(),
        audioPath,
        null,
      );

      String transcription = '';
      String aiResponse = response;
      if (response.contains('[Transcription]:')) {
        final parts = response.split('\n\n');
        if (parts.length >= 2) {
          transcription = parts[0].replaceFirst('[Transcription]:', '').trim();
          aiResponse = parts.sublist(1).join('\n\n').trim();
        } else {
          transcription = response.replaceFirst('[Transcription]:', '').trim();
          aiResponse = '';
        }
      }

      if (transcription.isNotEmpty && mounted) {
        setState(() {
          _messages[userMsgIndex] = ChatMessage(
            role: 'user',
            content: transcription,
            audioPath: audioPath,
            timestamp: _messages[userMsgIndex].timestamp,
          );
        });
      }

      setState(() {
        _messages[_messages.length - 1] = ChatMessage(
          role: 'assistant',
          content: aiResponse.isNotEmpty ? aiResponse : response,
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

  Future<void> _sendMessage() async {
    final text = _inputCtl.text.trim();
    final imagePath = _pendingImagePath;

    if (text.isEmpty && imagePath == null) return;
    if (_isStreaming) return;
    if (!AiService.instance.isReady) return;

    try {
      final mcpTools = McpService.instance.tools;
      if (_conversation != null && !_conversationHasTools && mcpTools.isNotEmpty) {
        _conversation?.dispose();
        _conversation = null;
        _conversationHasTools = false;
      }
      if (_conversation == null) {
        final mcpContext = McpService.instance.contextCache;
        final baseInstruction = _attachedNote != null
            ? '${AiService.instance.contextInfo} The user has shared a note for context:\nTitle: ${_attachedNote!.title}\nContent: ${_attachedNote!.content}\n\nHelp the user with questions about this note.'
            : '${AiService.instance.contextInfo} You are a helpful assistant.';
        final systemInstruction = mcpContext.isNotEmpty
            ? '$baseInstruction\n\nContext information:\n$mcpContext'
            : baseInstruction;
        _conversation = await AiService.instance.createChatConversation(
          systemInstruction: systemInstruction,
          tools: mcpTools,
        );
        _conversationHasTools = mcpTools.isNotEmpty;
      }
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
        final response = await AiService.instance.completeMultimodal(
          AiPrompts.chatImage(),
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
      await _sendTextWithToolSupport(text, assistantMsg);
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

  Future<void> _sendTextWithToolSupport(
      String text, ChatMessage assistantMsg) async {
    if (_conversation == null) return;
    if (!McpService.instance.isEnabled || McpService.instance.tools.isEmpty) {
      final buffer = StringBuffer();
      final completer = Completer<void>();
      _streamSub = _conversation!.sendMessageStream(text).listen(
        (token) {
          if (!mounted) return;
          buffer.write(token.text);
          final parsed = _parseThinking(buffer.toString());
          setState(() {
            _messages[_messages.length - 1] = ChatMessage(
              role: 'assistant',
              content: parsed['content']!,
              thinkingContent:
                  parsed['thinking']!.isEmpty ? null : parsed['thinking'],
              timestamp: assistantMsg.timestamp,
            );
          });
          _scrollToBottom();
        },
        onError: (e) {
          if (mounted) {
            setState(() {
              _messages[_messages.length - 1] = ChatMessage(
                role: 'assistant',
                content: 'Error: $e',
                timestamp: assistantMsg.timestamp,
              );
              _isStreaming = false;
            });
          }
          if (!completer.isCompleted) completer.complete();
        },
        onDone: () {
          if (mounted) setState(() => _isStreaming = false);
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );
      await completer.future;
      _streamSub = null;
      return;
    }

    String currentText = text;
    int maxToolRounds = 5;
    while (maxToolRounds-- > 0) {
      LiteLmMessage response;
      try {
        response = await _conversation!.sendMessage(currentText);
      } catch (e) {
        if (mounted) {
          setState(() {
            _messages[_messages.length - 1] = ChatMessage(
              role: 'assistant',
              content: 'Error: $e',
              timestamp: assistantMsg.timestamp,
            );
            _isStreaming = false;
          });
        }
        return;
      }

      if (response.toolCalls.isEmpty) {
        final parsed = _parseThinking(response.text);
        if (mounted) {
          setState(() {
            _messages[_messages.length - 1] = ChatMessage(
              role: 'assistant',
              content: parsed['content']!,
              thinkingContent:
                  parsed['thinking']!.isEmpty ? null : parsed['thinking'],
              timestamp: assistantMsg.timestamp,
            );
            _isStreaming = false;
          });
        }
        return;
      }

      for (final toolCall in response.toolCalls) {
        final toolName = toolCall.name;
        final toolArgs = toolCall.arguments;

        if (mounted) {
          setState(() {
            _messages[_messages.length - 1] = ChatMessage(
              role: 'assistant',
              content: toolName,
              timestamp: assistantMsg.timestamp,
              messageType: MessageType.toolCall,
            );
            _messages.add(ChatMessage(role: 'assistant', content: ''));
          });
          _scrollToBottom();
        }

        String toolResult;
        try {
          toolResult = await McpService.instance.callTool(toolName, toolArgs);
        } catch (e) {
          toolResult = 'Error calling $toolName: $e';
        }

        if (mounted) {
          setState(() {
            final idx = _messages.length - 2;
            _messages[idx] = ChatMessage(
              role: 'assistant',
              content: '$toolName\n$toolResult',
              timestamp: assistantMsg.timestamp,
              messageType: MessageType.toolResult,
            );
          });
          _scrollToBottom();
        }

        try {
          final continuation =
              await _conversation!.sendToolResponse(toolName, toolResult);
          if (continuation.toolCalls.isEmpty && continuation.text.isNotEmpty) {
            final parsed = _parseThinking(continuation.text);
            if (mounted) {
              setState(() {
                _messages[_messages.length - 1] = ChatMessage(
                  role: 'assistant',
                  content: parsed['content']!,
                  thinkingContent:
                      parsed['thinking']!.isEmpty ? null : parsed['thinking'],
                  timestamp: assistantMsg.timestamp,
                );
                _isStreaming = false;
              });
            }
            return;
          }
          currentText = '';
        } catch (_) {
          currentText = '';
        }
      }
    }

    if (mounted) setState(() => _isStreaming = false);
  }

  Map<String, String> _parseThinking(String raw) {
    final thinkStart = raw.indexOf('<think>');
    if (thinkStart == -1) {
      return {'thinking': '', 'content': raw};
    }
    final thinkEnd = raw.indexOf('</think>');
    if (thinkEnd == -1) {
      final thinking = raw.substring(thinkStart + 7);
      final before = raw.substring(0, thinkStart).trim();
      return {'thinking': thinking, 'content': before};
    }
    final thinking = raw.substring(thinkStart + 7, thinkEnd);
    final content = raw.substring(0, thinkStart).trim() +
        raw.substring(thinkEnd + 8).trim();
    return {'thinking': thinking, 'content': content.trim()};
  }

  void _pickImage() async {
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

    setState(() => _pendingImagePath = image.path);
  }

  void _clearChat() {
    _conversation?.dispose();
    _conversation = null;
    _conversationHasTools = false;
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
        _conversationHasTools = false;
        setState(() => _attachedNote = note);
      }
    });
  }

  Widget _buildSettingsSectionHeader(BuildContext context, String title,
      {Widget? trailing}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
        ),
        if (trailing != null) ...[const Spacer(), trailing],
      ],
    );
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
    bool dialogActive = true;
    bool showModelList = false;

    String mcpUrl = McpService.instance.serverUrl;
    String mcpToken = McpService.instance.authHeader;
    bool mcpEnabled = McpService.instance.enabled;
    bool isMcpFetching = false;
    final mcpUrlCtl = TextEditingController(text: mcpUrl);
    final mcpTokenCtl = TextEditingController(text: mcpToken);

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
        builder: (ctx, rawSetDialogState) {
          void setDialogState(VoidCallback fn) {
            if (!dialogActive) return;
            rawSetDialogState(fn);
          }
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
                            _conversation?.dispose();
                            _conversation = null;
                            _conversationHasTools = false;
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
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            contentPadding: EdgeInsets.zero,
            title: Text(sl.getText('aiSettings') ?? 'AI Settings'),
            content: SizedBox(
              width: double.maxFinite,
              height: MediaQuery.of(ctx).size.height * 0.75,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  // ── Section 1: Model & Inference ──────────────────────
                  _buildSettingsSectionHeader(
                      ctx, sl.getText('aiModelInference') ?? 'Model & Inference'),
                  const SizedBox(height: 8),

                  // Load model button + status
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: isInitializing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.smart_toy, size: 16),
                          label: Text(
                            isInitializing
                                ? (sl.getText('aiModelLoading') ?? 'Loading...')
                                : AiService.instance.isReady
                                    ? (sl.getText('aiModelReady') ?? 'Ready')
                                    : (sl.getText('aiModelNotSet') ?? 'Not configured'),
                            style: const TextStyle(fontSize: 13),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AiService.instance.isReady
                                ? Theme.of(ctx).colorScheme.primaryContainer
                                : null,
                          ),
                          onPressed: (isInitializing || isDownloading)
                              ? null
                              : () async {
                                  if (!AiService.instance.isReady &&
                                      AiService.instance.modelPath.isNotEmpty) {
                                    setDialogState(() => isInitializing = true);
                                    await AiService.instance.initialize();
                                    setDialogState(() => isInitializing = false);
                                  }
                                },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Device RAM info
                  if (deviceRamGB != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          const Icon(Icons.memory, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            '${sl.getText('aiDeviceRam') ?? 'RAM'}: ${deviceRamGB.toStringAsFixed(1)} GB',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),

                  // Download progress
                  if (isDownloading)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: downloadProgress),
                        const SizedBox(height: 4),
                        Text(
                          '${(downloadProgress * 100).toStringAsFixed(1)}%',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  if (downloadError != null)
                    Text(downloadError!,
                        style: const TextStyle(fontSize: 11, color: Colors.red)),

                  // Current model + switch button
                  if (hasModel && !showModelList) ...[
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.smart_toy_outlined, size: 20),
                      title: Text(
                          AiService.instance.modelPath.split('/').last,
                          style: const TextStyle(fontSize: 12)),
                      subtitle: Text(modelSizeText,
                          style: const TextStyle(fontSize: 11)),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.swap_horiz, size: 14),
                      label: Text(
                        sl.getText('aiSwitchModel') ?? 'Switch Model',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: (isInitializing || isDownloading)
                          ? null
                          : () => setDialogState(() => showModelList = true),
                    ),
                  ],

                  if (!hasModel || showModelList) ...[
                    if (showModelList)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          sl.getText('aiSelectModel') ?? 'Select a model',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ...AiService.availableModels.map(buildModelListItem),
                    const SizedBox(height: 8),
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
                                sl.getText('aiDownloadModel') ?? 'Download Model',
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
                                    _conversation?.dispose();
                                    _conversation = null;
                                    _conversationHasTools = false;
                                    final stream = hasModel
                                        ? AiService.instance.switchModel(model)
                                        : AiService.instance.downloadModel(model);
                                    downloadSub = stream.listen(
                                      (progress) => setDialogState(
                                          () => downloadProgress = progress),
                                      onDone: () async {
                                        WakelockPlus.disable();
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
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            icon: const Icon(Icons.open_in_new, size: 14),
                            label: Text(
                              sl.getText('aiBrowseModels') ?? 'Browse available models',
                              style: const TextStyle(fontSize: 11),
                            ),
                            onPressed: () {
                              launchUrl(
                                Uri.parse('https://huggingface.co/models?library=litert-lm'),
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
                                final result = await FilePicker.pickFiles(
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
                                    modelSizeText = '${gb.toStringAsFixed(2)} GB';
                                    showModelList = false;
                                  });
                                }
                              },
                      ),
                    ),
                  ],

                  // Backend selector
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(sl.getText('aiBackend') ?? 'Backend',
                          style: const TextStyle(fontSize: 13)),
                      const Spacer(),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'gpu', label: Text('GPU')),
                          ButtonSegment(value: 'cpu', label: Text('CPU')),
                        ],
                        selected: {selectedBackend},
                        onSelectionChanged: (isDownloading || isInitializing)
                            ? null
                            : (vals) {
                                setDialogState(() => selectedBackend = vals.first);
                              },
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),

                  // AI Output Language
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(sl.getText('aiOutputLanguage') ?? 'AI Language',
                          style: const TextStyle(fontSize: 13)),
                      const Spacer(),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'zh', label: Text('中文')),
                          ButtonSegment(value: 'en', label: Text('EN')),
                        ],
                        selected: {selectedLanguage},
                        onSelectionChanged: (vals) {
                          setDialogState(() => selectedLanguage = vals.first);
                          AiService.instance.setLanguage(vals.first);
                        },
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),

                  const Divider(height: 24),

                  // ── Section 2: MCP Tools ───────────────────────────────
                  _buildSettingsSectionHeader(
                      ctx, sl.getText('mcpTools') ?? 'MCP Tools',
                      trailing: Switch(
                        value: mcpEnabled,
                        onChanged: (v) async {
                          setDialogState(() => mcpEnabled = v);
                          await McpService.instance.saveConfig(enabled: v);
                        },
                      )),
                  const SizedBox(height: 8),

                  TextField(
                    controller: mcpUrlCtl,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      labelText: sl.getText('mcpServerUrl') ?? 'Server URL',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => mcpUrl = v,
                    onEditingComplete: () async {
                      await McpService.instance.saveConfig(url: mcpUrl);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: mcpTokenCtl,
                    style: const TextStyle(fontSize: 13),
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: sl.getText('mcpAuthToken') ?? 'Bearer Token',
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => mcpToken = v,
                    onEditingComplete: () async {
                      await McpService.instance.saveConfig(token: mcpToken);
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        McpService.instance.isReady
                            ? Icons.check_circle_outline
                            : isMcpFetching
                                ? Icons.sync
                                : Icons.radio_button_unchecked,
                        size: 14,
                        color: McpService.instance.isReady
                            ? Colors.green
                            : Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        McpService.instance.isReady
                            ? (sl.getText('mcpReady') ?? 'Ready')
                            : isMcpFetching
                                ? (sl.getText('mcpFetching') ?? 'Fetching...')
                                : (sl.getText('mcpNotConfigured') ?? 'Not configured'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: isMcpFetching
                            ? null
                            : () async {
                                await McpService.instance.saveConfig(
                                    url: mcpUrl, token: mcpToken);
                                setDialogState(() => isMcpFetching = true);
                                await McpService.instance.fetchContextOnModelReady();
                                _conversation?.dispose();
                                _conversation = null;
                                _conversationHasTools = false;
                                if (ctx.mounted) {
                                  setDialogState(() => isMcpFetching = false);
                                }
                              },
                        child: Text(
                          sl.getText('mcpFetchNow') ?? 'Fetch Now',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),

                  const Divider(height: 24),

                  // ── Section 3: Conversation ────────────────────────────
                  _buildSettingsSectionHeader(
                      ctx, sl.getText('aiConversation') ?? 'Conversation'),
                  const SizedBox(height: 8),

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: Text(
                        sl.getText('aiClearChat') ?? 'Clear',
                        style: const TextStyle(fontSize: 13),
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _clearChat();
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  downloadSub?.cancel();
                  WakelockPlus.disable();
                  Navigator.of(ctx).pop();
                  setState(() {});
                },
                child: Text(sl.getText('cancelLabel') ?? 'Close'),
              ),
            ],
          );
        },
      ),
    );
    dialogActive = false;
    urlCtl.dispose();
    mcpUrlCtl.dispose();
    mcpTokenCtl.dispose();
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
          titleSpacing: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () =>
                NavigationHelper.replaceTo(context, NoteLanding.routeName),
          ),
          title: Text(sl.getText('aiChat') ?? 'AI Chat'),
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
                        _conversationHasTools = false;
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
                              color: colorScheme.primary.withValues(alpha: 0.4)),
                          const SizedBox(height: 16),
                          Text(
                            sl.getText('aiInputHint') ?? 'Ask anything...',
                            style: TextStyle(
                              fontSize: 16,
                              color: colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (AiService.instance.isReady) ...[
                            const SizedBox(height: 6),
                            Text(
                              AiService.instance.modelPath.split('/').last.replaceAll('.litertlm', ''),
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              _buildSuggestionChip(
                                  sl.getText('aiSummarize') ?? 'Summarize',
                                  Icons.summarize,
                                  colorScheme),
                              _buildSuggestionChip(
                                  sl.getText('aiTranslate') ?? 'Translate',
                                  Icons.translate,
                                  colorScheme),
                              _buildSuggestionChip(
                                  sl.getText('aiOrganize') ?? 'Organize',
                                  Icons.auto_fix_high,
                                  colorScheme),
                            ],
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollCtl,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 12),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) {
                          final msg = _messages[i];
                          if (msg.messageType == MessageType.toolCall ||
                              msg.messageType == MessageType.toolResult) {
                            return _buildToolBubble(msg, colorScheme);
                          }
                          return _buildMessageBubble(msg, colorScheme);
                        },
                    ),
            ),
            _buildInputBar(colorScheme, sl),
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String label, IconData icon, ColorScheme colorScheme) {
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: Colors.transparent,
      side: BorderSide(color: colorScheme.outlineVariant),
      onPressed: () => _inputCtl.text = label,
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, ColorScheme colorScheme) {
    final isUser = msg.role == 'user';
    final isThinking = !isUser &&
        msg.content.isEmpty &&
        msg.thinkingContent == null &&
        _isStreaming;
    final sl = SimpleLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 12,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(Icons.auto_awesome,
                  size: 12, color: colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Card(
              elevation: 0,
              color: isUser
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                side: isUser
                    ? BorderSide.none
                    : BorderSide(
                        color: colorScheme.primary.withValues(alpha: 0.3),
                        width: 0.5),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (msg.audioPath != null) ...[
                      GestureDetector(
                        onTap: () => _toggleAudioPlayback(msg.audioPath!),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _playingAudioPath == msg.audioPath
                                  ? Icons.stop_circle
                                  : Icons.play_circle,
                              size: 24,
                              color: isUser
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              sl.getText('aiVoiceMessage') ?? 'Voice Message',
                              style: TextStyle(
                                fontSize: 12,
                                fontStyle: FontStyle.italic,
                                color: isUser
                                    ? colorScheme.onPrimaryContainer
                                        .withValues(alpha: 0.7)
                                    : colorScheme.onSurface
                                        .withValues(alpha: 0.7),
                              ),
                            ),
                            if (isUser && msg.content.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => setState(() {
                                  _expandedAudioTranscripts[msg.audioPath!] =
                                      !(_expandedAudioTranscripts[msg.audioPath!] ?? false);
                                }),
                                child: Icon(
                                  (_expandedAudioTranscripts[msg.audioPath!] ?? false)
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                  size: 16,
                                  color: isUser
                                      ? colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                                      : colorScheme.primary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (isUser &&
                          msg.content.isNotEmpty &&
                          (_expandedAudioTranscripts[msg.audioPath!] ?? false)) ...[
                        const SizedBox(height: 6),
                        SelectableText(
                          msg.content,
                          style: TextStyle(
                            fontSize: 13,
                            color: colorScheme.onPrimaryContainer.withValues(alpha: 0.85),
                            height: 1.3,
                          ),
                        ),
                      ] else if (!isUser && msg.content.isNotEmpty) ...[
                        const SizedBox(height: 8),
                      ],
                    ],
                    if (msg.imagePath != null) ...[
                      _buildTappableImage(msg, colorScheme),
                      if (msg.content.isNotEmpty) const SizedBox(height: 8),
                    ],
                    if (isThinking)
                      _TypingDots(color: colorScheme.onSurfaceVariant)
                    else ...[
                      if (msg.thinkingContent != null &&
                          msg.thinkingContent!.isNotEmpty) ...[
                        _buildThinkingSection(
                            msg.thinkingContent!, colorScheme),
                        if (msg.content.isNotEmpty)
                          const SizedBox(height: 8),
                      ],
                      if (msg.content.isEmpty && msg.thinkingContent != null && _isStreaming)
                        _TypingDots(color: colorScheme.onSurfaceVariant)
                      else if (msg.content.isNotEmpty && !(isUser && msg.audioPath != null))
                        isUser
                            ? SelectableText(
                                msg.content,
                                style: TextStyle(
                                  color: colorScheme.onPrimaryContainer,
                                  fontSize: 14,
                                  height: 1.4,
                                ),
                              )
                            : SelectableText.rich(
                                TextSpan(
                                  children: parseMarkdown(
                                    msg.content,
                                    TextStyle(
                                      color: colorScheme.onSurface,
                                      fontSize: 14,
                                      height: 1.4,
                                    ),
                                    colorScheme,
                                  ),
                                ),
                              ),
                    ],
                    if (msg.content.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: 10,
                          color: (isUser
                                  ? colorScheme.onPrimaryContainer
                                  : colorScheme.onSurfaceVariant)
                              .withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (isUser)
            const SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _buildToolBubble(ChatMessage msg, ColorScheme colorScheme) {
    final isCall = msg.messageType == MessageType.toolCall;
    final lines = msg.content.split('\n');
    final toolName = lines.first;
    final resultText = lines.length > 1 ? lines.sublist(1).join('\n') : '';

    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 48, top: 4, bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        child: isCall
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '🔧 $toolName...',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 14, color: colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        toolName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (resultText.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      msg.isExpanded || resultText.split('\n').length <= 3
                          ? resultText
                          : '${resultText.split('\n').take(3).join('\n')}...',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.8),
                      ),
                    ),
                    if (resultText.split('\n').length > 3)
                      GestureDetector(
                        onTap: () {
                          final idx = _messages.indexOf(msg);
                          if (idx >= 0 && mounted) {
                            setState(() {
                              _messages[idx] =
                                  msg.copyWith(isExpanded: !msg.isExpanded);
                            });
                          }
                        },
                        child: Text(
                          msg.isExpanded ? '收起' : '展开',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildThinkingSection(String thinking, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.5,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 4),
          dense: true,
          initiallyExpanded: false,
          leading: Icon(Icons.psychology,
              size: 14, color: colorScheme.onSurfaceVariant),
          title: Text(
            'Thinking...',
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
          children: [
            SelectableText(
              thinking,
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTappableImage(ChatMessage msg, ColorScheme colorScheme) {
    return GestureDetector(
      onTap: () {
        if (!_isStreaming &&
            AiService.instance.isReady &&
            AiService.instance.isVisionModel) {
          setState(() => _pendingImagePath = msg.imagePath);
        }
      },
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(msg.imagePath!), width: 200, fit: BoxFit.cover),
          ),
          if (AiService.instance.isVisionModel)
            Positioned(
              right: 6,
              bottom: 6,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: colorScheme.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(12),
                ),
                child:
                    Icon(Icons.refresh, size: 14, color: colorScheme.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingImagePath != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(File(_pendingImagePath!),
                          width: 100, height: 75, fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        sl.getText('aiImageReady') ?? 'Ask about this image...',
                        style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          size: 18, color: colorScheme.onSurfaceVariant),
                      onPressed: () =>
                          setState(() => _pendingImagePath = null),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                if (AiService.instance.isReady &&
                    AiService.instance.isVisionModel)
                  IconButton(
                    onPressed: _isStreaming ? null : _pickImage,
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
                        hintText:
                            sl.getText('aiInputHint') ?? 'Ask anything...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                if (AiService.instance.isReady &&
                    AiService.instance.isAudioModel)
                  IconButton(
                    onPressed: _isStreaming ? null : _toggleRecording,
                    icon: Icon(
                      _isRecording ? Icons.stop : Icons.mic,
                      color: _isRecording ? Colors.red : colorScheme.primary,
                    ),
                  ),
                _buildSendButton(colorScheme),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSendButton(ColorScheme colorScheme) {
    final disabled = _isStreaming || !AiService.instance.isReady || _isRecording;
    return GestureDetector(
      onTap: disabled ? null : _sendMessage,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: disabled
              ? colorScheme.surfaceContainerHighest
              : colorScheme.primary,
        ),
        child: Center(
          child: _isStreaming
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onPrimary,
                  ),
                )
              : Icon(Icons.send, size: 16, color: disabled
                  ? colorScheme.onSurfaceVariant
                  : colorScheme.onPrimary),
        ),
      ),
    );
  }
}

class _TypingDots extends StatefulWidget {
  final Color color;
  const _TypingDots({required this.color});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final offset = i * 0.33;
          final t = ((_ctrl.value + offset) % 1.0);
          final scale = 0.5 + 0.5 * (t < 0.5 ? t * 2 : (1.0 - t) * 2);
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: scale),
              shape: BoxShape.circle,
            ),
          );
        }),
      ),
    );
  }
}
