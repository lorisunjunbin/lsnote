# MCP Tool Calling Integration Design

## Goal

为 lsnote AI Chat 增加 MCP（Model Context Protocol）工具调用能力，支持：
1. app 启动后模型加载完成时自动预取基础信息（天气、节日等）并注入对话上下文
2. AI Chat 中模型自主决策调用 MCP 工具，聊天界面显示调用过程
3. 其他 AI 场景（NoteLanding 等）静默使用预取缓存

---

## Architecture

### 新增文件

**`lib/service/McpService.dart`**
MCP 单例服务，职责：
- 从 SQLite 加载/保存 MCP 配置（URL、token、enabled）
- `fetchContextOnModelReady()`：调用 `tools/list`，识别天气/节日类基础工具并调用，结果缓存为纯文本 `contextCache`
- `callTool(name, args)`：HTTP POST `tools/call`，返回结果字符串
- `tools`：返回 `List<LiteLmTool>`，供 AI Chat conversation 注入

**`lib/model/McpTool.dart`**
从 MCP `tools/list` 响应解析的工具定义：
```dart
class McpTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema; // JSON Schema
}
```

### 修改文件

- `lib/service/AiService.dart` — 模型加载成功后调用 `McpService.instance.fetchContextOnModelReady()`
- `lib/screen/AiChat.dart` — conversation 注入工具列表；处理 `toolCalls`；显示工具气泡；重构设置弹窗布局
- `lib/i18n/SimpleLocalizations.dart` — 新增 MCP 相关字符串
- `NoteApp.dart` — `_asyncInit()` 中 `ensureConfig()` 新增 3 个 MCP config key
- `CLAUDE.md` — 记录 McpService 架构

---

## Data Flow

```
App 启动
  └─ NoteApp._asyncInit() → ensureConfig(mcpEnabled/mcpServerUrl/mcpAuthHeader)
       └─ McpService.instance.init()  ← 加载配置到内存

模型加载完成（AiService._loadModel 成功）
  └─ McpService.instance.fetchContextOnModelReady()
       ├─ isEnabled == false → 跳过
       ├─ GET {url}/tools/list → 解析工具列表，存 _tools
       ├─ 筛选 context 类工具（天气/节日/时间，按名称模糊匹配）
       ├─ 逐一 POST {url}/tools/call → 拼接结果
       └─ _contextCache = 拼接后的纯文本；_isReady = true

AI Chat 发消息
  ├─ createConversation 时注入 McpService.instance.tools 为 LiteLmTool 列表
  ├─ 模型回复 message.toolCalls 非空
  │    ├─ 插入"正在调用 {name}..."工具气泡（MessageType.toolCall）
  │    ├─ McpService.instance.callTool(name, args) → result
  │    ├─ 插入"✓ {name} 返回: {result}"工具结果气泡（MessageType.toolResult）
  │    └─ conversation.sendToolResponse(name, result) → 继续推理，等待下一条消息
  └─ 最终 AI 文字回复气泡

NoteLanding / completeStream 场景
  └─ extraContext 附加 McpService.instance.contextCache（非空时）
```

---

## HTTP Protocol

协议：HTTP JSON-RPC 2.0，使用 `dart:io HttpClient`（已有依赖，无需新增 package）

**tools/list**
```
GET {mcpServerUrl}/tools/list
Authorization: Bearer {token}
```
响应：
```json
{
  "tools": [
    {
      "name": "get_weather",
      "description": "Get current weather for a city",
      "inputSchema": {
        "type": "object",
        "properties": { "city": { "type": "string" } },
        "required": ["city"]
      }
    }
  ]
}
```

**tools/call**
```
POST {mcpServerUrl}/tools/call
Authorization: Bearer {token}
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "method": "tools/call",
  "params": { "name": "get_weather", "arguments": { "city": "Beijing" } }
}
```
响应：
```json
{
  "result": {
    "content": [{ "type": "text", "text": "北京 晴 26°C 湿度40%" }]
  }
}
```

