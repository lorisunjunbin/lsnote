import 'AiService.dart';
import 'McpService.dart';

class AiPrompts {
  static String get _ctx => AiService.instance.contextInfo;
  static String get _lang =>
      AiService.instance.language == 'zh' ? 'Reply in Simplified Chinese.' : '';

  // === Lightweight scenes (completeStream, short output) ===

  static String greeting(String topic) {
    final mcpCtx = McpService.instance.contextCache;
    if (mcpCtx.isNotEmpty) {
      return 'You are a witty, humorous assistant in a note app. Today\'s context:\n$mcpCtx\nGenerate a single short greeting incorporating today\'s date, weather, or notable info from context above (1 sentence, under 25 words). Be warm and informative. NEVER repeat. Output ONLY the greeting. $_lang';
    }
    return 'You are a witty, humorous assistant in a note app. Generate a single short funny greeting about "$topic" (1 sentence, under 20 words). Be creative, use wordplay. NEVER repeat a previous greeting. Output ONLY the greeting. $_lang';
  }

  static String colorCompliment(String colorName) =>
      'You are a cheerful assistant. Give a single short compliment about the color "$colorName" (under 15 words). Be creative and fun. NEVER repeat. Output ONLY the compliment. $_lang';

  static String gameHint() =>
      'You are a game assistant for 1A2B number guessing. A=correct digit in correct spot, B=correct digit wrong spot. Give a short encouraging hint (under 15 words). Do NOT reveal the answer. NEVER repeat. Output ONLY the hint. $_lang';

  static String gameWin() =>
      'You are a game assistant. The player just won! Give a short fun congratulation (under 15 words). Be creative. NEVER repeat. Output ONLY the congrats. $_lang';

  // === Note editing (completeStreamNoThink, medium output) ===

  static String organize() =>
      '$_ctx\nOrganize this text into structured bullet points. Keep all info. Output only the result.';

  static String polish() =>
      '$_ctx\nImprove grammar and clarity. Keep meaning. Output only the result.';

  static String continueWriting() =>
      '$_ctx\nThe text below is unfinished. Continue writing from where it stops, matching style and topic. Produce at least one new paragraph. Output ONLY the continuation, no preface, no acknowledgement.';

  static const String translate =
      'Translate: Chinese to English, English to Chinese. Output only the translation.';

  // === Multimodal (completeMultimodal / completeAudio) ===

  static String imageToNote() =>
      '$_ctx\nDescribe this image as structured note content. Output only the note.';

  static String transcribeAudio() =>
      '$_ctx\nTranscribe audio accurately. Output only the text.';

  // === AiChat (completeAudio with transcription + response) ===

  static String chatAudio() =>
      '$_ctx\nFirst transcribe the audio as [Transcription]: text, then answer the question. Separate with blank line.';

  static String chatImage() =>
      '$_ctx\nAnalyze the image and respond to the user.';

  // === Landing page note assist (completeStream, medium output) ===

  static String summarize() =>
      'Summarize into concise bullet points. $_ctx';

  static String improveGrammar() =>
      'Improve grammar and clarity. Keep meaning. $_ctx';

  static String landingContinue() =>
      'Continue writing, match style and topic. $_ctx';

  // === Landing page audio transcription ===

  static String landingTranscribe() =>
      '$_ctx\nTranscribe audio accurately. Output only the text.';

  static String extractNoteStructure() =>
      'Extract a concise title and the full content from the following note text. Format your response EXACTLY as:\nTITLE: <title>\nCONTENT: <content>\nThe title should be a short phrase (under 15 words) summarizing the main point. The content is the complete text. $_lang';

  // === Landing page note organize (inline) ===

  static String landingOrganize() =>
      'Organize into structured note with bullet points. Keep all info. No preamble. $_ctx';

  // === MCP context summarization ===

  static String summarizeContext() =>
      'Summarize the following raw data into a vivid daily info card. Rules:\n- Each piece of info on its own line\n- Start each line with a fitting emoji (e.g. ☀️ weather, 📅 date, 🌙 lunar, 🧧 holiday, 🎯 auspicious)\n- Include: weather, lunar date, Ganzhi date (天干地支, from "ganzhi" field), holidays, auspicious activities if available\n- Keep each line concise (under 20 words)\n- No title, no heading, no extra blank lines\n- Output ONLY the lines. $_lang';

  // === Color recommendation ===

  static String recommendColor(String context, List<String> colorNames) {
    final colors = colorNames.join(', ');
    final ctx = context.isNotEmpty
        ? 'Based on today\'s context:\n$context\n'
        : '';
    return '${ctx}Pick ONE color from this list that best matches today\'s mood/weather/season: [$colors]. Output ONLY the color name, nothing else.';
  }

  // === Chat session title ===

  static String sessionTitle() =>
      'Generate a short title (under 10 words) summarizing this conversation. Output ONLY the title, no quotes. $_lang';

  // === Chat conversation system prompts ===

  static const String chatDefault = 'You are a helpful assistant.';

  static String chatWithNote(String title, String content) =>
      '$_ctx The user has shared a note for context:\nTitle: $title\nContent: $content\n\nHelp the user with questions about this note.';

  static String chatBase() => '$_ctx $chatDefault';

  static const String chatToolInstruction =
      '\n\nWhen using tools: extract parameters directly from the user\'s message. Use default values or empty string for unmentioned optional parameters. Do NOT ask the user to confirm parameters — call the tool immediately. If a tool call fails, adjust the parameters based on the error and retry once. Only ask the user for clarification if the retry also fails.';
}
