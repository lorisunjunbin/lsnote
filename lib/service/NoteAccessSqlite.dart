import 'dart:io';

import 'package:async/async.dart';

import 'package:sqflite/sqflite.dart';

import '../model/Note.dart';
import '../model/Config.dart';
import '../model/ChatMessage.dart';
import '../model/ChatSession.dart';

// https://pub.dev/packages/sqflite
// https://www.sqlite.org/datatype3.html

//Singleton service
class NoteAccessSqlite {
  static final NoteAccessSqlite _noteAccessSqlite =
      new NoteAccessSqlite._internal();

  factory NoteAccessSqlite() {
    return _noteAccessSqlite;
  }

  static Database? _database;
  final AsyncMemoizer _memoizer = AsyncMemoizer();
  final String _dbFileName = 'ls_note.db';
  final List<String> _initSQLs = [
    '''
      CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY,
            title TEXT,
            content TEXT,
            sequence REAL,
            isDone BIT NOT NULL,
            isPinned BIT DEFAULT 0,
            targetDate INT)
     ''',
    '''
      CREATE TABLE IF NOT EXISTS config (
            id INTEGER PRIMARY KEY,
            name TEXT,
            value TEXT
      )
    ''',
    '''
      INSERT INTO config
            (name, value)
          VALUES
            ('primarySwatch','5');
    ''',
    '''
      INSERT INTO config
            (name, value)
          VALUES
            ('hiddenDone','1');
    ''',
    '''
      INSERT INTO config
            (name, value)
          VALUES
            ('aiModelPath','');
    ''',
    '''
      INSERT INTO config
            (name, value)
          VALUES
            ('aiBackend','gpu');
    ''',
    '''
      CREATE TABLE IF NOT EXISTS chat_sessions (
            id INTEGER PRIMARY KEY,
            title TEXT,
            createdAt INT,
            updatedAt INT,
            messageCount INT DEFAULT 0)
    ''',
    '''
      CREATE TABLE IF NOT EXISTS chat_messages (
            id INTEGER PRIMARY KEY,
            sessionId INT,
            role TEXT,
            content TEXT,
            imagePath TEXT,
            audioPath TEXT,
            thinkingContent TEXT,
            timestamp INT,
            messageType TEXT,
            FOREIGN KEY(sessionId) REFERENCES chat_sessions(id))
    '''
  ];

  bool authSuccess = false;
  String? _dbPath;

