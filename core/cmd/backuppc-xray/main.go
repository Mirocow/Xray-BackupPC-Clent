// backuppc-xray — настольное ядро с нативным протоколом backuppc.
//
// Повторяет контракт OneXrayCore (desktop_bin libXray): читает Xray JSON,
// прогоняет его через конвейер backuppc-core (NormalizeJSON →
// core.LoadConfig → Apply) и запускает инстанс Xray. Конфиги без
// backuppc-outbound работают как в обычном ядре.
//
// Команды:
//
//	backuppc-xray run  -config app.json        # запуск (до SIGINT/SIGTERM)
//	backuppc-xray test -config app.json        # валидация (TestXray-режим)
//
// Отладка (инструментарий разработки, см. DEVELOPMENT.md):
//
//	BACKUPPC_PPROF=127.0.0.1:6060 backuppc-xray run -config app.json
//	    — net/http/pprof: профили горутин/аллокаций/CPU туннеля.
package main

import (
	"flag"
	"fmt"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"backuppc-core/preprocess"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
)

func main() {
	startDebugHooks()
	if code := run(os.Args[1:]); code != 0 {
		os.Exit(code)
	}
}

// startDebugHooks — отладочные возможности ядра: pprof-листенер по
// BACKUPPC_PPROF (addr, напр. 127.0.0.1:6060). Уровень журнала Xray
// задается конфигом ("log": {"loglevel": ...}). В нормальном режиме
// хук бездействует.
func startDebugHooks() {
	if addr := os.Getenv("BACKUPPC_PPROF"); addr != "" {
		go func() {
			fmt.Printf("backuppc-xray: pprof на http://%s/debug/pprof/\n", addr)
			srv := &http.Server{
				Addr:              addr,
				ReadHeaderTimeout: 10 * time.Second,
			}
			_ = srv.ListenAndServe()
		}()
	}
}

func run(args []string) int {
	if len(args) == 0 {
		usage()
		return 2
	}
	switch args[0] {
	case "run":
		return withConfig(args[1:], startAndWait)
	case "test":
		return withConfig(args[1:], validateOnly)
	default:
		usage()
		return 2
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "использование: backuppc-xray <run|test> -config <xray.json>")
}

func withConfig(args []string, action func(config []byte) error) int {
	fs := flag.NewFlagSet("", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	configPath := fs.String("config", "", "путь к Xray JSON")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *configPath == "" {
		fmt.Fprintln(os.Stderr, "укажите -config")
		return 2
	}
	config, err := os.ReadFile(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "чтение конфига: %v\n", err)
		return 1
	}
	if err := action(config); err != nil {
		fmt.Fprintf(os.Stderr, "ошибка: %v\n", err)
		return 1
	}
	return 0
}

func buildInstance(config []byte) (*core.Instance, error) {
	patched, replacements, err := preprocess.NormalizeJSON(config)
	if err != nil {
		return nil, err
	}
	coreConfig, err := core.LoadConfig("json", strings.NewReader(string(patched)))
	if err != nil {
		return nil, err
	}
	if err := preprocess.Apply(coreConfig, replacements); err != nil {
		return nil, err
	}
	return core.New(coreConfig)
}

func validateOnly(config []byte) error {
	instance, err := buildInstance(config)
	if err != nil {
		return err
	}
	fmt.Println("OK: конфиг валиден (протоколы Xray + backuppc)")
	return instance.Close()
}

func startAndWait(config []byte) error {
	instance, err := buildInstance(config)
	if err != nil {
		return err
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return err
	}
	defer instance.Close()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	fmt.Println("backuppc-xray: ядро запущено (Ctrl+C для остановки)")
	<-signals
	fmt.Println("backuppc-xray: остановка…")
	return nil
}
