# AI Chat Markdown Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 AI Chat 中 AI 回复的 Markdown 语法（粗体/斜体/行内代码/代码块/列表）渲染为可选择的富文本。

**Architecture:** 新增 `MarkdownParser.dart` 纯函数模块，将文本解析为 `InlineSpan` 列表。AiChat 中 AI 消息的 `SelectableText` 替换为 `SelectableText.rich`，传入解析结果。用户消息不做渲染。

**Tech Stack:** Flutter `TextSpan` / `WidgetSpan` / `SelectableText.rich`，正则表达式行内解析，无第三方依赖。

---

## File Map

| 文件 | 操作 | 职责 |
|------|------|------|
| `lib/utils/MarkdownParser.dart` | 新建 | Markdown → InlineSpan 列表的纯函数解析器 |
| `lib/screen/AiChat.dart` | 修改 | AI 消息气泡用 parseMarkdown 替换纯文本 |

---

## Task 1: MarkdownParser — 行内解析（粗体/斜体/行内代码）

**Files:**
- Create: `lib/utils/MarkdownParser.dart`

- [ ] **Step 1: 创建 MarkdownParser.dart，实现行内解析函数**

```dart
import 'package:flutter/material.dart';

List<InlineSpan> parseMarkdown(
    String text, TextStyle baseStyle, ColorScheme colorScheme) {
  if (text.isEmpty) return [];
  final lines = text.split('\n');
  final spans = <InlineSpan>[];
  bool inCodeBlock = false;
  final codeBuffer = StringBuffer();

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];

    // 代码块围栏检测
    if (line.trimLeft().startsWith('```')) {
      if (!inCodeBlock) {
        inCodeBlock = true;
        codeBuffer.clear();
      } else {
        inCodeBlock = false;
        spans.add(_buildCodeBlockSpan(
            codeBuffer.toString().trimRight(), colorScheme));
        if (i < lines.length - 1) {
          spans.add(const TextSpan(text: '\n'));
        }
      }
      continue;
    }

    if (inCodeBlock) {
      if (codeBuffer.isNotEmpty) codeBuffer.write('\n');
      codeBuffer.write(line);
      continue;
    }

    // 列表项检测
    final unorderedMatch = RegExp(r'^(\s*)[-*]\s+(.*)$').firstMatch(line);
    final orderedMatch = RegExp(r'^(\s*)(\d+)\.\s+(.*)$').firstMatch(line);

    if (unorderedMatch != null) {
      final content = unorderedMatch.group(2)!;
      spans.add(_buildListItemSpan('• ', content, baseStyle, colorScheme));
    } else if (orderedMatch != null) {
      final num = orderedMatch.group(2)!;
      final content = orderedMatch.group(3)!;
      spans.add(_buildListItemSpan('$num. ', content, baseStyle, colorScheme));
    } else {
      // 普通行 — 行内解析
      spans.addAll(_parseInline(line, baseStyle, colorScheme));
    }

    // 行间换行
    if (i < lines.length - 1) {
      spans.add(const TextSpan(text: '\n'));
    }
  }

  // 未闭合的代码块视为普通文本
  if (inCodeBlock) {
    spans.add(TextSpan(text: '```\n${codeBuffer.toString()}', style: baseStyle));
  }

  return spans;
}

