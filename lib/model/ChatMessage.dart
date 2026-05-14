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

  ChatMessage.fromDbMap(Map<String, dynamic> map)
      : role = map['role'] as String,
        content = map['content'] as String? ?? '',
        imagePath = map['imagePath'] as String?,
        audioPath = map['audioPath'] as String?,
        thinkingContent = map['thinkingContent'] as String?,
        timestamp = DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
        messageType = _parseMessageType(map['messageType'] as String?),
        isExpanded = false;

  Map<String, dynamic> toDbMap(int sessionId) => {
        'sessionId': sessionId,
        'role': role,
        'content': content,
        'imagePath': imagePath,
        'audioPath': audioPath,
        'thinkingContent': thinkingContent,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'messageType': messageType.name,
      };

  static MessageType _parseMessageType(String? value) {
    if (value == 'toolCall') return MessageType.toolCall;
    if (value == 'toolResult') return MessageType.toolResult;
    return MessageType.text;
  }

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
