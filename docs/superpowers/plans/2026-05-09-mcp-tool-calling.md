# MCP Tool Calling Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 lsnote AI Chat 增加 MCP 工具调用能力，支持启动预取基础信息（天气/节日）静默注入上下文，以及 AI Chat 中模型自主调用工具并显示调用过程。

**Architecture:** 新增 `McpService` 单例负责 MCP HTTP 通信，`McpTool` 数据模型负责解析工具定义。模型加载成功后自动触发预取，AI Chat 对话注入工具列表，收到 toolCalls 时显示中间气泡并执行 HTTP tool call，再把结果通过 `sendToolResponse` 反馈给模型继续推理。

**Tech Stack:** dart:io HttpClient（已有）、flutter_litert_lm LiteLmTool / sendToolResponse、sqflite config 表（ensureConfig 模式）

---

## File Map

| 文件 | 操作 | 职责 |
|------|------|------|
| `lib/model/McpTool.dart` | 新建 | MCP 工具定义数据模型 |
| `lib/service/McpService.dart` | 新建 | MCP 单例：配置、预取、tool call HTTP bridge |
| `lib/model/ChatMessage.dart` | 修改 | 新增 `messageType` 字段（toolCall / toolResult） |
| `lib/model/Config.dart` | 修改 | 新增 3 个 MCP config 常量 |
| `lib/NoteApp.dart` | 修改 | `_asyncInit` 中 ensureConfig MCP keys + McpService.init() |
| `lib/service/AiService.dart` | 修改 | `initialize()` 成功后调用 McpService.fetchContextOnModelReady() |
| `lib/i18n/SimpleLocalizations.dart` | 修改 | 新增 MCP 相关 i18n 字符串 |
| `lib/screen/AiChat.dart` | 修改 | conversation 注入工具；处理 toolCalls；工具气泡；设置弹窗重布局 |
| `CLAUDE.md` | 修改 | 记录 McpService 架构 |

---

## Task 1: McpTool 数据模型

**Files:**
- Create: `lib/model/McpTool.dart`

- [ ] **Step 1: 创建 McpTool 模型文件**

```dart
class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  factory McpTool.fromJson(Map<String, dynamic> json) {
    return McpTool(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      inputSchema: json['inputSchema'] as Map<String, dynamic>? ?? {},
    );
  }
}
```

- [ ] **Step 2: 验证文件无错误**

```bash
flutter analyze lib/model/McpTool.dart
```

Expected: No issues found（或仅 info level）

- [ ] **Step 3: Commit**

```bash
git add lib/model/McpTool.dart
git commit -m "feat: add McpTool model"
```

---

## Task 2: Config 常量 + SQLite 迁移

**Files:**
- Modify: `lib/model/Config.dart`
- Modify: `lib/NoteApp.dart`

- [ ] **Step 1: 在 Config.dart 新增 3 个静态常量**

在 `lib/model/Config.dart` 中，`static final String aiLanguage` 行之后添加：

```dart
  static final String mcpEnabled = "mcpEnabled";
  static final String mcpServerUrl = "mcpServerUrl";
  static final String mcpAuthHeader = "mcpAuthHeader";
```

完整文件结果：

```dart
class Config {

  static final String primarySwatch = "primarySwatch";
  static final String hiddenDone = "hiddenDone";
  static final String aiModelPath = "aiModelPath";
  static final String aiBackend = "aiBackend";
  static final String aiLanguage = "aiLanguage";
  static final String mcpEnabled = "mcpEnabled";
  static final String mcpServerUrl = "mcpServerUrl";
  static final String mcpAuthHeader = "mcpAuthHeader";

  final int? id;
  final String? name;
  final String? value;

  Config({this.id, this.name, this.value});

  Config.fromJsonMap(Map<String, dynamic> map)
      : id = map['id'] as int,
        name = map['name'] as String,
        value = map['value'] as String;

  Map<String, dynamic> toJsonMap() => {
        'id': id,
        'name': name,
        'value': value,
      };
}
```

- [ ] **Step 2: 在 NoteApp._asyncInit 中新增 ensureConfig 调用**

在 `lib/NoteApp.dart` 中，找到：

```dart
      await db.ensureConfig(Config.aiLanguage, 'zh');
      await AiService.instance.loadConfig();
```

