package main

import (
	"io"
	"os"
	"regexp"
)

// macOS: ядро встроено в backuppc-client (run), службы — launchd.
const (
	defaultDir          = "/usr/local/etc/backuppc-client"
	defaultTun          = "utun99"
	serverModeSupported = false
	restartHint         = "перезапустите службу: sudo backuppc-client service restart tun  (или socks)"
	platformCommandList = " | run | service"
	tunNameHint         = " (на macOS — utunN, например utun99)"
)

const platformUsage = desktopUsage

var platformCommands = map[string]func([]string, io.Writer) error{
	"run":     cmdRun,
	"service": cmdService,
}

var utunName = regexp.MustCompile(`^utun[0-9]{1,4}$`)

func validTunName(name string) bool { return utunName.MatchString(name) }

// secureDir — каталог читает только root (UUID — секрет).
func secureDir(dir string) error { return os.Chmod(dir, 0o700) }
