import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import '../model/Note.dart';
import '../service/NoteAccessSqlite.dart';
import 'notelanding/NoteLanding.dart';

import '../component/NumberPuzzles.dart';

class Backup extends StatefulWidget {
  static final String routeName = '/Backup';

  @override
  _BackupState createState() => _BackupState();
}

class _BackupState extends State<Backup> {
  bool _restore_disabled = true;
  final _textCtlr = TextEditingController();

  Future<bool> _onBackPressed() {
    Navigator.popAndPushNamed(context, NoteLanding.routeName);
    return Future.value(true);
  }

  @override
  Widget build(BuildContext context) {
    //https://medium.com/@iamatul_k/flutter-handle-back-button-in-a-flutter-application-override-back-arrow-button-in-app-bar-d17e0a3d41f
    return WillPopScope(
      onWillPop: _onBackPressed,
      child: Scaffold(
          appBar: AppBar(
            title: IconButton(
                icon: Icon(Icons.arrow_back_ios_sharp),
                onPressed: () {
                  Navigator.popAndPushNamed(context, NoteLanding.routeName);
                }),
            actions: [
              IconButton(
                  icon: Icon(Icons.content_copy_sharp),
                  onPressed: () async {
                    await _populateJsonExport();
                  }),
              IconButton(
                  icon: Icon(_restore_disabled
                      ? Icons.sync_disabled_sharp
                      : Icons.sync_sharp),
                  onPressed: () {
                    if (_restore_disabled) {
                      return;
                    }

                    List<dynamic> notesRaw =
                        JsonDecoder().convert(_textCtlr.value.text);
                    //print('notes: ${notesRaw}');

                    List<Note> notes = notesRaw
                        .map((notejson) => Note.fromJsonMapThin(
                            notejson as Map<String, dynamic>))
                        .toList();

                    notes.forEach((note) async {
                      await db.addNote(note);
                    });
                  })
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 1,
                child: TextFormField(
                  controller: _textCtlr,
                  onChanged: (val) =>
                      setState(() => _restore_disabled = val.isEmpty),
                  maxLines: 100,
                  textCapitalization: TextCapitalization.sentences,
                ),
              ),
              NumberPuzzles()
            ],
          )),
    );
  }

  Future _populateJsonExport() async {
    List<Note> notes = await db.getNotesAll();
    List<Map<String, dynamic>> notesInMap =
        notes.map((e) => e.toJsonMapThin()).toList();
    _textCtlr.text = JsonEncoder().convert(notesInMap);
  }

  @override
  void dispose() {
    _textCtlr.dispose();
    super.dispose();
  }
}