超时：10 秒。预取失败静默忽略（catch all，不影响 app 启动）。

---

## SQLite Config Keys

在 `NoteApp._asyncInit()` 的 `ensureConfig()` 中新增：

| key | 默认值 | 说明 |
|-----|--------|------|
| `mcpEnabled` | `"0"` | MCP 功能开关 |
| `mcpServerUrl` | `""` | MCP server HTTP 地址 |
| `mcpAuthHeader` | `""` | Bearer token 值（不含 "Bearer " 前缀） |

---

## McpService API

```dart
class McpService {
  static final McpService instance = McpService._();

  bool get isEnabled    // mcpEnabled == "1" && mcpServerUrl 非空
  bool get isReady      // 预取已完成
  String get contextCache  // 预取结果纯文本，注入 extraContext
  List<LiteLmTool> get tools  // 供 conversation 注入

  Future<void> init()   // 从 SQLite 加载配置到内存
  Future<void> fetchContextOnModelReady()  // 预取 context 类工具
  Future<void> saveConfig({String? url, String? token, bool? enabled})  // 持久化

  Future<String> callTool(String name, Map<String, dynamic> args)  // HTTP tools/call
}
```

---

## AiChat 设置弹窗重布局

保留 BottomSheet 形式，内部改为 `ListView` + Section 分组，三个区块从上到下：

**Section 1：模型与推理**（最显眼，无需滚动即可看到）
- [加载模型] 按钮 + 当前状态（加载中 / 已就绪 / 错误）
- 后端选择（GPU / CPU）
- 模型路径显示
- [选择模型文件] [下载模型] 按钮

**Section 2：MCP 工具**
- 标题行右侧带 Switch 开关
- Server URL 输入框
- Bearer Token 输入框（obscureText）
- 状态指示（已就绪 / 加载中 / 未配置）
- [立即预取] 按钮

**Section 3：对话**
- 系统提示词输入框
- [清除对话历史] 按钮

---

## Chat 工具调用气泡

新增 `MessageType.toolCall` 和 `MessageType.toolResult` 两种消息类型。

**toolCall 气泡**（推理中，模型正在调用工具）：
- 背景：`colorScheme.surfaceContainerLow`
- 边框：`colorScheme.outline.withValues(alpha: 0.15)`
- 内容：`🔧 正在调用 {toolName}...` + CircularProgressIndicator（小）
- 左对齐（同 AI 消息）

**toolResult 气泡**（工具返回结果）：
- 背景：`colorScheme.surfaceContainerLow`
- 边框：`colorScheme.outline.withValues(alpha: 0.15)`
- 内容：`✓ {toolName}` 标题行 + 结果文本（可折叠，超过 3 行显示"展开"）
- 左对齐

---

## Error Handling

- **预取失败**：catch 所有异常，`_contextCache = ""`，`_isReady = false`，静默（不弹 toast）
- **Chat tool call 失败**：`callTool` 抛出异常时，`sendToolResponse` 传入错误描述字符串，让模型感知失败并告知用户
- **MCP 未启用**：`tools` 返回空列表，`contextCache` 返回空字符串，对现有逻辑零影响
- **模型不支持 tool calling**：工具列表注入后若模型从不返回 toolCalls，自然跳过，无副作用

---

## i18n Keys（新增）

```
mcpTools          → "MCP Tools" / "MCP 工具"
mcpServerUrl      → "Server URL" / "服务器地址"
mcpAuthToken      → "Bearer Token" / "认证令牌"
mcpEnabled        → "Enable MCP" / "启用 MCP"
mcpReady          → "Ready" / "已就绪"
mcpFetching       → "Fetching..." / "获取中..."
mcpNotConfigured  → "Not configured" / "未配置"
mcpFetchNow       → "Fetch Now" / "立即预取"
toolCalling       → "Calling {name}..." / "正在调用 {name}..."
toolResult        → "{name} returned" / "{name} 返回"
modelAndInference → "Model & Inference" / "模型与推理"
conversation      → "Conversation" / "对话"
```