  Future<Database> init() async {
    if (_database == null) {
      await _memoizer.runOnce(() async {
        final dbFolder = await getDatabasesPath();
        if (!await Directory(dbFolder).exists()) {
          await Directory(dbFolder).create(recursive: true);
        }
        _dbPath = '$dbFolder/$_dbFileName';
        ////print(_dbPath);

        _database = await openDatabase(_dbPath!, version: 3,
            onCreate: (Database db, int version) async {
          for (String sql in _initSQLs) {
            await db.execute(sql);
          }
        }, onUpgrade: (Database db, int oldVersion, int newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
                'ALTER TABLE notes ADD COLUMN isPinned BIT DEFAULT 0');
          }
          if (oldVersion < 3) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS chat_sessions (
                id INTEGER PRIMARY KEY,
                title TEXT,
                createdAt INT,
                updatedAt INT,
                messageCount INT DEFAULT 0)
            ''');
            await db.execute('''
              CREATE TABLE IF NOT EXISTS chat_messages (
                id INTEGER PRIMARY KEY,
                sessionId INT,
                role TEXT,
                content TEXT,
                imagePath TEXT,
                audioPath TEXT,
                thinkingContent TEXT,
                timestamp INT,
                messageType TEXT,
                FOREIGN KEY(sessionId) REFERENCES chat_sessions(id))
            ''');
          }
        });
      });
    }
    return _database!;
  }

  Future<Config> getConfig(String key) async {
    List<Map<String, dynamic>> jsons =
        await _database!.rawQuery('select * from config where name=?', [key]);

    return jsons.map((json) => Config.fromJsonMap(json)).toList().first;
  }

  void setConfig(String name, String value) {
    //print('setConfig - $name = $value');

    _database!.rawUpdate(
      '''
      UPDATE config
      SET value = ?
      WHERE name = ?''',
      [value, name],
    );
  }

  Future<void> ensureConfig(String name, String defaultValue) async {
    final results = await _database!
        .rawQuery('SELECT * FROM config WHERE name=?', [name]);
    if (results.isEmpty) {
      await _database!.rawInsert(
        'INSERT INTO config (name, value) VALUES (?, ?)',
        [name, defaultValue],
      );
    }
  }

  Future<List<Note>> getNotes(Map<String, dynamic> params) async {
    List<Map<String, dynamic>> jsons = await getNotesAllInJson(params);
    //print('getNotes - ${jsons.length} rows retrieved from db!');
    return jsons.map((json) => Note.fromJsonMap(json)).toList();
  }

  Future<List<Note>> getNotesAll() async {
    return getNotes({});
  }

  static const int sequenceStep = 1024;

  Future<List<Map<String, dynamic>>> getNotesAllInJson(
      Map<String, dynamic> params) {
    String sql = 'SELECT * FROM notes ';
    List<dynamic> paramValues = [];
    params.forEach((key, value) {
      sql += key;
      if (value != null) {
        paramValues.add(value);
      }
    });
    sql += ' order by isPinned DESC, sequence, id ';

    return _database!.rawQuery(sql, paramValues);
  }

  Future<int> getNoteCount() async {
    final List<Map<String, dynamic>> jsons =
        await _database!.rawQuery("select count(*) as total from notes");
    return jsons[0]['total'];
  }

  Future<void> addOrUpdateNote(Note note) async {
    _database!.rawQuery('select * from notes where id=? and title=?',
        [note.id, note.title]).then((value) async {
      if (value.length > 0) {
        await updateNote(note);
      } else {
        await addNote(note);
      }
    });
  }

  Future<void> addNote(Note note) async {
    await _database!.transaction((Transaction txn) async {
      await txn.rawInsert('''
          INSERT INTO notes
            (title, content, sequence, isDone, isPinned, targetDate)
          VALUES
            (?, ?, ?, ?, ?, ?)''',
          [
            note.title,
            note.content,
            note.sequence,
            note.isDone ? 1 : 0,
            note.isPinned ? 1 : 0,
            note.targetDate?.millisecondsSinceEpoch,
          ]);
    });
  }

  Future<void> toggleNoteItem(Note note) async {
    await _database!.rawUpdate(
      '''
      UPDATE notes
      SET isDone = ?
      WHERE id = ?''',
      [if (note.isDone) 1 else 0, note.id],
    );
  }

  Future<void> toggleNotePinned(Note note) async {
    await _database!.rawUpdate(
      '''
      UPDATE notes
      SET isPinned = ?
      WHERE id = ?''',
      [note.isPinned ? 1 : 0, note.id],
    );
  }

  Future<void> updateNoteItemSequence(int? id, num? sequence) async {
    await _database!.rawUpdate(
      '''
      UPDATE notes
      SET sequence = ?
      WHERE id = ?''',
      [sequence, id],
    );
  }

  Future<void> updateNoteItemContent(int id, String content) async {
    //print('updateNoteItemContent $id - $content ');
    await _database!.rawUpdate(
      '''
      UPDATE notes
      SET content = ?
      WHERE id = ?''',
      [content, id],
    );
  }

  Future<void> updateNote(Note note) async {
    await _database!.rawUpdate(
      '''
      UPDATE notes
      SET content = ?, title = ?, sequence = ?, isDone = ?, isPinned = ?, targetDate = ?
      WHERE id = ?''',
      [
        note.content,
        note.title,
        note.sequence,
        note.isDone ? 1 : 0,
        note.isPinned ? 1 : 0,
        note.targetDate?.millisecondsSinceEpoch,
        note.id
      ],
    );
  }

  Future<void> deleteNoteItem(Note note) async {
    await _database!.rawDelete('''
        DELETE FROM notes
        WHERE id = ?
      ''', [note.id]);
  }

  Future<void> updateNoteSequence(int id, int sequence) async {
    await _database!.rawUpdate(
      'UPDATE notes SET sequence = ? WHERE id = ?',
      [sequence, id],
    );
  }

  // Only re-sequence the affected range [lo..hi] after a drag
  Future<void> renumberRangeSequences(List<Note> notes, int lo, int hi,
      {int step = sequenceStep}) async {
    await _database!.transaction((Transaction txn) async {
      final batch = txn.batch();
      for (var i = lo; i <= hi; i++) {
        final sequence = i * step;
        notes[i].sequence = sequence;
        batch.rawUpdate(
          'UPDATE notes SET sequence = ? WHERE id = ?',
          [sequence, notes[i].id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> renumberNoteSequences(List<Note> notes,
      {int step = sequenceStep}) async {
    await _database!.transaction((Transaction txn) async {
      final batch = txn.batch();
      for (var i = 0; i < notes.length; i++) {
        final sequence = i * step;
        notes[i].sequence = sequence;
        batch.rawUpdate(
          '''
      UPDATE notes
      SET sequence = ?
      WHERE id = ?''',
          [sequence, notes[i].id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ── Chat Session CRUD ──

  Future<int> createChatSession(String title) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return await _database!.rawInsert(
      'INSERT INTO chat_sessions (title, createdAt, updatedAt, messageCount) VALUES (?, ?, ?, 0)',
      [title, now, now],
    );
  }

  Future<List<ChatSession>> getChatSessions() async {
    final jsons = await _database!.rawQuery(
        'SELECT * FROM chat_sessions ORDER BY updatedAt DESC');
    return jsons.map((j) => ChatSession.fromJsonMap(j)).toList();
  }

  Future<void> deleteChatSession(int sessionId) async {
    await _database!.rawDelete(
        'DELETE FROM chat_messages WHERE sessionId = ?', [sessionId]);
    await _database!.rawDelete(
        'DELETE FROM chat_sessions WHERE id = ?', [sessionId]);
  }

  Future<void> updateChatSessionTitle(int id, String title) async {
    await _database!.rawUpdate(
      'UPDATE chat_sessions SET title = ? WHERE id = ?',
      [title, id],
    );
  }

  // ── Chat Message CRUD ──

  Future<void> addChatMessage(int sessionId, ChatMessage msg) async {
    final map = msg.toDbMap(sessionId);
    await _database!.insert('chat_messages', map);
    await _database!.rawUpdate(
      'UPDATE chat_sessions SET updatedAt = ?, messageCount = messageCount + 1 WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, sessionId],
    );
  }

  Future<List<ChatMessage>> getChatMessages(int sessionId) async {
    final jsons = await _database!.rawQuery(
        'SELECT * FROM chat_messages WHERE sessionId = ? ORDER BY timestamp ASC',
        [sessionId]);
    return jsons.map((j) => ChatMessage.fromDbMap(j)).toList();
  }

  NoteAccessSqlite._internal();
}

final db = NoteAccessSqlite();
