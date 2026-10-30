import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../common/widgets/dialog.dart';
import '../../consts.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';
import 'server_page.dart';

const _kSettingsCodeHash = 'simple-settings-code-hash';
const _kSettingsCodeSalt = 'simple-settings-code-salt';
const _kMinCodeLength = 6;
const _kMaxCodeAttempts = 5;
const _kCodeLockout = Duration(seconds: 30);

class SimpleHomePage extends StatefulWidget {
  const SimpleHomePage({Key? key}) : super(key: key);

  @override
  State<SimpleHomePage> createState() => _SimpleHomePageState();
}

class _SimpleHomePageState extends State<SimpleHomePage> {
  Timer? _updateTimer;
  bool _passwordSet = true;

  @override
  void initState() {
    super.initState();
    _forcePermanentPasswordOnly();
    gFFI.serverModel.checkAndroidPermission();
    _updateTimer = periodic_immediate(const Duration(seconds: 3), () async {
      await gFFI.serverModel.fetchID();
      checkService();
      final passwordSet =
          (await bind.mainGetCommon(key: "permanent-password-set")) == "true";
      if (mounted && passwordSet != _passwordSet) {
        setState(() => _passwordSet = passwordSet);
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _forcePermanentPasswordOnly() async {
    await bind.mainSetOption(key: kOptionApproveMode, value: 'password');
    await bind.mainSetOption(
        key: kOptionVerificationMethod, value: kUsePermanentPassword);
    await gFFI.serverModel.updatePasswordModel();
  }

  Future<void> _startAssistance(ServerModel serverModel) async {
    await serverModel.checkRequestNotificationPermission();
    await serverModel.checkFloatingWindowPermission();
    await serverModel.startService();
  }

  Future<void> _openSettings() async {
    if (await _checkSettingsCode() && mounted) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (context) => const _SimpleSettingsPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
        value: gFFI.serverModel,
        child: Scaffold(
          appBar: AppBar(
            centerTitle: true,
            title: const Text('Assistance à distance'),
            actions: [
              IconButton(
                  tooltip: 'Réglages',
                  icon: const Icon(Icons.settings),
                  onPressed: _openSettings)
            ],
          ),
          body: Consumer<ServerModel>(
              builder: (context, serverModel, child) => SingleChildScrollView(
                    child: Column(children: [
                      _buildStatus(serverModel),
                      const ConnectionManager(),
                    ]),
                  )),
        ));
  }

  Widget _buildStatus(ServerModel serverModel) {
    if (!_passwordSet) {
      return _statusCard(Icons.settings, Colors.orange, 'Configuration à finir',
          'Appuyez sur la roue dentée en haut à droite.');
    }
    if (!serverModel.isStart || !serverModel.mediaOk) {
      return _statusCard(Icons.pause_circle_outline, Colors.orange,
          'Assistance arrêtée', 'Appuyez sur le bouton ci-dessous.',
          buttonLabel: "Activer l'assistance",
          onPressed: () => _startAssistance(serverModel));
    }
    if (!serverModel.inputOk) {
      return _statusCard(Icons.touch_app, Colors.orange,
          'Contrôle à autoriser', "L'écran est partagé, mais pas le contrôle.",
          buttonLabel: 'Autoriser le contrôle',
          onPressed: serverModel.toggleInput);
    }
    if (serverModel.connectStatus <= 0) {
      return _statusCard(Icons.wifi_find, Colors.orange, 'Connexion en cours',
          'Vérifiez que le Wi-Fi est bien activé.');
    }
    return _statusCard(Icons.check_circle, Colors.green, 'Prêt',
        "L'assistance à distance est disponible.");
  }

  Widget _statusCard(IconData icon, Color color, String title, String text,
      {String? buttonLabel, VoidCallback? onPressed}) {
    return PaddingCard(
        child: Column(children: [
      const SizedBox(height: 16),
      Icon(icon, color: color, size: 96),
      const SizedBox(height: 16),
      Text(title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      Text(text,
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 20)),
      if (buttonLabel != null) ...[
        const SizedBox(height: 24),
        SizedBox(
            width: double.infinity,
            child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18)),
                onPressed: onPressed,
                child: Text(buttonLabel,
                    style: const TextStyle(fontSize: 22)))),
      ],
      const SizedBox(height: 16),
    ]));
  }
}

