import 'dart:async';

import 'package:flutter/material.dart';

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
  bool _aiAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkAiHealth();
  }

  Future<void> _checkAiHealth() async {
    final available = await AiService.instance.checkHealth();
    if (mounted) setState(() => _aiAvailable = available);
  }

  @override
  void dispose() {
    _inputCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _inputCtl.text.trim();
    if (text.isEmpty || _isStreaming) return;

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _isStreaming = true;
    });
    _inputCtl.clear();
    _scrollToBottom();

    final apiMessages = <Map<String, String>>[];

    if (_attachedNote != null) {
      apiMessages.add({
        'role': 'system',
        'content':
            'The user has shared a note for context:\nTitle: ${_attachedNote!.title}\nContent: ${_attachedNote!.content}\n\nHelp the user with questions about this note.',
      });
    }

    for (final msg in _messages) {
      if (msg.role != 'system') {
        apiMessages.add(msg.toApiMap());
      }
    }

    final assistantMsg = ChatMessage(role: 'assistant', content: '');
    setState(() => _messages.add(assistantMsg));

    try {
      final buffer = StringBuffer();
      await for (final token in AiService.instance.completeStream(apiMessages)) {
        buffer.write(token);
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

  void _clearChat() {
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
        setState(() => _attachedNote = note);
      }
    });
  }

  Future<void> _showSettingsDialog() async {
    final sl = SimpleLocalizations.of(context)!;
    final hostCtl = TextEditingController(text: AiService.instance.host);
    final portCtl =
        TextEditingController(text: AiService.instance.port.toString());
    bool? testResult;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(sl.getText('aiSettings') ?? 'AI Settings'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: hostCtl,
                decoration: InputDecoration(
                  labelText: sl.getText('aiHost') ?? 'Host',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portCtl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: sl.getText('aiPort') ?? 'Port',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () async {
                      final newHost = hostCtl.text.trim();
                      final newPort =
                          int.tryParse(portCtl.text.trim()) ?? 8888;
                      AiService.instance.updateConfig(newHost, newPort);
                      final result =
                          await AiService.instance.checkHealth();
                      setDialogState(() => testResult = result);
                    },
                    child:
                        Text(sl.getText('aiTestConnection') ?? 'Test'),
                  ),
                  const SizedBox(width: 12),
                  if (testResult != null)
                    Icon(
                      testResult! ? Icons.check_circle : Icons.error,
                      color: testResult! ? Colors.green : Colors.red,
                      size: 20,
                    ),
                  if (testResult != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        testResult!
                            ? (sl.getText('aiConnected') ?? 'Connected')
                            : (sl.getText('aiDisconnected') ??
                                'Disconnected'),
                        style: TextStyle(
                          color:
                              testResult! ? Colors.green : Colors.red,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                final newHost = hostCtl.text.trim();
                final newPort = int.tryParse(portCtl.text.trim()) ?? 8888;
                AiService.instance.updateConfig(newHost, newPort);
                Navigator.of(ctx).pop();
                _checkAiHealth();
              },
              child: Text(sl.getText('confirmLabel') ?? 'OK'),
            ),
          ],
        ),
      ),
    );

    hostCtl.dispose();
    portCtl.dispose();
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
                      onTap: () => setState(() => _attachedNote = null),
                      child: Icon(Icons.close,
                          size: 16, color: colorScheme.primary),
                    ),
                  ],
                ),
              ),
            if (!_aiAvailable)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: colorScheme.errorContainer.withValues(alpha: 0.3),
                child: Text(
                  sl.getText('aiServiceHint') ??
                      'Start AI Edge Gallery and enable Edge Server',
                  style:
                      TextStyle(fontSize: 12, color: colorScheme.error),
                  textAlign: TextAlign.center,
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
        child: SelectableText(
          msg.content,
          style: TextStyle(
            color: isUser ? colorScheme.onPrimary : colorScheme.onSurface,
            fontSize: 14,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colorScheme, SimpleLocalizations sl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: Row(
        children: [
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
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: (_isStreaming || !_aiAvailable) ? null : _sendMessage,
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
    );
  }
}
