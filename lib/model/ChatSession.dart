class ChatSession {
  final int? id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int messageCount;

  ChatSession({
    this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
  });

  ChatSession.fromJsonMap(Map<String, dynamic> map)
      : id = map['id'] as int,
        title = map['title'] as String? ?? '',
        createdAt = DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
        updatedAt = DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
        messageCount = map['messageCount'] as int? ?? 0;
}
