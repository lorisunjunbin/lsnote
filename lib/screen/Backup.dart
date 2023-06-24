import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

import '../i18n/SimpleLocalizations.dart';
import '../model/Note.dart';
import '../service/NoteAccessSqlite.dart';
import 'NoteLanding.dart';

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
    final sl = SimpleLocalizations.of(context);

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
                  tooltip: sl?.getText('exportToJSON'),
                  icon: Icon(Icons.file_upload_outlined),
                  onPressed: () async {
                    await _populateJsonExport();
                  }),
              IconButton(
                  tooltip: sl?.getText('importFromJSON'),
                  icon: Icon(_restore_disabled
                      ? Icons.file_download_off
                      : Icons.file_download),
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
                      await db.addOrUpdateNote(note);
                    });

                    showDialog<void>(
                      context: context,
                      barrierDismissible: false, // user must tap button!
                      builder: (context) {
                        return AlertDialog(
                            title:
                                Text(sl?.getText('messageLabel') ?? 'Message'),
                            content: Text((sl?.getText('successImportLabel') ??
                                    'success') +
                                (notes.length.toString())),
                            actions: <Widget>[
                              TextButton(
                                  child: Text(sl?.getText('noticed') ?? 'OK'),
                                  onPressed: () => Navigator.of(context).pop())
                            ]);
                      },
                    );
                  })
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _textCtlr,
                onChanged: (val) =>
                    setState(() => _restore_disabled = val.isEmpty),
                keyboardType: TextInputType.multiline,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
              )
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