修改为：

```dart
      await db.ensureConfig(Config.aiLanguage, 'zh');
      await db.ensureConfig(Config.mcpEnabled, '0');
      await db.ensureConfig(Config.mcpServerUrl, '');
      await db.ensureConfig(Config.mcpAuthHeader, '');
      await AiService.instance.loadConfig();
```

- [ ] **Step 3: 验证**

```bash
flutter analyze lib/model/Config.dart lib/NoteApp.dart
```

Expected: No issues found

- [ ] **Step 4: Commit**

```bash
git add lib/model/Config.dart lib/NoteApp.dart
git commit -m "feat: add MCP config keys"
```

---

## Task 3: McpService 核心实现

**Files:**
- Create: `lib/service/McpService.dart`

- [ ] **Step 1: 创建 McpService.dart**

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_litert_lm/flutter_litert_lm.dart';

import '../model/Config.dart';
import '../model/McpTool.dart';
import 'NoteAccessSqlite.dart';

class McpService {
  static final McpService instance = McpService._();
  McpService._();

  String _serverUrl = '';
  String _authHeader = '';
  bool _enabled = false;
  bool _isReady = false;
  String _contextCache = '';
  List<McpTool> _mcpTools = [];

  bool get isEnabled => _enabled && _serverUrl.isNotEmpty;
  bool get isReady => _isReady;
  String get contextCache => _contextCache;

  List<LiteLmTool> get tools {
    if (!isEnabled) return [];
    return _mcpTools.map((t) => LiteLmTool(
      name: t.name,
      description: t.description,
      parameters: t.inputSchema,
    )).toList();
  }

  Future<void> init() async {
    try {
      final enabledCfg = await db.getConfig(Config.mcpEnabled);
      final urlCfg = await db.getConfig(Config.mcpServerUrl);
      final authCfg = await db.getConfig(Config.mcpAuthHeader);
      _enabled = enabledCfg.value == '1';
      _serverUrl = urlCfg.value ?? '';
      _authHeader = authCfg.value ?? '';
    } catch (_) {}
  }

  Future<void> saveConfig({String? url, String? token, bool? enabled}) async {
    if (url != null) {
      _serverUrl = url;
      await db.setConfig(Config.mcpServerUrl, url);
    }
    if (token != null) {
      _authHeader = token;
      await db.setConfig(Config.mcpAuthHeader, token);
    }
    if (enabled != null) {
      _enabled = enabled;
      await db.setConfig(Config.mcpEnabled, enabled ? '1' : '0');
    }
  }

  static const List<String> _contextToolKeywords = [
    'weather', 'holiday', 'time', 'date', 'calendar',
    '天气', '节日', '时间', '日历',
  ];

  bool _isContextTool(String name) {
    final lower = name.toLowerCase();
    return _contextToolKeywords.any((kw) => lower.contains(kw));
  }

  Future<void> fetchContextOnModelReady() async {
    if (!isEnabled) return;
    _isReady = false;
    _contextCache = '';
    _mcpTools = [];

    try {
      final toolsJson = await _get('${_serverUrl}/tools/list');
      final toolsList = toolsJson['tools'] as List<dynamic>? ?? [];
      _mcpTools = toolsList
          .whereType<Map<String, dynamic>>()
          .map((j) => McpTool.fromJson(j))
          .toList();

      final contextBuffer = StringBuffer();
      for (final tool in _mcpTools) {
        if (!_isContextTool(tool.name)) continue;
        try {
          final args = _buildDefaultArgs(tool);
          final result = await callTool(tool.name, args);
          if (result.isNotEmpty) {
            contextBuffer.writeln('${tool.name}: $result');
          }
        } catch (_) {
          // 单个工具调用失败不影响其他工具
        }
      }
      _contextCache = contextBuffer.toString().trim();
      _isReady = true;
    } catch (_) {
      // 预取失败静默忽略
    }
  }

