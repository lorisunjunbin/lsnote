# AI Chat Markdown 渲染设计

## Goal

将 AI Chat 中 AI 回复的 Markdown 语法渲染为可选择的富文本，提升阅读体验。

---

## 支持语法

| 语法 | 示例 | 渲染效果 |
|------|------|----------|
| 粗体 | `**text**` | fontWeight: w600 |
| 斜体 | `*text*` | fontStyle: italic |
| 行内代码 | `` `code` `` | 等宽字体 + surfaceContainerHighest 背景 |
| 代码块 | ```` ``` ... ``` ```` | Container + 等宽字体 12px + 圆角 8px 背景 |
| 无序列表 | `- item` | • + 左缩进 12px |
| 有序列表 | `1. item` | 数字 + 左缩进 12px |

**不支持**：嵌套语法（粗体内斜体）、标题层级、表格、链接、图片、语法高亮。

---

## Architecture

### 新增文件

**`lib/utils/MarkdownParser.dart`**

纯函数模块，职责：
- `List<InlineSpan> parseMarkdown(String text, TextStyle baseStyle, ColorScheme colorScheme)`
- 输入原始文本字符串，输出 Flutter `InlineSpan` 列表（`TextSpan` + `WidgetSpan`）
- 可直接传入 `SelectableText.rich(TextSpan(children: result))`

解析策略：
1. 按 `\n` 拆行
2. 检测代码块围栏（``` 行），在代码块状态内收集原始文本
3. 非代码块行：检测列表前缀（`- ` 或 `1. `），剥离前缀后进入行内解析
4. 行内解析：正则匹配 `**...**`、`*...*`、`` `...` ``，其余为普通文本
5. 最终拼接所有行的 span，行间用 `\n` TextSpan 分隔

### 修改文件

**`lib/screen/AiChat.dart`**
- `_buildMessageBubble` 中 AI 消息的 `SelectableText` 替换为 `SelectableText.rich`
- 调用 `parseMarkdown(msg.content, baseTextStyle, colorScheme)`
- 用户消息保持纯 `SelectableText`（不做 Markdown 解析）
- 流式输出时每次 setState 都重新 parse 当前 buffer（单条消息 < 2KB，无性能问题）

---

## 样式规范

```dart
// 粗体
TextStyle(fontWeight: FontWeight.w600)

// 斜体
TextStyle(fontStyle: FontStyle.italic)

// 行内代码
TextStyle(
  fontFamily: 'monospace',
  fontSize: baseStyle.fontSize! - 1,
  backgroundColor: colorScheme.surfaceContainerHighest,
)

// 代码块 — WidgetSpan 包裹 Container
Container(
  width: double.infinity,
  margin: EdgeInsets.symmetric(vertical: 4),
  padding: EdgeInsets.all(10),
  decoration: BoxDecoration(
    color: colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(8),
  ),
  child: SelectableText(
    codeContent,
    style: TextStyle(fontFamily: 'monospace', fontSize: 12),
  ),
)

// 列表项 — WidgetSpan 包裹 Row
Padding(
  padding: EdgeInsets.only(left: 12),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('• ', style: baseStyle),  // 或数字
      Expanded(child: Text.rich(TextSpan(children: inlineSpans))),
    ],
  ),
)
```

---

## 边界与约束

- **不处理嵌套**：`***bold italic***` 不支持，按最外层匹配
- **不做语法高亮**：代码块统一等宽字体，不区分语言
- **流式安全**：未闭合的 ``` 在流式中视为普通文本，下一次 parse 闭合后自动修正
- **仅 AI 消息**：用户发送的文本不做 Markdown 渲染
- **SelectableText.rich 限制**：WidgetSpan 内部不支持选择，代码块内用独立 SelectableText 补偿
- **性能**：每次 setState 重新 parse，对 < 5KB 文本无感知延迟

---

## i18n

无需新增 i18n key（纯视觉渲染，无用户可见文字）。

---

## 测试验证

1. 发送包含 `**粗体**` 的消息 → 渲染为加粗
2. 发送包含 `` `code` `` → 渲染为等宽+灰底
3. 发送包含 ``` 代码块 → 渲染为容器+等宽
4. 发送 `- item1\n- item2` → 渲染为带 bullet 的列表
5. 流式输出中出现未闭合 ``` → 不崩溃，闭合后自动渲染为代码块
6. 用户消息不做任何 Markdown 渲染
7. 深色模式下对比度正常
