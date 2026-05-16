import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/ChatMessage.dart';
import '../model/ChatSession.dart';
import '../model/Note.dart';
import '../service/AiPrompts.dart';
import '../service/AiService.dart';
import '../model/McpServer.dart';
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
  StreamSubscription? _playerStateSub;

  int? _currentSessionId;
  bool _isReadOnly = false;
  bool _sessionTitled = false;
  String? _historyContextCache;
  int _historyContextMsgCount = -1;

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingDuration = 0;
  Timer? _recordingTimer;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingAudioPath;
  final Map<int, List<InlineSpan>> _markdownCache = {};
  final Map<String, bool> _expandedAudioTranscripts = {};
  Timer? _streamThrottleTimer;
  bool _streamDirty = false;

  @override
  void initState() {
    super.initState();
    _checkModelReady();
    McpService.instance.onContextReady = () {
      if (mounted) setState(() {});
    };
  }

  Future<void> _ensureSession() async {
    if (_currentSessionId != null) return;
    final id = await db.createChatSession('');
    _currentSessionId = id;
  }

  Future<void> _ensureConversation() async {
    final mcpTools = McpService.instance.tools;
    if (_conversation != null && !_conversationHasTools && mcpTools.isNotEmpty) {
      _conversation?.dispose();
      _conversation = null;
      _conversationHasTools = false;
    }
    if (_conversation == null) {
      final mcpContext = McpService.instance.contextCache;
      final baseInstruction = _attachedNote != null
          ? AiPrompts.chatWithNote(_attachedNote!.title!, _attachedNote!.content!)
          : AiPrompts.chatBase();
      final toolInstruction = mcpTools.isNotEmpty
          ? AiPrompts.chatToolInstruction
          : '';
      final contextPart = mcpContext.isNotEmpty
          ? '\n\nContext information:\n$mcpContext'
          : '';
      final historyPart = _buildHistoryContext();
      final systemInstruction = '$baseInstruction$toolInstruction$contextPart$historyPart';
      _conversation = await AiService.instance.createChatConversation(
        systemInstruction: systemInstruction,
        tools: mcpTools,
      );
      _conversationHasTools = mcpTools.isNotEmpty;
    }
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
    McpService.instance.onContextReady = null;
    _streamThrottleTimer?.cancel();
    _streamSub?.cancel();
    _playerStateSub?.cancel();
    _conversation?.dispose();
    _recordingTimer?.cancel();
    _recorder.dispose();
    _audioPlayer.dispose();
    _inputCtl.dispose();
    _scrollCtl.dispose();
    if (_isStreaming) WakelockPlus.disable();
    _finalizeSession();
    super.dispose();
  }

  void _finalizeSession() {
    if (_currentSessionId == null) return;
    if (_messages.isEmpty) {
      db.deleteChatSession(_currentSessionId!);
      return;
    }
    if (_isReadOnly) return;
    _generateSessionTitle(_currentSessionId!, List.from(_messages));
  }

  Future<void> _generateSessionTitle(int sessionId, List<ChatMessage> messages) async {
    if (!AiService.instance.isReady) return;
    final textMessages = messages
        .where((m) => m.messageType == MessageType.text && m.content.isNotEmpty)
        .take(6)
        .map((m) => '${m.role == 'user' ? 'User' : 'Assistant'}: ${m.content.length > 100 ? m.content.substring(0, 100) : m.content}')
        .join('\n');
    if (textMessages.isEmpty) return;
    try {
      final buffer = StringBuffer();
      await AiService.instance.completeStream(
        AiPrompts.sessionTitle(),
        textMessages,
        maxLength: 50,
      ).forEach((token) => buffer.write(token));
      final title = buffer.toString().trim();
      if (title.isNotEmpty && title.length < 50) {
        await db.updateChatSessionTitle(sessionId, title);
      }
    } catch (_) {}
  }

  void _persistMessage(ChatMessage msg) {
    if (_isReadOnly) return;
    _ensureSession().then((_) {
      db.addChatMessage(_currentSessionId!, msg);
      if (msg.role == 'user' && !_sessionTitled) {
        _sessionTitled = true;
        final title = msg.content.length > 20
            ? msg.content.substring(0, 20)
            : msg.content;
        if (title.isNotEmpty) {
          db.updateChatSessionTitle(_currentSessionId!, title);
        }
      }
    });
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
        _playerStateSub?.cancel();
        _playerStateSub = _audioPlayer.playerStateStream.listen((state) {
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
    if (_isStreaming || _isReadOnly) return;
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

    try {
      final response = await AiService.instance.completeAudio(
        AiPrompts.chatAudio(),
        audioPath,
        null,
      );

      String transcription = '';
      if (response.contains('[Transcription]:')) {
        final parts = response.split('\n\n');
        transcription = parts[0].replaceFirst('[Transcription]:', '').trim();
      } else {
        transcription = response.trim();
      }

      if (transcription.isNotEmpty && mounted) {
        final updatedMsg = ChatMessage(
          role: 'user',
          content: transcription,
          audioPath: audioPath,
          timestamp: _messages[userMsgIndex].timestamp,
        );
        setState(() {
          _messages[userMsgIndex] = updatedMsg;
        });
        _persistMessage(updatedMsg);
      }

      setState(() => _isStreaming = false);

      if (transcription.isNotEmpty) {
        _sendTranscribedText(transcription);
      }
    } catch (e) {
      WakelockPlus.disable();
      final assistantMsg = ChatMessage(role: 'assistant', content: '');
      setState(() => _messages.add(assistantMsg));
      setState(() {
        _messages[_messages.length - 1] = ChatMessage(
          role: 'assistant',
          content: 'Error: $e',
          timestamp: assistantMsg.timestamp,
        );
        _isStreaming = false;
      });
    }
    _scrollToBottom();
  }

  Future<void> _sendTranscribedText(String text) async {
    if (_isStreaming) return;
    if (!AiService.instance.isReady) return;

    try {
      await _ensureConversation();
    } catch (e) {
      return;
    }

    setState(() => _isStreaming = true);
    WakelockPlus.enable();
    final assistantMsg = ChatMessage(role: 'assistant', content: '');
    setState(() => _messages.add(assistantMsg));
    _scrollToBottom();

    await _sendTextWithToolSupport(text, assistantMsg);
    _scrollToBottom();
  }

  Future<void> _sendMessage() async {
    final text = _inputCtl.text.trim();
    final imagePath = _pendingImagePath;

    if (text.isEmpty && imagePath == null) return;
    if (_isStreaming || _isReadOnly) return;
    if (!AiService.instance.isReady) return;

    try {
      await _ensureConversation();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
      return;
    }

    final sl = SimpleLocalizations.of(context)!;
    final userMsg = ChatMessage(
      role: 'user',
      content: text.isNotEmpty
          ? text
          : (sl.getText('aiImageAnalyze') ?? 'Analyze image'),
      imagePath: imagePath,
    );
    setState(() {
      _messages.add(userMsg);
      _isStreaming = true;
      _pendingImagePath = null;
    });
    WakelockPlus.enable();
    _persistMessage(userMsg);
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
        final finalMsg = ChatMessage(
          role: 'assistant',
          content: response,
          timestamp: assistantMsg.timestamp,
        );
        setState(() {
          _messages[_messages.length - 1] = finalMsg;
        });
        _persistMessage(finalMsg);
      } catch (e) {
        setState(() {
          _messages[_messages.length - 1] = ChatMessage(
            role: 'assistant',
            content: 'Error: $e',
            timestamp: assistantMsg.timestamp,
          );
        });
      } finally {
        WakelockPlus.disable();
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
          _streamDirty = true;
          if (_streamThrottleTimer == null || !_streamThrottleTimer!.isActive) {
            _streamThrottleTimer = Timer(const Duration(milliseconds: 80), () {
              if (!mounted || !_streamDirty) return;
              _streamDirty = false;
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
            });
          }
        },
        onError: (e) {
          _streamThrottleTimer?.cancel();
          WakelockPlus.disable();
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
          _streamThrottleTimer?.cancel();
          WakelockPlus.disable();
          if (mounted) {
            final parsed = _parseThinking(buffer.toString());
            final finalMsg = ChatMessage(
              role: 'assistant',
              content: parsed['content']!,
              thinkingContent:
                  parsed['thinking']!.isEmpty ? null : parsed['thinking'],
              timestamp: assistantMsg.timestamp,
            );
            setState(() {
              _messages[_messages.length - 1] = finalMsg;
              _isStreaming = false;
            });
            _persistMessage(finalMsg);
            _scrollToBottom();
          }
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
        WakelockPlus.disable();
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
        WakelockPlus.disable();
        if (mounted) {
          final finalMsg = ChatMessage(
            role: 'assistant',
            content: parsed['content']!,
            thinkingContent:
                parsed['thinking']!.isEmpty ? null : parsed['thinking'],
            timestamp: assistantMsg.timestamp,
          );
          setState(() {
            _messages[_messages.length - 1] = finalMsg;
            _isStreaming = false;
          });
          _persistMessage(finalMsg);
        }
        return;
      }

      for (final toolCall in response.toolCalls) {
        final toolName = toolCall.name;
        final toolArgs = toolCall.arguments;
        final serverName = McpService.instance.getServerNameForTool(toolName);
        final toolLabel = serverName != null ? '[$serverName] $toolName' : toolName;

        if (mounted) {
          setState(() {
            _messages[_messages.length - 1] = ChatMessage(
              role: 'assistant',
              content: toolLabel,
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
              content: '$toolLabel\n$toolResult',
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
              final finalMsg = ChatMessage(
                role: 'assistant',
                content: parsed['content']!,
                thinkingContent:
                    parsed['thinking']!.isEmpty ? null : parsed['thinking'],
                timestamp: assistantMsg.timestamp,
              );
              setState(() {
                _messages[_messages.length - 1] = finalMsg;
                _isStreaming = false;
              });
              _persistMessage(finalMsg);
            }
            return;
          }
          currentText = '';
        } catch (_) {
          currentText = '';
        }
      }
    }

    if (mounted) {
      WakelockPlus.disable();
      setState(() => _isStreaming = false);
    }
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
    _markdownCache.clear();
    _finalizeSession();
    setState(() {
      _messages.clear();
      _attachedNote = null;
      _isReadOnly = false;
      _currentSessionId = null;
      _sessionTitled = false;
    });
  }

  Future<void> _showHistorySheet() async {
    final sessions = await db.getChatSessions();
    if (!mounted) return;

    final sl = SimpleLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            if (sessions.isEmpty) {
              return SizedBox(
                height: 200,
                child: Center(
                  child: Text(
                    sl.getText('emptyHistory') ?? 'No chat history',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
              );
            }
            return DraggableScrollableSheet(
              initialChildSize: 0.5,
              minChildSize: 0.3,
              maxChildSize: 0.8,
              expand: false,
              builder: (ctx, scrollCtl) {
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        sl.getText('chatHistory') ?? 'Chat History',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        controller: scrollCtl,
                        itemCount: sessions.length,
                        separatorBuilder: (ctx, i) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final session = sessions[i];
                          final isCurrent = session.id == _currentSessionId;
                          return Dismissible(
                            key: ValueKey(session.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              color: colorScheme.error,
                              child: Icon(Icons.delete,
                                  color: colorScheme.onError),
                            ),
                            onDismissed: (_) {
                              db.deleteChatSession(session.id!);
                              setSheetState(() => sessions.removeAt(i));
                              if (isCurrent) {
                                _clearChat();
                              }
                            },
                            child: ListTile(
                              title: Text(
                                session.title.isNotEmpty
                                    ? session.title
                                    : '...',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                ),
                              ),
                              subtitle: Text(
                                '${_formatSessionTime(session.updatedAt)} · ${session.messageCount}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              trailing: isCurrent
                                  ? Icon(Icons.chat_bubble,
                                      size: 16, color: colorScheme.primary)
                                  : null,
                              onTap: isCurrent
                                  ? () => Navigator.pop(ctx)
                                  : () {
                                      Navigator.pop(ctx);
                                      _loadSession(session);
                                    },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _formatSessionTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _loadSession(ChatSession session) async {
    final messages = await db.getChatMessages(session.id!);
    if (!mounted) return;

    _conversation?.dispose();
    _conversation = null;
    _conversationHasTools = false;

    setState(() {
      _currentSessionId = session.id;
      _messages.clear();
      _messages.addAll(messages);
      _attachedNote = null;
      _isReadOnly = true;
    });
    _scrollToBottom();
  }

  void _continueSession() {
    _conversation?.dispose();
    _conversation = null;
    _conversationHasTools = false;
    final sl = SimpleLocalizations.of(context);
    final hint = sl?.getText('chatResumed') ?? 'Conversation resumed';
    setState(() {
      _isReadOnly = false;
      _messages.add(ChatMessage(
        role: 'system',
        content: hint,
      ));
    });
    _scrollToBottom();
  }

  String _buildHistoryContext() {
    if (_messages.isEmpty) return '';
    if (_historyContextCache != null && _historyContextMsgCount == _messages.length) {
      return _historyContextCache!;
    }
    final recent = _messages.length > 10
        ? _messages.sublist(_messages.length - 10)
        : _messages;
    final buf = StringBuffer('\n\nPrevious conversation:\n');
    for (final m in recent) {
      if (m.messageType != MessageType.text || m.role == 'system') continue;
      final role = m.role == 'user' ? 'User' : 'Assistant';
      final text = m.content.length > 200
          ? m.content.substring(0, 200)
          : m.content;
      buf.writeln('$role: $text');
    }
    _historyContextCache = buf.toString();
    _historyContextMsgCount = _messages.length;
    return _historyContextCache!;
  }

  Future<void> _showNotePickerDialog() async {
    final notes = await db.getNotesAll();
    if (!mounted) return;

    final sl = SimpleLocalizations.of(context)!;

    showDialog<Note>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(sl.getText('aiSelectNote') ?? 'Select a note'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.separated(
            itemCount: notes.length,
            separatorBuilder: (ctx, i) => const Divider(height: 1),
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

    List<McpServer> mcpServers = List<McpServer>.from(McpService.instance.servers);
    bool isMcpFetching = false;

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
                borderRadius: BorderRadius.circular(12)),
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
                      trailing: IconButton(
                        icon: const Icon(Icons.add, size: 20),
                        onPressed: () async {
                          final server = await _showMcpServerEditDialog(ctx, sl);
                          if (server != null) {
                            await McpService.instance.addServer(server);
                            setDialogState(() {
                              mcpServers = List<McpServer>.from(McpService.instance.servers);
                            });
                          }
                        },
                      )),
                  const SizedBox(height: 4),

                  if (mcpServers.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        sl.getText('mcpNotConfigured') ?? 'Not configured',
                        style: TextStyle(fontSize: 12,
                            color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                      ),
                    ),

                  ...mcpServers.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final server = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          SizedBox(
                            height: 28,
                            width: 36,
                            child: Switch(
                              value: server.enabled,
                              onChanged: (v) async {
                                await McpService.instance.toggleServer(idx, v);
                                setDialogState(() {
                                  mcpServers = List<McpServer>.from(McpService.instance.servers);
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                final edited = await _showMcpServerEditDialog(
                                    ctx, sl, server: server);
                                if (edited != null) {
                                  await McpService.instance.updateServer(idx, edited);
                                  setDialogState(() {
                                    mcpServers = List<McpServer>.from(McpService.instance.servers);
                                  });
                                }
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(server.name,
                                      style: const TextStyle(fontSize: 13,
                                          fontWeight: FontWeight.w500)),
                                  Text(server.url,
                                      style: TextStyle(fontSize: 11,
                                          color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                                      maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () async {
                              await McpService.instance.removeServer(idx);
                              setDialogState(() {
                                mcpServers = List<McpServer>.from(McpService.instance.servers);
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  }),

                  const SizedBox(height: 4),
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
                        onPressed: isMcpFetching || mcpServers.where((s) => s.enabled).isEmpty
                            ? null
                            : () async {
                                setDialogState(() => isMcpFetching = true);
                                await AiService.instance.fetchAndSummarizeContext();
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
                child: Text(sl.getText('closeLabel') ?? 'Close'),
              ),
            ],
          );
        },
      ),
    );
    dialogActive = false;
    urlCtl.dispose();
  }

  Future<McpServer?> _showMcpServerEditDialog(
      BuildContext context, SimpleLocalizations sl,
      {McpServer? server}) async {
    final nameCtl = TextEditingController(text: server?.name ?? '');
    final urlCtl = TextEditingController(text: server?.url ?? '');
    final fallbackUrlCtl = TextEditingController(text: server?.fallbackUrl ?? '');
    final tokenCtl = TextEditingController(text: server?.token ?? '');

    final result = await showDialog<McpServer>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(
          server == null
              ? (sl.getText('mcpAddServer') ?? 'Add Server')
              : (sl.getText('mcpEditServer') ?? 'Edit Server'),
          style: const TextStyle(fontSize: 15),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: sl.getText('mcpServerName') ?? 'Name',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: sl.getText('mcpServerUrl') ?? 'Server URL',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: fallbackUrlCtl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  labelText: sl.getText('mcpFallbackUrl') ?? 'Fallback URL',
                  hintText: 'Optional',
                  hintStyle: const TextStyle(fontSize: 12),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokenCtl,
                style: const TextStyle(fontSize: 13),
                obscureText: true,
                decoration: InputDecoration(
                  labelText: sl.getText('mcpAuthToken') ?? 'Bearer Token',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(sl.getText('cancelLabel') ?? 'Cancel'),
          ),
          TextButton(
            onPressed: () {
              final name = nameCtl.text.trim();
              final url = urlCtl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              Navigator.of(ctx).pop(McpServer(
                name: name,
                url: url,
                fallbackUrl: fallbackUrlCtl.text.trim(),
                token: tokenCtl.text.trim(),
                enabled: server?.enabled ?? true,
              ));
            },
            child: Text(sl.getText('saveLabel') ?? 'Save'),
          ),
        ],
      ),
    );

    return result;
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
              icon: const Icon(Icons.history),
              tooltip: sl.getText('chatHistory') ?? 'Chat History',
              onPressed: _showHistorySheet,
            ),
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
            if (AiService.instance.isReady && McpService.instance.isEnabled && McpService.instance.contextCache.isEmpty)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_sync_outlined,
                      size: 14,
                      color: colorScheme.tertiary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'MCP ${sl.getText('aiMcpFetching') ?? 'fetching context...'}',
                        style: TextStyle(
                            fontSize: 11, color: colorScheme.tertiary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _messages.isEmpty
                  ? SingleChildScrollView(
                      child: Column(
                        children: [
                          if (McpService.instance.contextCache.isNotEmpty)
                            GestureDetector(
                              onLongPress: () {
                                Clipboard.setData(ClipboardData(text: McpService.instance.contextCache));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(sl.getText('aiCopied') ?? 'Copied')),
                                );
                              },
                              child: Container(
                                width: double.infinity,
                                margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerLow,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(_weatherIcon(McpService.instance.contextCache), size: 16, color: colorScheme.primary),
                                        const SizedBox(width: 6),
                                        Text(
                                          sl.getText('aiTodayInfo') ?? 'Today',
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: colorScheme.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      McpService.instance.contextCache,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colorScheme.onSurfaceVariant,
                                        height: 1.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: 24),
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
            if (_isReadOnly)
              _buildContinueBar(colorScheme, sl)
            else
              _buildInputBar(colorScheme, sl),
          ],
        ),
      ),
    );
  }

  IconData _weatherIcon(String context) {
    final lower = context.toLowerCase();
    if (lower.contains('雪') || lower.contains('snow')) return Icons.ac_unit;
    if (lower.contains('雷') || lower.contains('thunder')) return Icons.flash_on;
    if (lower.contains('雨') || lower.contains('rain')) return Icons.water_drop_outlined;
    if (lower.contains('阴') || lower.contains('overcast')) return Icons.cloud;
    if (lower.contains('多云') || lower.contains('cloudy')) return Icons.cloud_outlined;
    if (lower.contains('雾') || lower.contains('fog')) return Icons.foggy;
    if (lower.contains('晴') || lower.contains('sunny') || lower.contains('clear')) return Icons.wb_sunny_outlined;
    return Icons.wb_sunny_outlined;
  }

  Widget _buildSuggestionChip(String label, IconData icon, ColorScheme colorScheme) {
    return ActionChip(
      avatar: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: Colors.transparent,
      side: BorderSide(color: colorScheme.outlineVariant),
      onPressed: () => _executeQuickAction(label),
    );
  }

  Widget _buildMiniActionChip(String label, IconData icon, ColorScheme colorScheme) {
    return InkWell(
      onTap: () => _executeQuickAction(label),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: colorScheme.primary),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Future<void> _executeQuickAction(String action) async {
    if (_isStreaming) return;
    if (!AiService.instance.isReady) return;

    final sl = SimpleLocalizations.of(context)!;
    final summarizeLabel = sl.getText('aiSummarize') ?? 'Summarize';
    final translateLabel = sl.getText('aiTranslate') ?? 'Translate';
    final organizeLabel = sl.getText('aiOrganize') ?? 'AI Organize';

    final inputText = _inputCtl.text.trim();
    final hasNote = _attachedNote != null &&
        (_attachedNote!.content ?? '').trim().isNotEmpty;
    final hasInput = inputText.isNotEmpty;

    String content;
    String systemPrompt;

    if (hasNote && hasInput) {
      // 输入框内容作为额外指令，笔记作为操作对象
      content = '${_attachedNote!.content}\n\nUser instruction: $inputText';
      if (action == summarizeLabel) {
        systemPrompt = AiPrompts.summarize();
      } else if (action == translateLabel) {
        systemPrompt = AiPrompts.translate;
      } else {
        systemPrompt = AiPrompts.landingOrganize();
      }
    } else if (hasNote) {
      // 只有笔记，对笔记内容执行操作
      content = _attachedNote!.content!;
      if (action == summarizeLabel) {
        systemPrompt = AiPrompts.summarize();
      } else if (action == translateLabel) {
        systemPrompt = AiPrompts.translate;
      } else {
        systemPrompt = AiPrompts.landingOrganize();
      }
    } else if (hasInput) {
      // 只有输入框内容，对输入框内容执行操作
      content = inputText;
      if (action == summarizeLabel) {
        systemPrompt = AiPrompts.summarize();
      } else if (action == translateLabel) {
        systemPrompt = AiPrompts.translate;
      } else {
        systemPrompt = AiPrompts.landingOrganize();
      }
    } else {
      // 无内容
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sl.getText('aiNoContent') ?? 'Please enter text or attach a note'),
        ),
      );
      return;
    }

    // Dispose existing conversation — LiteRT-LM only allows one at a time
    _conversation?.dispose();
    _conversation = null;
    _conversationHasTools = false;

    await _ensureSession();

    final displayText = hasInput ? '$action: $inputText' : action;
    final userMsg = ChatMessage(role: 'user', content: displayText);
    setState(() {
      _messages.add(userMsg);
      _isStreaming = true;
    });
    WakelockPlus.enable();
    _persistMessage(userMsg);
    _inputCtl.clear();
    _scrollToBottom();

    final assistantMsg = ChatMessage(role: 'assistant', content: '');
    setState(() => _messages.add(assistantMsg));

    final buffer = StringBuffer();
    try {
      final completer = Completer<void>();
      _streamSub = AiService.instance
          .completeStream(systemPrompt, content)
          .listen(
        (token) {
          if (!mounted) return;
          buffer.write(token);
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
        onDone: () {
          WakelockPlus.disable();
          if (mounted) {
            final parsed = _parseThinking(buffer.toString());
            final finalMsg = ChatMessage(
              role: 'assistant',
              content: parsed['content']!,
              thinkingContent:
                  parsed['thinking']!.isEmpty ? null : parsed['thinking'],
              timestamp: assistantMsg.timestamp,
            );
            setState(() {
              _messages[_messages.length - 1] = finalMsg;
              _isStreaming = false;
            });
            _persistMessage(finalMsg);
            _scrollToBottom();
          }
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e) {
          WakelockPlus.disable();
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
        cancelOnError: true,
      );
      await completer.future;
      _streamSub = null;
    } catch (_) {
      WakelockPlus.disable();
      setState(() => _isStreaming = false);
    }
  }

  Widget _buildMessageBubble(ChatMessage msg, ColorScheme colorScheme) {
    if (msg.role == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            msg.content,
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final isUser = msg.role == 'user';
    final isThinking = !isUser &&
        msg.content.isEmpty &&
        msg.thinkingContent == null &&
        _isStreaming;
    final sl = SimpleLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            GestureDetector(
              onLongPress: msg.content.isNotEmpty
                  ? () => _showMessageActions(msg, sl)
                  : null,
              child: CircleAvatar(
                radius: 12,
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(Icons.auto_awesome,
                    size: 12, color: colorScheme.onPrimaryContainer),
              ),
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
                  topLeft: Radius.circular(isUser ? 16 : 4),
                  topRight: const Radius.circular(16),
                  bottomLeft: const Radius.circular(16),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                                  fontSize: 12,
                                  height: 1.45,
                                ),
                              )
                            : SelectableText.rich(
                                TextSpan(
                                  children: _getCachedMarkdown(
                                    msg,
                                    TextStyle(
                                      color: colorScheme.onSurface,
                                      fontSize: 12,
                                      height: 1.45,
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

  List<InlineSpan> _getCachedMarkdown(
      ChatMessage msg, TextStyle baseStyle, ColorScheme colorScheme) {
    final key = msg.content.hashCode ^ msg.content.length;
    final cached = _markdownCache[key];
    if (cached != null) return cached;
    final result = parseMarkdown(msg.content, baseStyle, colorScheme);
    if (!_isStreaming || _messages.last != msg) {
      _markdownCache[key] = result;
    }
    return result;
  }

  void _showMessageActions(ChatMessage msg, SimpleLocalizations sl) {
    final colorScheme = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(sl.getText('aiCopyMessage') ?? 'Copy'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: msg.content));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(sl.getText('aiCopied') ?? 'Copied'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.note_add, color: colorScheme.primary),
              title: Text(sl.getText('aiSaveAsNote') ?? 'Save as Note'),
              onTap: () {
                Navigator.pop(ctx);
                _saveMessageAsNote(msg, sl);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveMessageAsNote(ChatMessage msg, SimpleLocalizations sl) async {
    final title = msg.content.length > 30
        ? msg.content.substring(0, 30)
        : msg.content;
    final note = Note(
      title: title.replaceAll('\n', ' '),
      content: msg.content,
      sequence: 0,
    );
    await db.addNote(note);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sl.getText('aiSavedAsNote') ?? 'Saved as note'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildToolBubble(ChatMessage msg, ColorScheme colorScheme) {
    final isCall = msg.messageType == MessageType.toolCall;
    final lines = msg.content.split('\n');
    final toolName = lines.first;
    final resultText = lines.length > 1 ? lines.sublist(1).join('\n') : '';
    final mutedColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.55);

    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 48, top: 4, bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outline.withValues(alpha: 0.2),
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
                      color: mutedColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.build_outlined, size: 12, color: mutedColor),
                  const SizedBox(width: 4),
                  Text(
                    '$toolName...',
                    style: TextStyle(
                      fontSize: 11,
                      color: mutedColor,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: resultText.isNotEmpty
                        ? () {
                            final idx = _messages.indexOf(msg);
                            if (idx >= 0 && mounted) {
                              setState(() {
                                _messages[idx] =
                                    msg.copyWith(isExpanded: !msg.isExpanded);
                              });
                            }
                          }
                        : null,
                    child: Row(
                      children: [
                        Icon(Icons.build_outlined,
                            size: 13, color: mutedColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            toolName,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: mutedColor,
                            ),
                          ),
                        ),
                        if (resultText.isNotEmpty)
                          Icon(
                            msg.isExpanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 14,
                            color: mutedColor,
                          ),
                      ],
                    ),
                  ),
                  if (resultText.isNotEmpty && msg.isExpanded) ...[
                    const SizedBox(height: 4),
                    Text(
                      resultText,
                      style: TextStyle(
                        fontSize: 11,
                        color: mutedColor,
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildThinkingSection(String thinking, ColorScheme colorScheme) {
    final mutedColor = colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.3),
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
          leading: Icon(Icons.psychology, size: 14, color: mutedColor),
          title: Text(
            'Thinking...',
            style: TextStyle(
              fontSize: 11,
              color: mutedColor,
              fontStyle: FontStyle.italic,
            ),
          ),
          children: [
            SelectableText(
              thinking,
              style: TextStyle(
                fontSize: 11,
                color: mutedColor,
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

  Widget _buildContinueBar(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colorScheme.outlineVariant, width: 0.5)),
      ),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _continueSession,
          icon: const Icon(Icons.chat_outlined, size: 18),
          label: Text(sl.getText('continueChat') ?? 'Continue'),
        ),
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
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
            if (AiService.instance.isReady && !_isStreaming && !_isRecording)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    _buildMiniActionChip(sl.getText('aiSummarize') ?? 'Summarize', Icons.summarize, colorScheme),
                    const SizedBox(width: 6),
                    _buildMiniActionChip(sl.getText('aiTranslate') ?? 'Translate', Icons.translate, colorScheme),
                    const SizedBox(width: 6),
                    _buildMiniActionChip(sl.getText('aiOrganize') ?? 'AI Organize', Icons.auto_fix_high, colorScheme),
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
                      maxLines: 6,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      onSubmitted: (_) => _sendMessage(),
                      style: const TextStyle(fontSize: 13, height: 1.4),
                      decoration: InputDecoration(
                        hintText:
                            sl.getText('aiInputHint') ?? 'Ask anything...',
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: true,
                        fillColor: colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
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
              ? Colors.transparent
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
