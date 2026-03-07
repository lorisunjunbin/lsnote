import 'package:flutter/foundation.dart';
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
  bool _isAuthenticating = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _authLogin(context);
    });
  }

  Future<bool> _auth(BuildContext context) async {
    if (kIsWeb) {
      return true;
    }

    final supported = await _localAuth.isDeviceSupported();
    final canCheckBiometrics = await _localAuth.canCheckBiometrics;
    if (!supported || !canCheckBiometrics) {
      return true;
    }

    try {
      final reason = SimpleLocalizations.of(context)!.getText('reason')!;
      return await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
      );
    } catch (_) {
      _setError('Authentication failed. Please try again.');
      return false;
    }
  }

  void _setError(String text) {
    if (!mounted) return;
    setState(() {
      _errorText = text;
    });
  }

  Future<void> _authLogin(BuildContext context) async {
    if (_isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _errorText = null;
    });

    final success = await _auth(context);
    if (!mounted) return;

    setState(() {
      _isAuthenticating = false;
    });

    if (success) {
      Navigator.of(context).pushReplacementNamed(NoteLanding.routeName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAuthenticating) const CircularProgressIndicator(),
            if (!_isAuthenticating)
              IconButton(
                color: Theme.of(context).primaryColorDark,
                icon: const Icon(Icons.fingerprint),
                iconSize: 80,
                onPressed: () => _authLogin(context),
              ),
            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _errorText!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
