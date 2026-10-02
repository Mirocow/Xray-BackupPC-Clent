/// backuppc_dart — нативная Dart-реализация клиентского протокола
/// xray-vless-backuppc.
///
/// Слои (порт Go-библиотеки `backuppc/internal/backupemulator`):
///  1. **Несущий канал** — HTTP/2+TLS (ALPN h2), POST с
///     `content-type: application/grpc`, метаданные «бекапов»
///     X-Backup-Session-ID / Chunk-Index / Auth (HMAC-SHA256);
///  2. **Кадрирование** — `[payloadLen:2B][paddingLen:2B][payload][padding]`
///     внутри gRPC-сообщений, случайный паддинг 32–1400 байт;
///  3. **VLESS** — UUID + TCP-target в первом кадре чанка 0;
///  4. **Ротация чанков** — лимиты байт/времени, END_STREAM до диала,
///     эстафета читателя по цепочке;
///  5. **Эмуляция BackupPC** — пулы хостов/агентов, джиттер-пинги,
///     балансировка асимметрии, псевдо-задания бекапов.
///
/// Поверх — SOCKS5-фронтенд [BackupPcClient] и прямой диал [dialLogical].
///
/// Требование заказчика: клиент мультиплатформенный (Flutter:
/// iOS/macOS/Android/Linux/Windows), протокол реализован на чистом Dart
/// без нативных зависимостей — собирается на всех платформах приложения.
library;

export 'src/backuppc_profile.dart'
    show
        backuppcHosts,
        backuppcUserAgents,
        validBackupPCSessionID,
        newBackupPCSessionID,
        pickBackupPCUserAgent,
        backuppcSessionHost,
        BackupJobKind,
        BackupJobPlan,
        backuppcNextJob,
        planBackupBursts,
        formatBackupBytes;
export 'src/carrier.dart'
    show
        ChunkConnection,
        CarrierTls,
        backupAuthHeader,
        chunkDialTimeout,
        responseHeaderTimeout;
export 'src/client.dart'
    show BackupPcClient, ClientMetrics, dialLogical;
export 'src/config.dart'
    show
        ClientConfig,
        TransportConfig,
        BackupPCConfig,
        Duration_,
        parseUUID,
        loadClientConfigFromJson;
export 'src/frame.dart'
    show
        FrameCodec,
        ChunkByteReader,
        ChunkEofException,
        StreamException_,
        frameHeaderSize,
        frameMaxPayload,
        frameMaxPadding,
        frameMaxTotal;
export 'src/grpc.dart'
    show
        GrpcMessageReader,
        GrpcMessageWriter,
        ByteFeeder,
        grpcHdrLen,
        grpcMaxFrame;
export 'src/link.dart' show BackupPcLink, backuppcScheme;
export 'src/random.dart'
    show randIntRange, randDurationRange, randBytes, randHex, randPaddingView;
export 'src/socks5.dart'
    show
        Socks5Request,
        SocketByteReader,
        socks5Handshake,
        socksHandshakeTimeout;
export 'src/tunnel.dart'
    show BackupPcLogicalConn, SessionMetrics, nextChunkWait, rotationCooldown;
export 'src/vless.dart'
    show
        buildVlessRequest,
        vlessResponseHeader,
        vlessVersion,
        vlessCmdTCP;
