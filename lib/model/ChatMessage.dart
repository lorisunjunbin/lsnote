class ChatMessage {
  final String role;
  final String content;
  final String? imagePath;
  final String? audioPath;
  final String? thinkingContent;
  final DateTime timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    this.imagePath,
    this.audioPath,
    this.thinkingContent,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, String> toApiMap() => {
        'role': role,
        'content': content,
      };
}