List<InlineSpan> _parseInline(
    String text, TextStyle baseStyle, ColorScheme colorScheme) {
  final spans = <InlineSpan>[];
  final regex = RegExp(r'(\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`)');
  int lastEnd = 0;

  for (final match in regex.allMatches(text)) {
    // 匹配前的普通文本
    if (match.start > lastEnd) {
      spans.add(TextSpan(
          text: text.substring(lastEnd, match.start), style: baseStyle));
    }

    if (match.group(2) != null) {
      // **粗体**
      spans.add(TextSpan(
        text: match.group(2),
        style: baseStyle.copyWith(fontWeight: FontWeight.w600),
      ));
    } else if (match.group(3) != null) {
      // *斜体*
      spans.add(TextSpan(
        text: match.group(3),
        style: baseStyle.copyWith(fontStyle: FontStyle.italic),
      ));
    } else if (match.group(4) != null) {
      // `行内代码`
      spans.add(TextSpan(
        text: match.group(4),
        style: baseStyle.copyWith(
          fontFamily: 'monospace',
          fontSize: (baseStyle.fontSize ?? 14) - 1,
          backgroundColor: colorScheme.surfaceContainerHighest,
        ),
      ));
    }

    lastEnd = match.end;
  }

  // 匹配后剩余文本
  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
  }

  // 如果整行没有任何匹配
  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: baseStyle));
  }

  return spans;
}

WidgetSpan _buildCodeBlockSpan(String code, ColorScheme colorScheme) {
  return WidgetSpan(
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        code,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: colorScheme.onSurface,
          height: 1.4,
        ),
      ),
    ),
  );
}

WidgetSpan _buildListItemSpan(String bullet, String content,
    TextStyle baseStyle, ColorScheme colorScheme) {
  final inlineSpans = _parseInline(content, baseStyle, colorScheme);
  return WidgetSpan(
    child: Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(bullet, style: baseStyle),
          Expanded(
            child: Text.rich(TextSpan(children: inlineSpans)),
          ),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 2: 验证文件无静态错误**

```bash
flutter analyze lib/utils/MarkdownParser.dart
```

Expected: No issues found（或仅 info level）

- [ ] **Step 3: Commit**

```bash
git add lib/utils/MarkdownParser.dart
git commit -m "feat: add lightweight Markdown parser for AI Chat"
```

---

## Task 2: AiChat — 集成 Markdown 渲染

**Files:**
- Modify: `lib/screen/AiChat.dart:1-22` (imports)
- Modify: `lib/screen/AiChat.dart:1597-1607` (AI message rendering)

- [ ] **Step 1: 在 AiChat.dart 顶部添加 import**

在 `import '../utils/NavigationHelper.dart';` 之后添加：

```dart
import '../utils/MarkdownParser.dart';
```

- [ ] **Step 2: 替换 AI 消息的 SelectableText 为 Markdown 渲染**

找到 `_buildMessageBubble` 方法中的：

```dart
                      else if (msg.content.isNotEmpty && !(isUser && msg.audioPath != null))
                        SelectableText(
                          msg.content,
                          style: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
```

替换为：

```dart
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
```

- [ ] **Step 3: 验证**

```bash
flutter analyze lib/screen/AiChat.dart
```

Expected: No issues found（或仅 info level）

- [ ] **Step 4: Commit**

```bash
git add lib/screen/AiChat.dart
git commit -m "feat: render AI messages with Markdown formatting"
```

---

## Task 3: 集成验证

- [ ] **Step 1: 全量静态分析**

```bash
flutter analyze lib/
```

Expected: No error-level issues

- [ ] **Step 2: 构建 APK**

```bash
flutter build apk --debug --target-platform android-arm64
```

Expected: Build successful

- [ ] **Step 3: 手动测试 Checklist**

1. AI Chat 发送普通消息 → 正常渲染，无变化
2. AI 回复包含 `**粗体**` → 显示为加粗文字
3. AI 回复包含 `*斜体*` → 显示为斜体文字
4. AI 回复包含 `` `inline code` `` → 等宽字体 + 灰色背景
5. AI 回复包含 ``` 代码块 → 独立容器 + 等宽字体 + 圆角背景
6. AI 回复包含 `- item` → 带 bullet 的缩进列表
7. 用户发送 `**test**` → 显示为纯文本 `**test**`
8. 流式输出中未闭合 ``` → 不崩溃
9. 深色模式下代码块背景和文字对比度正常
10. 长按 AI 消息仍可选中文字

- [ ] **Step 4: Commit（如有修复）**

```bash
git add -A
git commit -m "fix: adjust Markdown rendering issues found during testing"
```
