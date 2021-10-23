class Note {
  final int id;
  final String title;
  final String content;
  num sequence;

  // SQLite doesn't supprot boolean. Use INTEGER/BIT (0/1 values).
  bool isDone;

  // SQLite doesn't supprot DateTime. Store them as INTEGER (millisSinceEpoch).
  final DateTime targetDate;

  Note(
      {this.id,
      this.title,
      this.content,
      this.sequence,
      this.isDone = false,
      this.targetDate});

  Note.fromJsonMap(Map<String, dynamic> map)
      : id = map['id'] as int,
        title = map['title'] as String,
        content = map['content'] as String,
        sequence = map['sequence'] as num,
        isDone = map['isDone'] == 1,
        targetDate =
            DateTime.fromMillisecondsSinceEpoch(map['targetDate'] as int);

  Map<String, dynamic> toJsonMap() => {
        'id': id,
        'title': title,
        'content': content,
        'sequence': sequence,
        'isDone': isDone ? 1 : 0,
        'targetDate': targetDate.millisecondsSinceEpoch,
      };

  Note.fromJsonMapThin(Map<String, dynamic> map)
      : id = map['i'] as int,
        title = map['t'] as String,
        content = map['c'] as String,
        sequence = map['s'] as num,
        isDone = map['d'] == 1,
        targetDate = DateTime.fromMillisecondsSinceEpoch(map['td'] as int);

  Map<String, dynamic> toJsonMapThin() => {
        'i': id,
        't': title,
        'c': content,
        's': sequence,
        'd': isDone ? 1 : 0,
        'td': targetDate.millisecondsSinceEpoch,
      };
}
