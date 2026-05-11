# CLAUDE.md

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


## Project Overview

**lsnote** (Local Simple NOTE) is a Flutter mobile/desktop note-taking app (v1.3.2+6). It supports Android, iOS, macOS, and Windows. Features include SQLite-backed notes, drag-drop reordering, fingerprint auth, JSON backup/restore, theme customization, on-device AI chat, and a number puzzle mini-game.

## Commands

```bash
# Dependencies
flutter pub get
flutter clean && flutter pub get

# Run
flutter run

# Build
flutter build apk --debug --target-platform android-arm64
flutter build apk --release

# Test
flutter test
flutter test test/widget_test.dart

# Analyze
flutter analyze
flutter analyze lib/some_file.dart

# Check outdated packages
flutter pub outdated

# Deploy to phone (USB debug connected)
./deploy.sh --debug    # debug build + install
./deploy.sh            # release build + install

# Install release APK directly (after build)
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Release Workflow

当用户提到"打包发布"/"release"/"新版本"时，执行以下完整流程：

1. **更新版本号** — `pubspec.yaml` 中 `version: X.Y.Z+N`（patch +1，build number +1）
2. **更新 README.md** — 反映新功能/改动
3. **Commit** — `git add` 相关文件，commit message 格式：`feat: ... (vX.Y.Z)`
4. **Tag & Push** — `git tag vX.Y.Z && git push origin master --tags`
5. **Build release APK** — `flutter build apk --release --target-platform android-arm64`
6. **打包到 bin/** — `mkdir -p bin/X.Y.Z+N && zip -j bin/X.Y.Z+N/app-release.zip build/app/outputs/flutter-apk/app-release.apk`

注意：`bin/` 目录已 gitignore，APK 通过 GitHub Release 上传。

## Architecture

The app uses **Provider + ChangeNotifier** for state management and **sqflite** for local persistence.

### Entry & Routing

`main.dart` bootstraps three global `ChangeNotifier`s via `MultiProvider` and mounts `NoteApp`. `NoteApp.dart` defines named routes and initializes the DB singleton.

Route flow: `Login` → `NoteLanding` → `NoteItem` / `Backup` / `NumberPuzzles` / `AiChat`

### Layer Structure

| Layer | Location | Role |
|---|---|---|
| Screens | `lib/screen/` | UI — 6 screens, each a named route |
| State | `lib/changenotifier/` | 3 ChangeNotifiers (theme, hide-done toggle, game state) |
| Service | `lib/service/NoteAccessSqlite.dart` | Singleton SQLite DAO; all DB access goes here |
| Models | `lib/model/` | Plain Dart classes: `Note`, `Config`, `GuessItem`, `ChatMessage` (has optional `imagePath` for multimodal), `McpTool` |
| i18n | `lib/i18n/SimpleLocalizations.dart` | Hardcoded en/zh strings (~100+ keys) |
| Utils | `lib/utils/NavigationHelper.dart` | Shared navigation helpers |

### State Management Details

- **ThemeChangeNotifier** — active color scheme (16 Material primaries); persisted to `config` table
- **SwitcherChangeNotifier** — boolean toggle for hiding completed notes; persisted to `config` table
- **GuessitemChangeNotifier** — in-memory state for the 1A2B number puzzle game

Screens read state with `Provider.of<T>(context)` and write via notifier methods.

### Database Schema

`NoteAccessSqlite` is a singleton (`NoteAccessSqlite.db`). Two tables:

- `notes` — `id`, `title`, `content`, `sequence` (REAL, used for drag-drop order), `isDone` (BIT), `targetDate` (INT epoch ms)
- `config` — `id`, `name`, `value` (key-value store for theme index and hide-done setting)

### i18n

`SimpleLocalizations` contains all UI strings. Add new keys to both `_en` and `_zh` maps in `lib/i18n/SimpleLocalizations.dart`.

### Theme System

Material Design 3 with `ColorScheme`. The user picks one of 16 colors (`Colors.primaries` minus brown/blueGrey); light and dark variants are generated automatically. Theme is applied at the `NoteApp` level.

### UI 风格约定

- **圆角**：弹窗/Dialog `borderRadius: 12`，卡片 `12`，输入框 `4`（近乎直角），气泡 `16`
- **字号体系**：正文 13px，辅助 11-12px，时间戳 10px
- **间距**：气泡内 padding h:12/v:8，消息间 vertical:4
- **弹窗风格**：elevation 0，flat design，减少圆角，参照 NoteLanding 页面风格
- **输入框**：不使用大圆角（no pill shape），细边框 + 聚焦高亮，支持多行

### On-Device AI (LiteRT-LM)

`lib/service/AiService.dart` — Singleton managing LiteRT-LM engine lifecycle. Uses `flutter_litert_lm` package with Gemma-4-E4B-it model (`.litertlm` format, ~3.6GB, user-provided file).

- State machine: `uninitialized → loading → ready / error`
- Two usage patterns: `completeStream(systemPrompt, userMessage)` for one-shot (NoteLanding assist), `createChatConversation()` for multi-turn (AiChat)
- Multimodal: `completeMultimodal(systemPrompt, imagePath, userText)` for image analysis (non-streaming, returns Future<String>)
- Audio: `completeAudio(systemPrompt, audioPath, userText)` for audio transcription (non-streaming, returns Future<String>)
- Audio/Vision multimodal must create temporary independent engines (with `audioBackend`/`visionBackend`), never use main engine. Audio needs WAV 16kHz mono format
- `sendMultimodalMessage` (SDK) is non-streaming only — no streaming for image/audio input
- `AiModelInfo.supportsVision` / `supportsAudio` — Gemma 4 models support both, Qwen3 models do not
- `AiService.isVisionModel` / `isAudioModel` — check before invoking multimodal features; show switch prompt if false
- GPU backend with automatic CPU fallback
- Config keys in SQLite: `aiModelPath`, `aiBackend`
- New config rows are added via `db.ensureConfig()` in `NoteApp._asyncInit()` (not only `_initSQLs`) for database migration safety

### AI Prompt & Sampling 最佳实践（小模型防重复）

小模型（Gemma E4B/E2B、Qwen3 0.6B）容易陷入重复输出循环。经验证有效的策略：

- **轻量场景用 `completeStream`**（直接流式），不用 `completeStreamNoThink`（其 buffer 累积逻辑反而加剧重复）
- **采样参数保持默认**：`temperature: 0.7, topK: 40, topP: 0.95` — 不要降低 topK/topP，过度限制候选 token 会导致循环
- **SDK 无 repetitionPenalty**：`LiteLmSamplerConfig` 只有 temperature/topK/topP，无法在采样层面惩罚重复
- **Prompt 需要角色设定 + 明确约束**：如 "You are a witty assistant..."、"NEVER repeat"、"Output ONLY the result"
- **轻量场景不附加 contextInfo**（时间+语言长前缀），仅用极短的语言标记 `_lang`（"Reply in Simplified Chinese."）
- **中重量级场景**（organize、chat 等输出较长）可保留完整 `$_ctx`，因为长输出不易循环
- **`completeStreamNoThink` 保留给**需要过滤 `<think>` 标签的场景（Qwen3 模型）或需要 maxLength 强制截断的场景
- **所有 prompt 集中在 `lib/service/AiPrompts.dart`** 统一管理

### AI Graceful Degradation (必须遵守)

所有 AI 增强功能必须在模型未就绪时优雅降级，绝不影响正常 UI 交互：

- **UI 渲染**: AI 相关按钮/指示器仅在 `AiService.instance.isReady` 为 true 时渲染
- **调用保护**: 所有 AI 调用前必须加 guard clause `if (!AiService.instance.isReady) return;`
- **错误处理**: AI 流式调用必须包裹在 try-catch 中，出错时静默重置状态（不弹错误提示）
- **独立性**: AI 失败绝不阻塞或破坏正常 app 功能，游戏逻辑/笔记操作不依赖 AI 代码路径

```dart
// 标准模式:
if (!AiService.instance.isReady) return;
try {
  // stream AI response
} catch (_) {
  // 静默清除状态，不向用户展示错误
}
```

### MCP Tool Calling

`lib/service/McpService.dart` — 单例管理 MCP HTTP 通信。

- 配置项：`mcpEnabled`、`mcpServerUrl`、`mcpAuthHeader`（SQLite config 表）
- 模型加载成功后自动调用 `fetchContextOnModelReady()`，预取天气/节日等 context 类工具结果，缓存为 `contextCache` 纯文本注入对话 system prompt
- AI Chat 对话创建时通过 `createChatConversation(tools: McpService.instance.tools)` 注入工具定义
- 收到 `toolCalls` 时走 `_sendTextWithToolSupport` 非流式路径，显示 `MessageType.toolCall/toolResult` 气泡，再调 `sendToolResponse` 继续推理
- context 类工具按名称模糊匹配（weather/holiday/time/date/calendar）在启动时主动调用；其余工具仅注入定义供模型按需调用
- MCP 未启用时 `tools` 返回空列表，`contextCache` 返回空字符串，对现有逻辑零影响
- **Tool-calling 路径**：`_sendTextWithToolSupport` 使用 `conversation.sendMessage`（非流式，返回 `LiteLmMessage`），检查 `response.toolCalls`，若非空则逐个调用 MCP server 的 `tools/call`，再通过 `sendToolResponse` 继续推理，最多循环 5 轮
- **`_conversationHasTools` 延迟加载**：MCP tools 异步获取，可能晚于首次对话创建。发送消息时检测到 tools 已就绪但 conversation 未注入 tools，则自动重建 conversation
- **JSON-RPC 要求 `id` 字段**：MCP server 遵循 JSON-RPC 2.0，请求必须包含 `'id'` 字段，否则返回 `Method not found` 错误
- **HTTP body 编码**：Dart `HttpClient.request.write()` 默认用 Latin-1，必须用 `request.add(utf8.encode(body))` + 显式 `Content-Length` 确保 UTF-8 传输

### AI Engine 并发与生命周期管理

- **LiteRT-LM engine 单线程**：不能并发调用，流式输出进行中再发请求会导致崩溃
- **所有 AI stream 必须保存为 `StreamSubscription`**：页面 dispose 时 cancel，防止后台继续调用已释放的 engine
- **切换模型需要延迟**：dispose 旧 engine 后需 `Future.delayed(500ms)` 让 GPU/内存资源回收，再 create 新 engine
- **推理不可中断**：LiteRT-LM native 层无法安全中断进行中的推理（MethodChannel 阻塞、cooperative cancellation 无效）。UI 上不提供停止按钮，推理开始后等待完成。推理中禁用发送按钮并显示 loading indicator
- **轻量场景（greeting/game）的 `.listen()` 必须 try-catch 包裹**：engine 状态异常时不能让 app 崩溃
- **不要尝试实现 cancelStream / 中断推理**：已验证 native FFI dispose 会阻塞 Dart main isolate 直到推理完成，无论是 fire-and-forget、requestId 失效、还是 coroutine Job.cancel() 都无法避免 UI 卡死

### Gotchas

- **Dart SDK**: Project uses `>=2.12.0 <4.0.0` — switch cases need `break` statements (no Dart 3 exhaustive patterns)
- **Android minSdk**: Must be ≥24 for `flutter_litert_lm`
- **flutter analyze**: This project has many pre-existing `info` lint warnings (file_names, prefer_const, etc.) — only `error` level matters
- **image_picker**: iOS needs `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription` in Info.plist; Android needs `<uses-permission android:name="android.permission.CAMERA" />` in manifest
- **flutter_litert_lm multimodal API**: `conversation.sendMultimodalMessage(List<LiteLmContent>)` — non-streaming; `sendMessageStream(String)` — streaming but text-only
- **flutter_litert_lm fork**: `plugins/flutter_litert_lm/` 是必要 fork — 升级 litertlm-android 到 0.11.0 并添加 `maxNumImages` 参数，修复 vision SIGSEGV。待上游 pub 包更新后可移除
- **record package**: `record_linux` 与 `record_platform_interface` 版本不兼容会导致 Android build 失败。通过 `dependency_overrides` 中 `record_linux: ^1.3.0` 解决
- **NoteAccessSqlite API**: 添加笔记用 `db.addNote(note)`；删除用 `db.deleteNoteItem(item)`；更新内容用 `db.updateNoteItemContent(id, text)`
- **bin/ 目录已 gitignore**：APK release 文件上传到 GitHub Release，不 commit 到 git（GitHub 100MB 文件限制）
- **getConfig 必须先 ensureConfig**：`db.getConfig(key)` 内部用 `.first`，key 不存在时抛 StateError。任何新增 config key 必须先调 `db.ensureConfig(key, defaultValue)` 再 `getConfig`
- **Drag-drop 排序策略**：区间重编号 `renumberRangeSequences(items, lo, hi, step: 1024)`，只更新受影响的 [lo..hi] 区间，整数步进，不用中点插入也不全量重排
- **McpService.onContextReady 回调**：`fetchContextOnModelReady` 完成后通过 `setContextCache` 触发回调通知 UI 刷新，页面 dispose 时需置 null
- **iOS build**: 需 `brew install cocoapods`（系统 Ruby 的 pod 有 ffi 兼容问题）；deployment target >= 14.0（file_picker 要求）