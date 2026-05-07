import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import 'models.dart';

/// Chat screen that loads a previously-downloaded model and lets the user
/// have a conversation with it. The picker screen is responsible for
/// guaranteeing the model file exists before pushing this route.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.model,
    required this.modelPath,
    required this.backend,
  });

  final ModelInfo model;
  final String modelPath;
  final LiteLmBackend backend;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <_ChatMessage>[];

  LiteLmEngine? _engine;
  LiteLmConversation? _conversation;
  StreamSubscription<LiteLmMessage>? _streamSub;

  bool _isBusy = false;
  bool _isReady = false;
  String _statusMessage = 'Loading model...';

  @override
  void initState() {
    super.initState();
    _initializeEngine();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _conversation?.dispose();
    _engine?.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeEngine() async {
    setState(() {
      _isBusy = true;
      _statusMessage = 'Loading ${widget.model.name}...';
    });

    try {
      _engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: widget.modelPath,
          backend: widget.backend,
        ),
      );

      _conversation = await _engine!.createConversation(
        LiteLmConversationConfig(
          systemInstruction: 'You are a helpful assistant. Be concise.',
          samplerConfig: const LiteLmSamplerConfig(
            temperature: 0.7,
            topK: 40,
            topP: 0.95,
          ),
        ),
      );

      setState(() {
        _isReady = true;
        _statusMessage = 'Ready';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Failed to load model: $e';
      });
    } finally {
      setState(() => _isBusy = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !_isReady || _isBusy) return;

    _controller.clear();
    // Add the user's message and a placeholder for the model's streaming
    // reply. The placeholder is updated in-place as tokens arrive so the
    // UI feels alive instead of waiting silently for the full response.
    final stats = _MessageStats();
    final reply = _ChatMessage(role: 'model', text: '', stats: stats);
    setState(() {
      _messages.add(_ChatMessage(role: 'user', text: text));
      _messages.add(reply);
      _isBusy = true;
    });
    _scrollToBottom();

    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();
    _streamSub = _conversation!.sendMessageStream(text).listen(
      (msg) {
        if (!mounted) return;
        // LiteRT-LM's Flow emits one Message per generated chunk, where the
        // text is the NEW tokens only (a delta), not a snapshot of the full
        // response so far. Append, don't overwrite, otherwise the user sees
        // only the most recent token flicker on screen.
        setState(() {
          reply.text += msg.text;
          stats.tokens++;
          stats.timeToFirstToken ??= stopwatch.elapsed;
          stats.totalDuration = stopwatch.elapsed;
        });
        _scrollToBottom();
      },
      onError: (Object err) {
        if (!mounted) return;
        setState(() {
          if (reply.text.isEmpty) {
            // Replace the empty placeholder with an error bubble.
            _messages.removeLast();
            _messages.add(_ChatMessage(role: 'error', text: 'Error: $err'));
          } else {
            reply.text = '${reply.text}\n[Error: $err]';
            reply.role = 'error';
          }
          _isBusy = false;
        });
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!mounted) return;
        stopwatch.stop();
        setState(() {
          stats.totalDuration = stopwatch.elapsed;
          // If the model genuinely produced no text, show a hint instead of
          // leaving an empty bubble in the chat.
          if (reply.text.isEmpty) {
            _messages.removeLast();
            _messages.add(
              _ChatMessage(role: 'error', text: '(empty response)'),
            );
          }
          _isBusy = false;
        });
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.model.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _statusMessage,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _isReady
                            ? 'Type a message to start chatting!'
                            : _statusMessage,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final isUser = msg.role == 'user';
                      final isEmptyModelBubble =
                          msg.role == 'model' && msg.text.isEmpty;
                      return Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: isUser
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primaryContainer
                                    : msg.role == 'error'
                                        ? Theme.of(context)
                                            .colorScheme
                                            .errorContainer
                                        : Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: isEmptyModelBubble
                                  ? const _TypingDots()
                                  : SelectableText(msg.text),
                            ),
                            if (msg.stats != null && msg.stats!.tokens > 0)
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 4,
                                  right: 4,
                                  bottom: 8,
                                ),
                                child: _StatsBar(stats: msg.stats!),
                              )
                            else
                              const SizedBox(height: 4),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    enabled: _isReady && !_isBusy,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _isReady && !_isBusy ? _sendMessage : null,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatMessage {
  String role;
  String text;

  /// Per-message inference stats — only populated for streaming model
  /// replies. The picker keeps these around so the user can compare runs
  /// after the fact.
  _MessageStats? stats;

  _ChatMessage({required this.role, required this.text, this.stats});
}

class _MessageStats {
  /// Number of streaming chunks received from the model. LiteRT-LM emits
  /// roughly one chunk per generated token, so this doubles as a token
  /// count for display purposes.
  int tokens = 0;

  /// Wall-clock duration from sending the prompt to receiving the first
  /// chunk back. A proxy for prefill cost.
  Duration? timeToFirstToken;

  /// Wall-clock duration from sending the prompt to the final chunk.
  Duration? totalDuration;

  /// Decode throughput in tokens per second, computed across the decode
  /// window only (excludes the time-to-first-token / prefill phase) so that
  /// the number reflects sustained generation speed rather than being
  /// dragged down by the initial latency.
  double get tokensPerSecond {
    final ttft = timeToFirstToken;
    final total = totalDuration;
    if (ttft == null || total == null || tokens <= 1) return 0;
    final decodeMs = (total.inMicroseconds - ttft.inMicroseconds) / 1000.0;
    if (decodeMs <= 0) return 0;
    // We saw `tokens` chunks total; the first one ended the TTFT window, so
    // (tokens - 1) chunks were generated during the decode phase.
    return (tokens - 1) * 1000.0 / decodeMs;
  }
}

/// Compact one-line readout of inference stats: token count, decode
/// throughput in tok/s, and time-to-first-token. Shown directly under each
/// streamed model reply so the user can compare runs across backends and
/// model sizes without scrolling.
class _StatsBar extends StatelessWidget {
  const _StatsBar({required this.stats});

  final _MessageStats stats;

  String _formatDuration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
    return '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';
  }

  @override
  Widget build(BuildContext context) {
    final ttft = stats.timeToFirstToken;
    final total = stats.totalDuration;
    final tps = stats.tokensPerSecond;

    final parts = <String>[
      '${stats.tokens} tok',
      if (tps > 0) '${tps.toStringAsFixed(1)} tok/s',
      if (ttft != null) 'TTFT ${_formatDuration(ttft)}',
      if (total != null) 'total ${_formatDuration(total)}',
    ];

    return Text(
      parts.join(' • '),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Three dots that fade in/out in sequence — the classic "typing..."
/// indicator. Used as the placeholder while the model is preparing the
/// first token of a streaming response.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = ((_controller.value * 3) - i).clamp(0.0, 1.0);
            final opacity =
                0.3 + 0.7 * (1 - (phase - 0.5).abs() * 2).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Opacity(
                opacity: opacity,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
