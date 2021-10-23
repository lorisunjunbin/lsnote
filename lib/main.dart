import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'changenotifier/GuessItemChangeNotifier.dart';
import 'changenotifier/SwitcherChangeNotifier.dart';
import 'changenotifier/ThemeChangeNotifier.dart';

import 'NoteApp.dart';

void main() => runApp(MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeChangeNotifier>(
            create: (_) => ThemeChangeNotifier()),
        ChangeNotifierProvider<SwitcherChangeNotifier>(
            create: (_) => SwitcherChangeNotifier()),
        ChangeNotifierProvider<GuessitemChangeNotifier>(
            create: (_) => GuessitemChangeNotifier())
      ],
      child: NoteApp(),
    ));
