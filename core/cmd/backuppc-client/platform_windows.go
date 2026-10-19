package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// Windows: ядро встроено в backuppc-client (run), службы — SCM.
const (
	defaultTun          = "backuppc"
	serverModeSupported = false
	restartHint         = "перезапустите службу: backuppc-client service restart tun  (или socks; в консоли администратора)"
	platformCommandList = " | run | service"
	tunNameHint         = ""
)

const platformUsage = desktopUsage

var defaultDir = filepath.Join(programData(), "backuppc-client")

var platformCommands = map[string]func([]string, io.Writer) error{
	"run":     cmdRun,
	"service": cmdService,
}

func programData() string {
	if d := os.Getenv("ProgramData"); d != "" {
		return d
	}
	return `C:\ProgramData`
}

func validTunName(name string) bool {
	return name != "" && len(name) <= 32 && !strings.ContainsAny(name, `/\:*?"'<>|`)
}

// secureDir — каталог доступен только SYSTEM и администраторам (UUID —
// секрет); наследование от ProgramData (там Users читают) отключено,
// файлы внутри наследуют этот DACL.
func secureDir(dir string) error {
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil, nil, dacl, nil)
}
