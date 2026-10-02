/// Контроллер Dart-туннелей backuppc: выделенный изолят с SOCKS5-фронтендами
/// (по одному на каждый backuppc-узел), управление старт/стоп и восстановление
/// после перезапуска приложения.
///
/// Изолят держит все сокеты туннеля (их нельзя передавать между изолятами):
/// UI-цикл не грузится, тяжелый трафик (8K-видео, сотни ГиБ) обрабатывается
/// независимо. Управляющий протокол: JSON-сообщения через SendPort.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:backuppc_dart/backuppc_dart.dart';

import 'package:onexray/core/tools/logger.dart';

/// Спецификация туннеля одного backuppc-узла.
class BackupPcTunnelProfile {
  /// Локальный порт SOCKS5 (на него указывает socks-outbound Xray).
  final int port;

  /// Конфигурация [ClientConfig] (JSON-serializable).
  final Map<String, dynamic> config;

  const BackupPcTunnelProfile({required this.port, required this.config});

  Map<String, dynamic> toJson() => {'port': port, 'config': config};

  static BackupPcTunnelProfile fromJson(Map<String, dynamic> json) {
    final port = json['port'];
    final config = json['config'];
    if (port is! int || config is! Map<String, dynamic>) {
      throw const FormatException('Invalid backuppc tunnel profile');
    }
    return BackupPcTunnelProfile(port: port, config: config);
  }
}

/// Запущенный туннель: изолят + контрольные порты (владеем и закрываем).
class _RunningTunnel {
  final String identity;
  final List<BackupPcTunnelProfile> profiles;
  final Isolate isolate;

  /// Управляющий порт изолята (получен в сообщении control).
  SendPort? isolateControl;
  final ReceivePort _control;
  final ReceivePort _onExit;
  final ReceivePort _onError;
  final Completer<void> _exited = Completer<void>();

  _RunningTunnel(
    this.identity,
    this.profiles,
    this.isolate,
    this._control,
    this._onExit,
    this._onError,
  );

  void log(String line) => ygLogger('backuppc tunnel: $line');

  Future<void> dispose() async {
    try {
      await _exited.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
    } finally {
      _control.close();
      _onExit.close();
      _onError.close();
    }
  }
}

class BackupPcTunnelService {
  static final BackupPcTunnelService instance = BackupPcTunnelService._();

  BackupPcTunnelService._();

  _RunningTunnel? _running;
  Future<void>? _starting;

  /// Активна ли туннельная служба.
  bool get isRunning => _running != null;

  /// Текущая идентичность (для сопоставления с runtime).
  String? get runningIdentity => _running?.identity;

  /// Запуск туннелей для соединения [identity]. Идемпотентно: совпадающая
  /// идентичность → существующие туннели (восстановление после перезапуска
  /// приложения при живом нативном VPN); другая → перезапуск.
  Future<void> ensureStarted(
    String identity,
    List<BackupPcTunnelProfile> profiles,
  ) async {
    while (_starting != null) {
      await _starting;
    }
    final current = _running;
    if (current != null && current.identity == identity) {
      return;
    }
    final starting = _start(identity, profiles);
    _starting = starting;
    try {
      await starting;
    } finally {
      _starting = null;
    }
  }

  Future<void> _start(
    String identity,
    List<BackupPcTunnelProfile> profiles,
  ) async {
    await stopAll(reason: 'rotate');
    if (profiles.isEmpty) {
      return;
    }
    final control = ReceivePort();
    final onExit = ReceivePort();
    final onError = ReceivePort();
    final ready = Completer<void>();
    Object? failure;

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _tunnelMain,
        _IsolateArgs(control.sendPort, profiles),
        onExit: onExit.sendPort,
        onError: onError.sendPort,
        errorsAreFatal: true,
      );
    } catch (error) {
      control.close();
      onExit.close();
      onError.close();
      throw StateError('backuppc: изолят туннеля не запущен: $error');
    }

    final running = _RunningTunnel(
      identity,
      profiles,
      isolate,
      control,
      onExit,
      onError,
    );
    _running = running;

    StreamSubscription? controlSub;
    controlSub = control.listen((message) {
      if (message is! Map) {
        return;
      }
      final type = message['type'];
      switch (type) {
        case 'control':
          final port = message['port'];
          if (port is SendPort) {
            running.isolateControl = port;
          }
        case 'ready':
          failure = null;
          if (!ready.isCompleted) {
            ready.complete();
          }
        case 'failed':
          failure = StateError('backuppc: ${message['error']}');
          if (!ready.isCompleted) {
            ready.completeError(failure!);
          }
        case 'log':
          running.log('${message['line']}');
      }
    });
    onError.listen((message) {
      running.log('isolate error: $message');
      if (!ready.isCompleted) {
        ready.completeError(StateError('backuppc: ошибка изолята: $message'));
      } else {
        running._exited.completeError(StateError('backuppc isolate error'));
      }
    });
    onExit.listen((_) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('backuppc: изолейт завершился'));
      }
      if (!running._exited.isCompleted) {
        running._exited.complete();
      }
    });

    try {
      await ready.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException(
          'backuppc: туннель не отчитался о готовности',
        ),
      );
    } on Object catch (error) {
      await controlSub.cancel();
      _running = null;
      isolate.kill(priority: Isolate.immediate);
      control.close();
      onExit.close();
      onError.close();
      throw error is StateError || error is TimeoutException
          ? error
          : StateError('backuppc: $error');
    }
    running.log('tunnels ready (${profiles.length}): '
        '${[for (final p in profiles) '127.0.0.1:${p.port}'].join(', ')}');
  }

  /// Полная остановка туннелей (соединение разорвано).
  Future<void> stopAll({String reason = 'stop'}) async {
    final running = _running;
    _running = null;
    if (running == null) {
      return;
    }
    running.log('stopping ($reason)');
    try {
      running.isolateControl?.send({'op': 'stop'});
    } catch (_) {}
    await running.dispose();
    ygLogger('backuppc tunnel stopped ($reason)');
  }
}

class _IsolateArgs {
  final SendPort reply;
  final List<BackupPcTunnelProfile> profiles;
  const _IsolateArgs(this.reply, this.profiles);
}

/// Точка входа изолята: поднимает SOCKS5-клиенты и обслуживает команды.
Future<void> _tunnelMain(_IsolateArgs args) async {
  final clients = <BackupPcClient>[];
  void send(Map<String, dynamic> message) => args.reply.send(message);
  void log(String line) => send({'type': 'log', 'line': line});
  final control = ReceivePort();
  send({'type': 'control', 'port': control.sendPort});
  try {
    for (final profile in args.profiles) {
      final cfg = ClientConfig.fromJson({
        ...profile.config,
        'socksListen': '127.0.0.1:${profile.port}',
      });
      final client = await BackupPcClient.start(cfg, log: log);
      clients.add(client);
    }
    send({
      'type': 'ready',
      'ports': [for (final p in args.profiles) p.port],
    });
  } catch (error) {
    send({'type': 'failed', 'error': '$error'});
    for (final client in clients) {
      await client.stop();
    }
    Isolate.exit();
  }
  await for (final message in control) {
    if (message is Map && message['op'] == 'stop') {
      break;
    }
  }
  for (final client in clients) {
    await client.stop();
  }
  log('isolate stopped');
  Isolate.exit();
}
