import 'package:flutter/material.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/Note.dart';
import '../service/NoteAccessSqlite.dart';
import 'notelanding/NoteLanding.dart';

class NoteItem extends StatefulWidget {
  static final String routeName = '/NoteItem';

  @override
  _NoteItemState createState() => _NoteItemState();
}

class _NoteItemState extends State<NoteItem> {
  static DateTime _datetime = DateTime.now();
  var _titleCtl = TextEditingController();
  var _contentCtl = TextEditingController();

  void _back2Home(BuildContext context) {
    Navigator.popAndPushNamed(context, NoteLanding.routeName);
  }

  Future<bool> _onBackPressed() {
    Navigator.popAndPushNamed(context, NoteLanding.routeName);
    return Future.value(true);
  }

  @override
  void dispose() {
    _contentCtl.dispose();
    _titleCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color _primaryColor = Theme.of(context).primaryColorDark;
    SimpleLocalizations sl = SimpleLocalizations.of(context);

    return WillPopScope(
      onWillPop: _onBackPressed,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded),
            onPressed: () => _back2Home(context),
          ),
          elevation: 2.0,
        ),
        body: Padding(
            padding: const EdgeInsets.all(32.0),
            child: ListView(children: <Widget>[
              _buildNoteTitleTextField(context, sl),
              _buildNoteDetailTextField(sl),
              Text(''),
              _buildDatepickerMaterialButton(context, sl, _primaryColor),
              const Divider(),
              _buildSaveIconButton(_primaryColor, context)
            ])),
      ),
    );
  }

  TextField _buildNoteTitleTextField(
      BuildContext context, SimpleLocalizations sl) {
    return TextField(
      keyboardType: TextInputType.text,
      style: Theme.of(context).textTheme.headline5,
      decoration: InputDecoration(
        labelText: sl.getText('titleLabel'),
      ),
      controller: _titleCtl,
    );
  }

  TextField _buildNoteDetailTextField(SimpleLocalizations sl) {
    return TextField(
      maxLines: 5,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: sl.getText('contentLabel'),
      ),
      controller: _contentCtl,
    );
  }

  MaterialButton _buildDatepickerMaterialButton(
      BuildContext context, SimpleLocalizations sl, Color _primaryColor) {
    return MaterialButton(
      onPressed: () {
        showDatePicker(
          context: context,
          initialDate: _datetime,
          firstDate: DateTime.parse("2020-01-01"),
          lastDate: DateTime.parse("2030-12-31"),
          cancelText: sl.getText('cancelLabel'),
          confirmText: sl.getText('confirmLabel'),
        ).then((value) {
          if (value != null) {
            setState(() {
              _datetime = value;
            });
          }
        });
      },
      child: Text('${_datetime?.toString()?.substring(0, 10)}',
          style: new TextStyle(
            fontSize: 22.0,
            color: _primaryColor,
          )),
    );
  }

  IconButton _buildSaveIconButton(Color _primaryColor, BuildContext context) {
    return IconButton(
        icon: Icon(Icons.save_rounded),
        color: _primaryColor,
        iconSize: 60,
        onPressed: () async {
          if (_titleCtl.value.text == null || _titleCtl.value.text.isEmpty)
            return;

          int total = await db.getNoteCount();

          db.addNote(Note(
              title: _titleCtl.value.text,
              content: _contentCtl.value.text,
              sequence: total * -1000.0,
              isDone: _datetime.isBefore(DateTime.now()) ?? true,
              targetDate: _datetime));

          _back2Home(context);

          setState(() {
            _datetime = DateTime.now();
          });
        });
  }
}
