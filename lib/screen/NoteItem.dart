import 'package:flutter/material.dart';

import '../i18n/SimpleLocalizations.dart';
import '../model/Note.dart';
import '../service/NoteAccessSqlite.dart';
import '../utils/NavigationHelper.dart';
import 'NoteLanding.dart';

class NoteItem extends StatefulWidget {
  static final String routeName = '/NoteItem';

  @override
  _NoteItemState createState() => _NoteItemState();
}

class _NoteItemState extends State<NoteItem> {
  static DateTime _datetime = DateTime.now().add(Duration(days: 1));
  var _titleCtl = TextEditingController();
  var _contentCtl = TextEditingController();

  @override
  void dispose() {
    _contentCtl.dispose();
    _titleCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color _primaryColor = Theme.of(context).primaryColorDark;
    SimpleLocalizations sl = SimpleLocalizations.of(context)!;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: NavigationHelper.createPopCallback(
        context,
        NoteLanding.routeName,
      ),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_rounded),
            onPressed: () => NavigationHelper.replaceTo(
              context,
              NoteLanding.routeName,
            ),
          ),
          elevation: 2.0,
          title: Text(sl.getText('addNote') ?? 'Add Note'),
        ),
        body: Padding(
            padding: const EdgeInsets.all(24.0),
            child: ListView(children: <Widget>[
              _buildDatepickerCard(context, sl, _primaryColor),
              const SizedBox(height: 24),
              _buildNoteTitleTextField(context, sl),
              const SizedBox(height: 20),
              _buildNoteDetailTextField(sl),
              const SizedBox(height: 32),
              _buildSaveButton(_primaryColor, context, sl),
            ])),
      ),
    );
  }

  TextField _buildNoteTitleTextField(
      BuildContext context, SimpleLocalizations sl) {
    return TextField(
      keyboardType: TextInputType.text,
      style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 18),
      decoration: InputDecoration(
        labelText: sl.getText('titleLabel'),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      controller: _titleCtl,
    );
  }

  TextField _buildNoteDetailTextField(SimpleLocalizations sl) {
    return TextField(
      keyboardType: TextInputType.multiline,
      maxLines: 8,
      minLines: 5,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: sl.getText('contentLabel'),
        alignLabelWithHint: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      controller: _contentCtl,
    );
  }

  Widget _buildDatepickerCard(
      BuildContext context, SimpleLocalizations sl, Color _primaryColor) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
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
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Icon(Icons.calendar_today_rounded,
                  color: _primaryColor, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sl.getText('targetDate') ?? 'Target Date',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_datetime.toString().substring(0, 10)}',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: _primaryColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded,
                  color: Colors.grey[400], size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton(
      Color _primaryColor, BuildContext context, SimpleLocalizations sl) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        icon: const Icon(Icons.save_rounded, size: 24),
        label: Text(
          sl.getText('saveLabel') ?? 'Save',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 2,
        ),
        onPressed: () async {
          if (_titleCtl.value.text.isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content:
                    Text(sl.getText('titleRequired') ?? 'Title is required'),
                duration: const Duration(seconds: 2),
                behavior: SnackBarBehavior.floating,
              ),
            );
            return;
          }

          int total = await db.getNoteCount();

          db.addNote(Note(
              title: _titleCtl.value.text,
              content: _contentCtl.value.text,
              sequence: total * -NoteAccessSqlite.sequenceStep,
              isDone: false,
              targetDate: _datetime));

          NavigationHelper.replaceTo(context, NoteLanding.routeName);

          setState(() {
            _datetime = DateTime.now();
          });
        },
      ),
    );
  }
}
