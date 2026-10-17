//go:build !darwin && !windows

package main

import (
	"io"
	"strings"
)

// Linux: ядро запускают systemd-юниты пакета (deploy/linux), сам
// backuppc-client только генерирует конфиги.
const (
	defaultDir          = "/etc/backuppc-client"
	defaultTun          = "bpc0"
	serverModeSupported = true
	restartHint         = "перезапустите службу: systemctl restart backuppc-client  (или backuppc-client-tun)"
	platformUsage       = ""
	platformCommandList = ""
	tunNameHint         = ""
)

var platformCommands = map[string]func([]string, io.Writer) error{}

func validTunName(name string) bool {
	return name != "" && len(name) <= 15 && !strings.ContainsAny(name, " /")
}

// secureDir — права каталога задают MkdirAll (0750) и writeSecret (0640).
func secureDir(string) error { return nil }
