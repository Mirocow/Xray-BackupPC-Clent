package main

// Службы Windows (SCM): backuppc-client-socks и backuppc-client-tun от
// LocalSystem, автозапуск, перезапуск при сбое. Под SCM run работает как
// служба (svc.Run), журнал — <каталог конфигов>\<режим>.log.

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"
)

func serviceName(mode string) string { return "backuppc-client-" + mode }

func cmdService(args []string, stdout io.Writer) error {
	action, mode, dir, err := serviceArgs(args)
	if err != nil {
		return err
	}
	if err := requireAdmin(); err != nil {
		return errors.New("управление службами требует прав администратора")
	}
	name := serviceName(mode)
	m, err := mgr.Connect()
	if err != nil {
		return err
	}
	defer m.Disconnect()

	s, openErr := m.OpenService(name)
	if openErr == nil {
		defer s.Close()
	}
	switch action {
	case "install":
		if err := requireConfig(dir, mode); err != nil {
			return err
		}
		exe, err := serviceExecutable()
		if err != nil {
			return err
		}
		if openErr == nil { // переустановка: новый путь/каталог
			_ = stopService(s)
			cfg, err := s.Config()
			if err != nil {
				return err
			}
			cfg.BinaryPathName = windows.EscapeArg(exe) + " run -dir " + windows.EscapeArg(dir) + " " + mode
			cfg.StartType = mgr.StartAutomatic
			if err := s.UpdateConfig(cfg); err != nil {
				return err
			}
		} else {
			s, err = m.CreateService(name, exe, mgr.Config{
				DisplayName: "BackupPC client (" + mode + ")",
				Description: "backuppc-client: " + mode + " (" + dir + ")",
				StartType:   mgr.StartAutomatic,
			}, "run", "-dir", dir, mode)
			if err != nil {
				return err
			}
			defer s.Close()
		}
		restart := mgr.RecoveryAction{Type: mgr.ServiceRestart, Delay: 5 * time.Second}
		if err := s.SetRecoveryActions([]mgr.RecoveryAction{restart, restart, restart}, 86400); err != nil {
			return err
		}
		// выход run с ошибкой (не только крах процесса) — тоже повод перезапуска
		_ = s.SetRecoveryActionsOnNonCrashFailures(true)
		if err := s.Start(); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "служба %s установлена и запущена (журнал: %s)\n", name,
			filepath.Join(dir, mode+".log"))
	case "uninstall":
		if openErr != nil {
			fmt.Fprintf(stdout, "служба %s не установлена\n", name)
			return nil
		}
		_ = stopService(s)
		if err := s.Delete(); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "служба %s удалена\n", name)
	case "restart":
		if openErr != nil {
			return fmt.Errorf("служба %s не установлена", name)
		}
		if err := stopService(s); err != nil {
			return err
		}
		if err := s.Start(); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "служба %s перезапущена\n", name)
	case "status":
		if openErr != nil {
			fmt.Fprintf(stdout, "%s: не установлена\n", name)
			return nil
		}
		st, err := s.Query()
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "%s: %s, журнал %s\n", name, stateName(st.State),
			filepath.Join(dir, mode+".log"))
	}
	return nil
}

func stopService(s *mgr.Service) error {
	st, err := s.Query()
	if err != nil {
		return err
	}
	if st.State == svc.Stopped {
		return nil
	}
	if st.State != svc.StopPending {
		if _, err := s.Control(svc.Stop); err != nil {
			return err
		}
	}
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(300 * time.Millisecond)
		if st, err = s.Query(); err != nil {
			return err
		}
		if st.State == svc.Stopped {
			return nil
		}
	}
	return errors.New("служба не остановилась за 30 с")
}

func stateName(s svc.State) string {
	switch s {
	case svc.Running:
		return "работает"
	case svc.Stopped:
		return "остановлена"
	case svc.StartPending:
		return "запускается"
	case svc.StopPending:
		return "останавливается"
	}
	return fmt.Sprintf("состояние %d", s)
}

// serviceMain — запуск под SCM: журнал в файл, жизненный цикл — svc.Run.
func serviceMain(mode, dir string) (bool, error) {
	isService, err := svc.IsWindowsService()
	if err != nil || !isService {
		return false, nil
	}
	logFile, err := openServiceLog(filepath.Join(dir, mode+".log"))
	if err != nil {
		return true, err
	}
	defer logFile.Close()
	// журнал ядра Xray пишется в os.Stdout — перенаправляем до старта;
	// стандартный log (slog библиотеки backuppc) запомнил os.Stderr при
	// инициализации — ему отдельно
	os.Stdout, os.Stderr = logFile, logFile
	log.SetOutput(logFile)
	err = svc.Run(serviceName(mode), &serviceHandler{mode: mode, dir: dir, out: logFile})
	return true, err
}

// openServiceLog — журнал дописывается; больше 10 МиБ — начинается заново.
func openServiceLog(path string) (*os.File, error) {
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if fi, err := os.Stat(path); err == nil && fi.Size() > 10<<20 {
		flags |= os.O_TRUNC
	}
	return os.OpenFile(path, flags, 0o600)
}

type serviceHandler struct {
	mode, dir string
	out       io.Writer
}

func (h *serviceHandler) Execute(_ []string, r <-chan svc.ChangeRequest, s chan<- svc.Status) (bool, uint32) {
	s <- svc.Status{State: svc.StartPending}
	stop := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- runMode(h.dir, h.mode, stop, h.out) }()
	s <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case c := <-r:
			switch c.Cmd {
			case svc.Interrogate:
				s <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				s <- svc.Status{State: svc.StopPending, WaitHint: 20000}
				close(stop)
				if err := <-done; err != nil {
					fmt.Fprintln(h.out, "backuppc-client:", err)
				}
				return false, 0
			}
		case err := <-done:
			// ядро завершилось само — код ошибки запускает перезапуск SCM
			fmt.Fprintln(h.out, "backuppc-client:", err)
			return false, 1
		}
	}
}