  Map<String, dynamic> _buildDefaultArgs(McpTool tool) {
    final props = tool.inputSchema['properties'] as Map<String, dynamic>? ?? {};
    final required = tool.inputSchema['required'] as List<dynamic>? ?? [];
    final args = <String, dynamic>{};
    for (final key in required) {
      if (props.containsKey(key)) {
        final prop = props[key] as Map<String, dynamic>;
        final type = prop['type'] as String? ?? 'string';
        if (type == 'string') args[key as String] = '';
        if (type == 'number' || type == 'integer') args[key as String] = 0;
      }
    }
    return args;
  }

  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'method': 'tools/call',
      'params': {'name': name, 'arguments': args},
    });
    final result = await _post('${_serverUrl}/tools/call', body);
    final content = result['result']?['content'] as List<dynamic>? ?? [];
    return content
        .whereType<Map<String, dynamic>>()
        .where((p) => p['type'] == 'text')
        .map((p) => p['text'] as String? ?? '')
        .join('\n');
  }

  Future<Map<String, dynamic>> _get(String url) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      if (_authHeader.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $_authHeader');
      }
      final response = await request.close()
          .timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _post(String url, String body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set('Content-Type', 'application/json');
      if (_authHeader.isNotEmpty) {
        request.headers.set('Authorization', 'Bearer $_authHeader');
      }
      request.write(body);
      final response = await request.close()
          .timeout(const Duration(seconds: 10));
      final responseBody = await response.transform(utf8.decoder).join();
      return jsonDecode(responseBody) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }
}
```

- [ ] **Step 2: 验证**

```bash
flutter analyze lib/service/McpService.dart
```

Expected: No issues found（或仅 info level）

- [ ] **Step 3: Commit**

```bash
git add lib/service/McpService.dart
git commit -m "feat: add McpService for MCP HTTP bridge"
```

---

## Task 4: AiService 触发 MCP 预取

**Files:**
- Modify: `lib/service/AiService.dart`

在 `initialize()` 方法中，找到两处 `_state = AiServiceState.ready; return true;` 的位置，在每处的 `_state = AiServiceState.ready;` 之后，`return true;` 之前，插入 McpService 预取调用。

- [ ] **Step 1: 在 AiService.dart 顶部添加 McpService import**

在 `lib/service/AiService.dart` 顶部，`import 'NoteAccessSqlite.dart';` 之后添加：

```dart
import 'McpService.dart';
```

- [ ] **Step 2: 修改 initialize() 中 GPU 后端成功分支**

找到：
```dart
      _engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: _modelPath,
          backend: _backend == 'gpu' ? LiteLmBackend.gpu : LiteLmBackend.cpu,
        ),
      );
      _state = AiServiceState.ready;
      return true;
```

修改为：
```dart
      _engine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: _modelPath,
          backend: _backend == 'gpu' ? LiteLmBackend.gpu : LiteLmBackend.cpu,
        ),
      );
      _state = AiServiceState.ready;
      McpService.instance.fetchContextOnModelReady();
      return true;
```

- [ ] **Step 3: 修改 initialize() 中 CPU fallback 成功分支**

找到：
```dart
          _engine = await LiteLmEngine.create(
            LiteLmEngineConfig(
              modelPath: _modelPath,
              backend: LiteLmBackend.cpu,
            ),
          );
          _backend = 'cpu';
          db.setConfig(Config.aiBackend, 'cpu');
          _state = AiServiceState.ready;
          return true;
```

修改为：
```dart
          _engine = await LiteLmEngine.create(
            LiteLmEngineConfig(
              modelPath: _modelPath,
              backend: LiteLmBackend.cpu,
            ),
          );
          _backend = 'cpu';
          db.setConfig(Config.aiBackend, 'cpu');
          _state = AiServiceState.ready;
          McpService.instance.fetchContextOnModelReady();
          return true;
