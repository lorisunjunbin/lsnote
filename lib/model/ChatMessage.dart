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
