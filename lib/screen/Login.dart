import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../i18n/SimpleLocalizations.dart';
import 'NoteLanding.dart';

class Login extends StatefulWidget {
  static final String routeName = '/Login';

  @override
  _LoginState createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final LocalAuthentication _localAuth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
  }

  Future<bool> _auth(context) async {
    if (!await deviceSupported()) {
      return true;
    }

    if (await authenticateIsAvailable()) {
      try {
        final reason = SimpleLocalizations.of(context)!.getText('reason')!;
        return await this._localAuth.authenticate(
            localizedReason: reason,
            options: const AuthenticationOptions(
                biometricOnly: true, stickyAuth: true));
      } catch (e) {
        print(e.toString());
      }
    }
    return false;
  }

  Future<bool> deviceSupported() async {
    return await _localAuth.isDeviceSupported();
  }

  Future<bool> authenticateIsAvailable() async {
    return await _localAuth.canCheckBiometrics;
  }

  Future<void> _auth_login(context) async {
    final success = await this._auth(context);
    if (success) {
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
