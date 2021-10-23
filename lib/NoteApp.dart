import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:async/async.dart';

import 'i18n/SimpleLocalizations.dart';
import 'changenotifier/SwitcherChangeNotifier.dart';
import 'changenotifier/ThemeChangeNotifier.dart';
import 'service/NoteAccessSqlite.dart';
import 'model/Config.dart';
import 'screen/NoteItem.dart';
import 'screen/notelanding/NoteLanding.dart';
import 'screen/Login.dart';
import 'screen/Backup.dart';

class NoteApp extends StatelessWidget {
  final AsyncMemoizer _memoizer = AsyncMemoizer();

  Future<bool> _asyncInit(
      ThemeChangeNotifier tcn, SwitcherChangeNotifier scn) async {
    await _memoizer.runOnce(() async {
      await db.init();

      Config cfgPrimarySwatch = await db.getConfig(Config.primarySwatch);
      tcn.setTheme(ThemeData(
        primarySwatch: Colors.primaries[int.parse(cfgPrimarySwatch.value)],
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ));

      Config cfgHiddenDone = await db.getConfig(Config.hiddenDone);
      scn.setHiddenDone(cfgHiddenDone.value == '1' ? true : false);
    });
    return true;
  }

  @override
  Widget build(mainContext) {
    final themeNotifier = Provider.of<ThemeChangeNotifier>(mainContext);
    final switcherProvider = Provider.of<SwitcherChangeNotifier>(mainContext);

    return FutureBuilder(
        future: _asyncInit(themeNotifier, switcherProvider),
        builder: (context, snapshot) {
          return GestureDetector(
            onTap: () {
              WidgetsBinding.instance.focusManager.primaryFocus?.unfocus();
            },
            child: MaterialApp(
                localeResolutionCallback:
                    (Locale locale, Iterable<Locale> supportedLocales) {
                  for (var value in supportedLocales) {
                    if (locale.languageCode == value.languageCode) return value;
                  }

                  return supportedLocales.first;
                },
                localizationsDelegates: [
                  const SimpleLocalizationsDelegate(),
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                ],
                supportedLocales: [
                  const Locale('en', ''), //should be always first.
                  const Locale.fromSubtags(languageCode: 'zh'),
                ],
                debugShowCheckedModeBanner: false,
                theme: themeNotifier.getTheme(),
                initialRoute: Login.routeName,
                routes: <String, WidgetBuilder>{
                  Login.routeName: (context) => Login(),
                  NoteLanding.routeName: (context) => NoteLanding(
                      title: SimpleLocalizations.of(context).getText('title')),
                  NoteItem.routeName: (context) => NoteItem(),
                  Backup.routeName: (context) => Backup()
                }),
          );
        });
  }
}
