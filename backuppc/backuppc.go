// Package backuppc — публичный API модуля transport-протокола BackupPC
// (Backup-Emulator: VLESS поверх HTTP/2+TLS gRPC-канала с маскировкой
// под поток периодических резервных копий BackupPC).
//
// Библиотека реализована в internal/backupemulator; этот файл реэкспортирует
// её наружу для внешних модулей (в частности — для ядра xray-backuppc-core,
// встраивающего протокол как нативный outbound Xray). Внутренняя структура
// не является частью контракта: внешний код работает только с типами,
// перечисленными здесь.
package backuppc

import (
	"log/slog"
	"time"

	"backuppc/internal/backupemulator"
)

// Основные типы (алиасы внутренней библиотеки).
type (
	// Client — outbound-транспорт: дайлер логических сессий
	// (VLESS + чанки gRPC-канала + маскировка) и локальный SOCKS5-сервер.
	Client = backupemulator.Client
	// ClientConfig — конфигурация outbound-транспорта.
	ClientConfig = backupemulator.ClientConfig
	// Server — inbound-транспорт: HTTP/2+TLS, анти-пробинг, склейка чанков.
	Server = backupemulator.Server
	// ServerConfig — конфигурация inbound-транспорта.
	ServerConfig = backupemulator.ServerConfig
	// TransportConfig — общие параметры профиля BackupPC.
	TransportConfig = backupemulator.TransportConfig
	// LogicalConn — логическая сессия поверх чанков (реализует net.Conn).
	LogicalConn = backupemulator.LogicalConn
	// Duration — обертка time.Duration с JSON-сериализацией «30m»/«45s».
	Duration = backupemulator.Duration
	// ClientMetrics — агрегированные метрики клиента.
	ClientMetrics = backupemulator.ClientMetrics
	// ServerMetrics — агрегированные метрики сервера.
	ServerMetrics = backupemulator.ServerMetrics
)

// NewClient — конструктор outbound-транспорта.
func NewClient(cfg *ClientConfig, logger *slog.Logger) (*Client, error) {
	return backupemulator.NewClient(cfg, logger)
}

// NewServer — конструктор inbound-транспорта.
func NewServer(cfg *ServerConfig, logger *slog.Logger) (*Server, error) {
	return backupemulator.NewServer(cfg, logger)
}

// LoadClientConfig — чтение конфигурации клиента из JSON-файла.
func LoadClientConfig(path string) (*ClientConfig, error) {
	return backupemulator.LoadClientConfig(path)
}

// LoadServerConfig — чтение конфигурации сервера из JSON-файла.
func LoadServerConfig(path string) (*ServerConfig, error) {
	return backupemulator.LoadServerConfig(path)
}

// Dur — обертка для time.Duration (удобно при сборке конфигов в коде).
func Dur(d time.Duration) Duration { return backupemulator.Dur(d) }
