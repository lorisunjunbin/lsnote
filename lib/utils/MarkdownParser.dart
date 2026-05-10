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

    final headingMatch = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
    if (headingMatch != null) {
      final level = headingMatch.group(1)!.length;
      final content = headingMatch.group(2)!;
      final bump = 4 - level; // # → +3, ## → +2, ### → +1
      spans.add(TextSpan(
        text: content,
        style: baseStyle.copyWith(
          fontSize: (baseStyle.fontSize ?? 13) + bump,
          fontWeight: FontWeight.w700,
          height: 1.6,
        ),
      ));
      if (i < lines.length - 1) spans.add(const TextSpan(text: '\n'));
      continue;
    }

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
      spans.addAll(_parseInline(line, baseStyle, colorScheme));
    }

    if (i < lines.length - 1) {
      spans.add(const TextSpan(text: '\n'));
    }
  }

  if (inCodeBlock) {
    spans.add(
        TextSpan(text: '```\n${codeBuffer.toString()}', style: baseStyle));
  }

  return spans;
}

List<InlineSpan> _parseInline(
    String text, TextStyle baseStyle, ColorScheme colorScheme) {
  final spans = <InlineSpan>[];
  final regex = RegExp(r'(\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`)');
  int lastEnd = 0;

  for (final match in regex.allMatches(text)) {
    if (match.start > lastEnd) {
      spans.add(TextSpan(
          text: text.substring(lastEnd, match.start), style: baseStyle));
    }

    if (match.group(2) != null) {
      spans.add(TextSpan(
        text: match.group(2),
        style: baseStyle.copyWith(fontWeight: FontWeight.w600),
      ));
    } else if (match.group(3) != null) {
      spans.add(TextSpan(
        text: match.group(3),
        style: baseStyle.copyWith(fontStyle: FontStyle.italic),
      ));
    } else if (match.group(4) != null) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            match.group(4)!,
            style: baseStyle.copyWith(
              fontFamily: 'monospace',
              fontSize: (baseStyle.fontSize ?? 13) - 1,
            ),
          ),
        ),
      ));
    }

    lastEnd = match.end;
  }

  if (lastEnd < text.length) {
    spans.add(TextSpan(text: text.substring(lastEnd), style: baseStyle));
  }

  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: baseStyle));
  }

  return spans;
}

WidgetSpan _buildCodeBlockSpan(String code, ColorScheme colorScheme) {
  return WidgetSpan(
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        code,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 11.5,
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
      padding: const EdgeInsets.only(left: 8),
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
