/// Экран подключения: адрес панели, токен, опции TLS. Поддерживает
/// автозаполнение из сохраненного профиля.
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../ui.dart';

class LoginPage extends StatefulWidget {
  final AppState state;
  const LoginPage(this.state, {super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _addr;
  late final TextEditingController _token;
  bool _selfSigned = false;
  bool _remember = true;

  @override
  void initState() {
    super.initState();
    final saved = widget.state.saved;
    _addr = TextEditingController(
      text: saved?.address ?? 'http://192.168.1.1:8444',
    );
    _token = TextEditingController(text: saved?.token ?? '');
    _selfSigned = saved?.acceptSelfSigned ?? false;
    widget.state.addListener(_onState);
  }

  void _onState() {
    final err = widget.state.error;
    if (err != null && mounted) {
      showSnack(context, err, error: true);
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _addr.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    await widget.state.connect(
      address: _addr.text.trim(),
      token: _token.text.trim(),
      acceptSelfSigned: _selfSigned,
      remember: _remember,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listening: state,
          builder: (context, _) => Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.dns_outlined, size: 56, color: kAccent),
                    const SizedBox(height: 8),
                    const Text(
                      'BackupPC Admin',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'управление сервером xray-backuppc',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kDim, fontSize: 13),
                    ),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _addr,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Адрес панели',
                        hintText: 'http://178.140.10.58:8444',
                        prefixIcon: Icon(Icons.language_outlined),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _token,
                      autocorrect: false,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Токен администратора',
                        hintText: 'admin-token.txt на сервере',
                        prefixIcon: Icon(Icons.key_outlined),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      value: _selfSigned,
                      onChanged: (v) => setState(() => _selfSigned = v),
                      title: const Text(
                        'Самоподписанный сертификат',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        'для https-панели без валидного сертификата',
                        style: TextStyle(color: kDim, fontSize: 11),
                      ),
                      dense: true,
                    ),
                    SwitchListTile(
                      value: _remember,
                      onChanged: (v) => setState(() => _remember = v),
                      title: const Text(
                        'Запомнить на этом устройстве',
                        style: TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        'токен хранится только в телефоне',
                        style: TextStyle(color: kDim, fontSize: 11),
                      ),
                      dense: true,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: state.busy ? null : _connect,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: state.busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Подключиться'),
                      ),
                    ),
                    if (state.loginInfo != null) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => state.logout(),
                        child: const Text('Выйти из текущей сессии'),
                      ),
                    ],
                    const SizedBox(height: 24),
                    const Text(
                      'Панель по умолчанию слушает порт 8444 (HTTP). '
                      'Токен генерируется при первом запуске сервера '
                      '(dataDir/admin-token.txt) и меняется в веб-панели.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: kDim, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