```

- [ ] **Step 4: 修改 NoteApp._asyncInit，在 loadConfig 之后调用 McpService.init()**

在 `lib/NoteApp.dart` 中，找到：
```dart
      await AiService.instance.loadConfig();
      if (AiService.instance.modelPath.isNotEmpty) {
```

修改为：
```dart
      await AiService.instance.loadConfig();
      await McpService.instance.init();
      if (AiService.instance.modelPath.isNotEmpty) {
```

同时在 `lib/NoteApp.dart` 顶部 imports 中添加（在 `import 'service/AiService.dart';` 之后）：

```dart
import 'service/McpService.dart';
```

- [ ] **Step 5: 验证**

```bash
flutter analyze lib/service/AiService.dart lib/NoteApp.dart
```

Expected: No issues found

- [ ] **Step 6: Commit**

```bash
git add lib/service/AiService.dart lib/NoteApp.dart
git commit -m "feat: trigger MCP context fetch after model loads"
```

---

## Task 5: ChatMessage 新增 messageType

**Files:**
- Modify: `lib/model/ChatMessage.dart`

- [ ] **Step 1: 添加 MessageType 枚举和 messageType 字段**

将 `lib/model/ChatMessage.dart` 替换为：

```dart
enum MessageType { text, toolCall, toolResult }

class ChatMessage {
  final String role;
  final String content;
  final String? imagePath;
  final String? audioPath;
  final String? thinkingContent;
  final DateTime timestamp;
  final MessageType messageType;
  final bool isExpanded;

  ChatMessage({
    required this.role,
    required this.content,
    this.imagePath,
    this.audioPath,
    this.thinkingContent,
    DateTime? timestamp,
    this.messageType = MessageType.text,
    this.isExpanded = false,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({bool? isExpanded}) {
    return ChatMessage(
      role: role,
      content: content,
      imagePath: imagePath,
      audioPath: audioPath,
      thinkingContent: thinkingContent,
      timestamp: timestamp,
      messageType: messageType,
      isExpanded: isExpanded ?? this.isExpanded,
    );
  }

  Map<String, String> toApiMap() => {
        'role': role,
        'content': content,
      };
}
```

- [ ] **Step 2: 验证**

```bash
flutter analyze lib/model/ChatMessage.dart
```

Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add lib/model/ChatMessage.dart
git commit -m "feat: add MessageType enum and messageType to ChatMessage"
```

---

## Task 6: i18n 新增 MCP 字符串

**Files:**
- Modify: `lib/i18n/SimpleLocalizations.dart`

- [ ] **Step 1: 在 en map 末尾（`'aiAudioNotSupported'` 之后，`},` 之前）添加**

```dart
      'mcpTools': 'MCP Tools',
      'mcpServerUrl': 'Server URL',
      'mcpAuthToken': 'Bearer Token',
      'mcpEnable': 'Enable MCP',
      'mcpReady': 'Ready',
      'mcpFetching': 'Fetching...',
      'mcpNotConfigured': 'Not configured',
      'mcpFetchNow': 'Fetch Now',
      'toolCalling': 'Calling tool...',
      'toolResult': 'Tool result',
      'aiModelInference': 'Model & Inference',
      'aiConversation': 'Conversation',
      'aiSystemPrompt': 'System Prompt',
```

- [ ] **Step 2: 在 zh map 末尾（`'aiAudioNotSupported'` 之后，`},` 之前）添加**

```dart
      'mcpTools': 'MCP 工具',
      'mcpServerUrl': '服务器地址',
      'mcpAuthToken': '认证令牌',
      'mcpEnable': '启用 MCP',
      'mcpReady': '已就绪',
      'mcpFetching': '获取中...',
      'mcpNotConfigured': '未配置',
      'mcpFetchNow': '立即预取',
      'toolCalling': '正在调用工具...',
      'toolResult': '工具返回',
      'aiModelInference': '模型与推理',
      'aiConversation': '对话',
      'aiSystemPrompt': '系统提示词',
```

- [ ] **Step 3: 验证**

```bash
flutter analyze lib/i18n/SimpleLocalizations.dart
```

Expected: No issues found

- [ ] **Step 4: Commit**

```bash
git add lib/i18n/SimpleLocalizations.dart
git commit -m "feat: add MCP i18n strings"
```

---

## Task 7: AiChat — 工具气泡 + sendMessage 处理 toolCalls

**Files:**
- Modify: `lib/screen/AiChat.dart`

此 Task 仅修改 `_sendMessage` 方法（处理 toolCalls 的逻辑），以及新增 `_buildToolBubble` helper，暂不改设置弹窗（Task 8 负责）。

- [ ] **Step 1: 在 AiChat.dart 顶部新增 McpService import**

在 `import '../service/AiService.dart';` 之后添加：

```dart
import '../service/McpService.dart';
```

- [ ] **Step 2: 修改 createChatConversation 调用，注入 MCP 工具**

找到 `_sendMessage` 中的：

```dart
    try {
      _conversation ??= await AiService.instance.createChatConversation(
        systemInstruction: _attachedNote != null
            ? '${AiService.instance.contextInfo} The user has shared a note for context:\nTitle: ${_attachedNote!.title}\nContent: ${_attachedNote!.content}\n\nHelp the user with questions about this note.'
            : '${AiService.instance.contextInfo} You are a helpful assistant.',
      );
    } catch (e) {
```

修改为：

```dart
    try {
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
          tools: McpService.instance.tools,
        );
      }
    } catch (e) {
```

- [ ] **Step 3: 修改 AiService.createChatConversation 签名，支持 tools 参数**

在 `lib/service/AiService.dart` 中，找到：

```dart
  Future<LiteLmConversation> createChatConversation(
      {String? systemInstruction}) async {
    if (_engine == null || _state != AiServiceState.ready) {
      throw AiServiceException('AI engine not ready');
    }

    return await _engine!.createConversation(
      LiteLmConversationConfig(
        systemInstruction: systemInstruction ?? 'You are a helpful assistant.',
        samplerConfig: const LiteLmSamplerConfig(
          temperature: 0.7,
          topK: 40,
          topP: 0.95,
        ),
      ),
    );
  }
```

修改为：

```dart
  Future<LiteLmConversation> createChatConversation(
      {String? systemInstruction, List<LiteLmTool>? tools}) async {
    if (_engine == null || _state != AiServiceState.ready) {
      throw AiServiceException('AI engine not ready');
    }

    return await _engine!.createConversation(
      LiteLmConversationConfig(
        systemInstruction: systemInstruction ?? 'You are a helpful assistant.',
        samplerConfig: const LiteLmSamplerConfig(
          temperature: 0.7,
          topK: 40,
          topP: 0.95,
        ),
        tools: tools,
      ),
    );
  }
```

- [ ] **Step 4: 在 AiChat._sendMessage 的文本消息分支，处理 toolCalls**

找到文本消息分支中的 stream listen 部分（`onDone` callback）：

```dart
        onDone: () {
          if (mounted) {
            setState(() => _isStreaming = false);
          }
          if (!completer.isCompleted) completer.complete();
        },
```

修改为（在 onDone 中添加 toolCalls 处理）：

```dart
        onDone: () async {
          // Check if the last message contains tool calls
          final lastMsg = _messages.isNotEmpty ? _messages.last : null;
          if (lastMsg != null && _conversation != null) {
            // Get the last LiteLm message to check toolCalls
            // We handle this via a separate method after stream completes
          }
          if (!completer.isCompleted) completer.complete();
        },
```

并在 `await completer.future;` 之后、`_streamSub = null;` 之前，添加 toolCalls 处理：

找到：
```dart
      await completer.future;
      _streamSub = null;
    }
    _scrollToBottom();
  }
```

修改为：
```dart
      await completer.future;
      _streamSub = null;
      await _handleToolCallsIfNeeded(text, assistantMsg);
    }
    _scrollToBottom();
  }
```

- [ ] **Step 5: 新增 _handleToolCallsIfNeeded 方法**

在 `_parseThinking` 方法之前插入：

```dart
  Future<void> _handleToolCallsIfNeeded(
      String originalUserText, ChatMessage assistantMsg) async {
    if (_conversation == null) return;
    if (!McpService.instance.isEnabled) return;

    // The conversation's last response may have tool calls embedded in content.
    // We detect them by checking if the assistant message content looks like a
    // tool call JSON. LiteRT-LM surfaces them via sendMessageStream token text.
    // Instead, use sendMessage (non-streaming) for the tool-calling turn.
    // After stream completes, query conversation for pending tool calls via
    // a non-streaming probe is not available. We handle this differently:
    // We listen for a structured pattern in the streamed content.
    // Pattern: if last assistant message content is empty and we have a
    // toolCalls response, the SDK fires onDone immediately.
    // For robustness, we check if the streamed content looks like a tool call.
    final lastContent = _messages.isNotEmpty ? _messages.last.content : '';
    // If content is non-empty text, no tool call happened — return.
    if (lastContent.isNotEmpty && !lastContent.trim().startsWith('{')) return;
  }
```

Note: LiteRT-LM 的 tool call 流程需要在实际设备上测试。当模型决定调用工具时，
`sendMessageStream` 会在 `onDone` 前通过 `LiteLmMessage.toolCalls` 暴露工具调用请求。
由于 Dart SDK 的 stream 只发 text delta，toolCalls 需要通过 `sendMessage`（非流式）获取完整 message。

实际实现使用非流式方式处理含工具调用的回合：

将 Task 7 Step 5 的方法替换为更完整的实现，并修改 `_sendMessage` 中文本消息分支，
改为先用非流式探测是否有工具调用，有则走工具流程，无则走流式。

修改 `_sendMessage` 中的文本消息分支（找到 `} else {` 之后的整块）：

```dart
    } else {
      await _sendTextWithToolSupport(text, assistantMsg);
    }
```

新增 `_sendTextWithToolSupport` 方法（替换上面 Step 5 的方法）：

```dart
  Future<void> _sendTextWithToolSupport(
      String text, ChatMessage assistantMsg) async {
    if (_conversation == null) return;
    if (!McpService.instance.isEnabled || McpService.instance.tools.isEmpty) {
      // No tools — use streaming as before
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

    // Tool calling: use non-streaming sendMessage to get toolCalls
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
        // Final text response
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

      // Has tool calls — process each
      for (final toolCall in response.toolCalls) {
        final toolName = toolCall.name;
        final toolArgs = toolCall.arguments;

        // Insert toolCall bubble
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

        // Replace toolCall bubble with toolResult bubble
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

        // Send tool response back to model
        try {
          final continuation = await _conversation!.sendToolResponse(toolName, toolResult);
          // If continuation has text and no tool calls, that's the final answer
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

      // After tool responses, get next model message (empty string triggers continuation)
    }

    // Max rounds exceeded
    if (mounted) setState(() => _isStreaming = false);
  }
```

- [ ] **Step 6: 移除旧的文本流式分支代码**

`_sendMessage` 中原来的 `} else {` 文本分支（从 `final buffer = StringBuffer();` 到 `_streamSub = null;`）已被 `_sendTextWithToolSupport` 取代，删除旧代码：

找到并删除：
```dart
    } else {
      final buffer = StringBuffer();
      final completer = Completer<void>();
      _streamSub = _conversation!.sendMessageStream(text).listen(
        (token) {
          ...
        },
        cancelOnError: true,
      );
      await completer.future;
      _streamSub = null;
    }
```

替换为：
```dart
    } else {
      await _sendTextWithToolSupport(text, assistantMsg);
    }
```

- [ ] **Step 7: 新增 _buildToolBubble 方法**

在 `_buildMessageBubble` 方法附近添加：

```dart
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
            color: colorScheme.outline.withValues(alpha: 0.15),
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
```

- [ ] **Step 8: 在 _buildMessageBubble 调用处，根据 messageType 分流**

找到消息列表渲染处（`ListView.builder` 的 `itemBuilder`），在调用 `_buildMessageBubble` 之前添加 tool bubble 判断：

找到类似：
```dart
              return _buildMessageBubble(msg, colorScheme);
```

修改为：
```dart
              if (msg.messageType == MessageType.toolCall ||
                  msg.messageType == MessageType.toolResult) {
                return _buildToolBubble(msg, colorScheme);
              }
              return _buildMessageBubble(msg, colorScheme);
```

- [ ] **Step 9: 验证**

```bash
flutter analyze lib/screen/AiChat.dart lib/service/AiService.dart
```

Expected: No issues found（或仅 info level）

- [ ] **Step 10: Commit**

```bash
git add lib/screen/AiChat.dart lib/service/AiService.dart
git commit -m "feat: handle MCP tool calls in AI Chat with tool bubbles"
```

---

## Task 8: AiChat 设置弹窗重布局

**Files:**
- Modify: `lib/screen/AiChat.dart`

将 `_showSettingsDialog` 方法的 `AlertDialog` 内容从单列 `SingleChildScrollView` 重构为三个 Section 的 `ListView`，并在顶部放置加载模型按钮/状态。

- [ ] **Step 1: 在 _showSettingsDialog 局部变量中添加 MCP 状态变量**

找到 `_showSettingsDialog` 方法顶部的局部变量声明区域，在 `bool showModelList = false;` 之后添加：

```dart
    String mcpUrl = McpService.instance._serverUrl;
    String mcpToken = McpService.instance._authHeader;
    bool mcpEnabled = McpService.instance._enabled;
    final mcpUrlCtl = TextEditingController(text: mcpUrl);
    final mcpTokenCtl = TextEditingController(text: mcpToken);
    final systemPromptCtl = TextEditingController();
```

注意：McpService 的私有字段需要通过公开 getter 暴露。在 McpService 中添加：

```dart
  String get serverUrl => _serverUrl;
  String get authHeader => _authHeader;
  bool get enabled => _enabled;
```

然后修改 `_showSettingsDialog` 中的初始化：

```dart
    String mcpUrl = McpService.instance.serverUrl;
    String mcpToken = McpService.instance.authHeader;
    bool mcpEnabled = McpService.instance.enabled;
    final mcpUrlCtl = TextEditingController(text: mcpUrl);
    final mcpTokenCtl = TextEditingController(text: mcpToken);
    final systemPromptCtl = TextEditingController();
    bool isMcpFetching = false;
```

- [ ] **Step 2: 将 AlertDialog 的 content 替换为分 Section 的 ListView**

找到 `return AlertDialog(` 及其 `content:` 部分，将整个 content widget 替换为：

```dart
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

                  // Load model button + status (always visible at top)
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
                                ? (sl.getText('aiModelLoading') ??
                                    'Loading...')
                                : AiService.instance.isReady
                                    ? (sl.getText('aiModelReady') ?? 'Ready')
                                    : (sl.getText('aiModelNotSet') ??
                                        'Not configured'),
                            style: const TextStyle(fontSize: 13),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AiService.instance.isReady
                                ? Theme.of(ctx)
                                    .colorScheme
                                    .primaryContainer
                                : null,
                          ),
                          onPressed: (isInitializing || isDownloading)
                              ? null
                              : () async {
                                  if (!AiService.instance.isReady &&
                                      AiService.instance.modelPath.isNotEmpty) {
                                    setDialogState(() => isInitializing = true);
                                    await AiService.instance.initialize();
                                    setDialogState(
                                        () => isInitializing = false);
                                  }
                                },
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

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
                        style: const TextStyle(
                            fontSize: 11, color: Colors.red)),

                  // Device RAM info
                  if (deviceRamGB != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
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

                  // Current model + switch
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
                          : () =>
                              setDialogState(() => showModelList = true),
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
                          decoration: const InputDecoration(
                            hintText:
                                'https://huggingface.co/.../xxx.litertlm?download=true',
                            border: OutlineInputBorder(),
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
                                    _conversation?.dispose();
                                    _conversation = null;
                                    final stream = hasModel
                                        ? AiService.instance
                                            .switchModel(model)
                                        : AiService.instance
                                            .downloadModel(model);
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
                        TextButton.icon(
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: Text(
                            sl.getText('aiBrowseModels') ??
                                'Browse available models',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onPressed: () => launchUrl(
                            Uri.parse(
                                'https://huggingface.co/litert-community'),
                          ),
                        ),
                      ],
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
                                setDialogState(
                                    () => selectedBackend = vals.first);
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
                          await McpService.instance
                              .saveConfig(enabled: v);
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
                                : (sl.getText('mcpNotConfigured') ??
                                    'Not configured'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: isMcpFetching
                            ? null
                            : () async {
                                await McpService.instance
                                    .saveConfig(url: mcpUrl, token: mcpToken);
                                setDialogState(() => isMcpFetching = true);
                                await McpService.instance
                                    .fetchContextOnModelReady();
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
                  mcpUrlCtl.dispose();
                  mcpTokenCtl.dispose();
                  systemPromptCtl.dispose();
                  downloadSub?.cancel();
                  Navigator.of(ctx).pop();
                },
                child:
                    Text(sl.getText('cancelLabel') ?? 'Close'),
              ),
            ],
          );
```

- [ ] **Step 3: 新增 _buildSettingsSectionHeader helper 方法**

在 `_showSettingsDialog` 方法之前添加：

```dart
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
```

- [ ] **Step 4: 验证**

```bash
flutter analyze lib/screen/AiChat.dart
```

Expected: No issues found（或仅 info level）

- [ ] **Step 5: Commit**

```bash
git add lib/screen/AiChat.dart lib/service/McpService.dart
git commit -m "feat: redesign AI settings dialog with MCP section"
```

---

## Task 9: NoteLanding completeStream 注入 contextCache

**Files:**
- Modify: `lib/service/AiService.dart`

设计文档要求：NoteLanding 等调用 `completeStream` 的场景，静默使用 `McpService.instance.contextCache`。

- [ ] **Step 1: 修改 AiService.completeStream，将 contextCache 注入 systemPrompt**

在 `lib/service/AiService.dart` 的 `completeStream` 方法中，找到：

```dart
  Stream<String> completeStream(
      String systemPrompt, String userMessage,
      {int? maxLength}) async* {
    if (_engine == null || _state != AiServiceState.ready) {
      throw AiServiceException('AI engine not ready');
    }

    final effectivePrompt =
        _isQwenModel ? '$systemPrompt\n/no_think' : systemPrompt;
```

修改为：

```dart
  Stream<String> completeStream(
      String systemPrompt, String userMessage,
      {int? maxLength}) async* {
    if (_engine == null || _state != AiServiceState.ready) {
      throw AiServiceException('AI engine not ready');
    }

    final mcpContext = McpService.instance.contextCache;
    final basePrompt = mcpContext.isNotEmpty
        ? '$systemPrompt\n\nContext information:\n$mcpContext'
        : systemPrompt;
    final effectivePrompt =
        _isQwenModel ? '$basePrompt\n/no_think' : basePrompt;
```

- [ ] **Step 2: 验证**

```bash
flutter analyze lib/service/AiService.dart
```

Expected: No issues found

- [ ] **Step 3: Commit**

```bash
git add lib/service/AiService.dart
git commit -m "feat: inject MCP context cache into completeStream system prompt"
```

---

## Task 11: CLAUDE.md 更新

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 在 CLAUDE.md 的 "On-Device AI (LiteRT-LM)" 章节添加 McpService 说明**

在 `### AI Engine 并发与生命周期管理` 章节之前插入：

```markdown
### MCP Tool Calling

`lib/service/McpService.dart` — 单例管理 MCP HTTP 通信。

- 配置项：`mcpEnabled`、`mcpServerUrl`、`mcpAuthHeader`（SQLite config 表）
- 模型加载成功后自动调用 `fetchContextOnModelReady()`，预取天气/节日等 context 类工具结果，缓存为 `contextCache` 纯文本注入对话 system prompt
- AI Chat 对话创建时通过 `createChatConversation(tools: McpService.instance.tools)` 注入工具定义
- 收到 `toolCalls` 时走 `_sendTextWithToolSupport` 非流式路径，显示 `MessageType.toolCall/toolResult` 气泡，再调 `sendToolResponse` 继续推理
- context 类工具按名称模糊匹配（weather/holiday/time/date/calendar）在启动时主动调用；其余工具仅注入定义供模型按需调用
- MCP 未启用时 `tools` 返回空列表，`contextCache` 返回空字符串，对现有逻辑零影响
```

- [ ] **Step 2: 验证 + Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document McpService architecture in CLAUDE.md"
```

---

## Task 12: 集成验证

- [ ] **Step 1: 静态分析全量检查**

```bash
flutter analyze
```

Expected: No error-level issues

- [ ] **Step 2: 构建 debug APK**

```bash
flutter build apk --debug --target-platform android-arm64
```

Expected: Build successful, no compilation errors

- [ ] **Step 3: 手动测试 Checklist**

1. **MCP 未配置场景**：打开 AI Chat → 设置弹窗 → Section 1"模型与推理"在顶部可见，无需滚动 → 关闭弹窗 → 正常发送消息，无报错
2. **设置弹窗布局**：三个 Section 均可见，MCP Section 有 Switch 开关、URL/Token 输入框、状态指示
3. **MCP 开关**：打开开关 → 输入 URL + Token → 点"立即预取" → 状态变为"获取中..." → 完成后变为"已就绪"
4. **工具调用气泡**：发送触发工具调用的消息 → 出现🔧气泡 → 工具完成后变为✓气泡（可折叠）
5. **无工具调用场景**：发送普通消息 → 正常流式输出，无变化

- [ ] **Step 4: Final Commit**

```bash
git add -A
git commit -m "feat: MCP tool calling integration complete (v1.4.0)"
```
