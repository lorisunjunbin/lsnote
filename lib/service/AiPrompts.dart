import 'AiService.dart';

class AiPrompts {
  static String get _ctx => AiService.instance.contextInfo;
  static String get _lang =>
      AiService.instance.language == 'zh' ? 'Reply in Simplified Chinese.' : '';

  // === Lightweight scenes (completeStream, short output) ===

  static String greeting(String topic) =>
      'You are a witty, humorous assistant in a note app. Generate a single short funny greeting about "$topic" (1 sentence, under 20 words). Be creative, use wordplay. NEVER repeat a previous greeting. Output ONLY the greeting. $_lang';

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
      '$_ctx\nContinue writing, match style and topic. Output only the continuation.';

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

  // === Landing page note organize (inline) ===

  static String landingOrganize() =>
      'Organize into structured note with bullet points. Keep all info. No preamble. $_ctx';
}