class _SimpleSettingsPage extends StatefulWidget {
  const _SimpleSettingsPage({Key? key}) : super(key: key);

  @override
  State<_SimpleSettingsPage> createState() => _SimpleSettingsPageState();
}

class _SimpleSettingsPageState extends State<_SimpleSettingsPage> {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
        value: gFFI.serverModel,
        child: Scaffold(
          appBar: AppBar(title: const Text('Réglages')),
          body: Consumer<ServerModel>(
              builder: (context, serverModel, child) => ListView(children: [
                    ListTile(
                      leading: const Icon(Icons.perm_identity),
                      title: const Text('ID'),
                      subtitle: Text(serverModel.serverId.text,
                          style: const TextStyle(fontSize: 22)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.edit),
                      title: const Text("Modifier l'ID"),
                      subtitle: serverModel.connectStatus > 0
                          ? null
                          : const Text('Nécessite une connexion Internet'),
                      enabled: serverModel.connectStatus > 0,
                      onTap: changeIdDialog,
                    ),
                    ListTile(
                      leading: const Icon(Icons.key),
                      title: const Text('Modifier le mot de passe permanent'),
                      onTap: setPasswordDialog,
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.lock),
                      title: const Text('Changer le code de protection'),
                      onTap: _createSettingsCode,
                    ),
                  ])),
        ));
  }
}

int _failedCodeAttempts = 0;
DateTime? _codeLockedUntil;

Future<bool> _checkSettingsCode() async {
  if (bind.mainGetLocalOption(key: _kSettingsCodeHash).isEmpty) {
    return _createSettingsCode();
  }
  final lockedUntil = _codeLockedUntil;
  if (lockedUntil != null && DateTime.now().isBefore(lockedUntil)) {
    showToast('Trop d\'essais. Réessayez dans 30 secondes.');
    return false;
  }
  final code = await _askCode('Code de protection');
  if (code == null) return false;
  final salt = bind.mainGetLocalOption(key: _kSettingsCodeSalt);
  if (_hashCode(code, salt) ==
      bind.mainGetLocalOption(key: _kSettingsCodeHash)) {
    _failedCodeAttempts = 0;
    return true;
  }
  _failedCodeAttempts++;
  if (_failedCodeAttempts >= _kMaxCodeAttempts) {
    _failedCodeAttempts = 0;
    _codeLockedUntil = DateTime.now().add(_kCodeLockout);
  }
  showToast('Code incorrect');
  return false;
}

Future<bool> _createSettingsCode() async {
  final code = await _askCode('Nouveau code de protection',
      hint: '$_kMinCodeLength chiffres minimum');
  if (code == null) return false;
  if (code.length < _kMinCodeLength) {
    showToast('Le code doit contenir au moins $_kMinCodeLength chiffres');
    return false;
  }
  final confirmation = await _askCode('Confirmez le code');
  if (confirmation != code) {
    showToast('Les deux codes sont différents');
    return false;
  }
  final random = Random.secure();
  final salt = base64Encode(List.generate(16, (_) => random.nextInt(256)));
  await bind.mainSetLocalOption(key: _kSettingsCodeSalt, value: salt);
  await bind.mainSetLocalOption(
      key: _kSettingsCodeHash, value: _hashCode(code, salt));
  return true;
}

String _hashCode(String code, String salt) =>
    sha256.convert(utf8.encode('$salt:$code')).toString();

Future<String?> _askCode(String title, {String? hint}) {
  final controller = TextEditingController();
  return gFFI.dialogManager.show<String>((setState, close, context) {
    submit() => close(controller.text.trim());
    return CustomAlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (_) => submit(),
      ),
      actions: [
        dialogButton('Annuler', onPressed: close, isOutline: true),
        dialogButton('OK', onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}
