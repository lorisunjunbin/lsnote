import 'dart:io';

import 'package:async/async.dart';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../model/Note.dart';
import '../model/Config.dart';

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
        _dbPath = join(dbFolder, _dbFileName);
        ////print(_dbPath);

        _database = await openDatabase(_dbPath!, version: 1,
            onCreate: (Database db, int version) async {
          for (String sql in _initSQLs) {
            await db.execute(sql);
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

  Future<List<Note>> getNotes(Map<String, dynamic> params) async {
    List<Map<String, dynamic>> jsons = await getNotesAllInJson(params);
    //print('getNotes - ${jsons.length} rows retrieved from db!');
    return jsons.map((json) => Note.fromJsonMap(json)).toList();
  }

  Future<List<Note>> getNotesAll() async {
    return getNotes({});
  }

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
    sql += ' order by sequence ';

    //print('sql - $sql, paramValues - $paramValues');

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
            (title, content, sequence, isDone, targetDate)
          VALUES
            (
              "${note.title}",
              "${note.content}",
              "${note.sequence}",
              ${note.isDone ? 1 : 0}, 
              ${note.targetDate?.millisecondsSinceEpoch}
            )''');
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
      SET content = ?, title = ?, sequence = ?, isDone = ?, targetDate = ?
      WHERE id = ?''',
      [
        note.content,
        note.title,
        note.sequence,
        note.isDone,
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

  NoteAccessSqlite._internal();
}

final db = NoteAccessSqlite();
