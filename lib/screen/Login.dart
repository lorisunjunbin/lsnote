import 'package:flutter/material.dart';
import 'package:local_auth/auth_strings.dart';
import 'package:local_auth/local_auth.dart';

import '../i18n/SimpleLocalizations.dart';
import '../service/NoteAccessSqlite.dart';
import 'notelanding/NoteLanding.dart';

class Login extends StatefulWidget {
  static final String routeName = '/Login';

  @override
  _LoginState createState() => _LoginState();
}

class _LoginState extends State<Login> {
  LocalAuthentication _localAuth;

  @override
  void initState() {
    super.initState();
    this._localAuth = LocalAuthentication();
  }

  Future<void> _auth(context) async {
    db.authSuccess = false;

    if (await this._localAuth.canCheckBiometrics == false) {
      print('Your device is NOT capable of checking biometrics.\n'
          'Require android 6.0+ and fingerprint sensor.');
    }
    final sl = SimpleLocalizations.of(context);
    try {
      db.authSuccess = await this._localAuth.authenticateWithBiometrics(
          localizedReason: sl.getText('reason'),//'localizedReason',
          stickyAuth: true,
          androidAuthStrings: AndroidAuthMessages(
            signInTitle: sl.getText('signInTitle'),
            fingerprintHint: ' ',
          ));
    } catch (e) {
      print(e.toString());
    }
  }

  Future<void> _auth_login(context) async {
    await this._auth(context);
    if (db.authSuccess) {
      Navigator.of(context).pushReplacementNamed(NoteLanding.routeName);
    }
  }

  @override
  Widget build(context) {
    _auth_login(context);
    return Scaffold(
        body: Center(
            child: IconButton(
      color: Theme.of(context).primaryColorDark,
      icon: Icon(Icons.fingerprint),
      iconSize: 80,
      onPressed: () async => _auth_login(context),
    )));
  }
}
