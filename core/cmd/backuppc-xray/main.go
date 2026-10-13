// backuppc-xray — настольное/роутерное ядро с нативным протоколом backuppc.
//
// Повторяет контракт OneXrayCore (desktop_bin libXray): читает Xray JSON,
// прогоняет его через конвейер backuppc-core (NormalizeJSON →
// core.LoadConfig → Apply) и запускает инстанс Xray. Конфиги без
// backuppc-outbound работают как в обычном ядре.
//
// Поддерживаются два стиля аргументов:
//
//	стиль xray (роутер asuswrt-merlin-xrayui, drop-in замена бинарника):
//	    xray -c app.json [-c extra.json …] [-test]   # без -test — запуск
//	    xray version                                  # «Xray 26.3.27 …»
//	несколько -c сливаются: объекты — рекурсивно, массивы (outbounds,
//	inbounds, rules) — конкатенацией, как в multi-json загрузчике Xray;
//	плюс подкоманды официального CLI: api (rmo/ado/statsquery — hot-swap
//	и «клиенты онлайн»), tls (ech/ping), uuid, convert, x25519, wg, help;
//
//	прежний стиль (совместимость, OneXray/скрипты):
//	    backuppc-xray run  -config app.json        # запуск (до SIGINT/SIGTERM)
//	    backuppc-xray test -config app.json        # валидация (TestXray-режим)
//
// Отладка (инструментарий разработки, см. DEVELOPMENT.md):
//
//	BACKUPPC_PPROF=127.0.0.1:6060 backuppc-xray run -config app.json
//	    — net/http/pprof: профили горутин/аллокаций/CPU туннеля.
package main

import (
	"encoding/json"
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
	"github.com/xtls/xray-core/main/commands/base"
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
		return withConfigs(args[1:], startAndWait, false)
	case "test":
		return withConfigs(args[1:], validateOnly, false)
	case "version", "-version", "--version":
		printVersion()
		return 0
	case "help", "-help", "--help", "-h":
		return delegateSubcommand([]string{"help"})
	}
	// Стиль xray: xray -c file [-c file2] [-test] — запуск без -test.
	if strings.HasPrefix(args[0], "-") {
		return withConfigs(args, startAndWait, true)
	}
	// Подкоманды официального CLI: api (rmo/ado/statsquery — XRAYUI
	// hot-swap и «клиенты онлайн»), tls (ech/ping), uuid, convert, x25519,
	// wg… — штатный каркас команд Xray.
	return delegateSubcommand(args)
}

// delegateSubcommand передаёт подкоманду официальному каркасу Xray.
// base.Execute завершает процесс штатным кодом возврата (os.Exit),
// как это делает официальный бинарник.
func delegateSubcommand(args []string) int {
	os.Args = append([]string{os.Args[0]}, args...)
	base.RootCommand.Long = "Xray is a platform for building proxies."
	base.Execute()
	return 0 // недостижимо: Execute завершает процесс
}

func usage() {
	fmt.Fprintln(os.Stderr, "использование: xray <run|test|version> -config <xray.json>")
	fmt.Fprintln(os.Stderr, "          или: xray -c <xray.json> [-c <extra.json>…] [-test]  (стиль xray)")
	fmt.Fprintln(os.Stderr, "          или: xray <api|tls|uuid|convert|x25519|wg|help> …   (подкоманды Xray)")
}

func printVersion() {
	lines := core.VersionStatement()
	for _, line := range lines {
		fmt.Println(line)
	}
	fmt.Println("Custom core: backuppc outbound enabled (xray-vless-backuppc)")
}

// withConfigs разбирает аргументы обоих стилей и выполняет действие.
//
// xrayStyle=true — путь флагов xrayui: несколько -c (конфиги сливаются),
// флаг -test переключает validateOnly вместо запуска. Иначе — одиночный
// -config подкоманд run|test.
func withConfigs(args []string, action func(config []byte) error, xrayStyle bool) int {
	fs := flag.NewFlagSet("", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	configPath := fs.String("config", "", "путь к Xray JSON (подкоманды run|test)")
	configFiles := multiFlag{}
	fs.Var(&configFiles, "c", "путь Xray JSON; повторяется — конфиги сливаются")
	testOnly := fs.Bool("test", false, "валидировать конфиг и выйти")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	files := configFiles
	if *configPath != "" {
		files = append(files, *configPath)
	}
	if len(files) == 0 {
		fmt.Fprintln(os.Stderr, "укажите -config или -c")
		return 2
	}

	config, err := readMerged(files)
	if err != nil {
		fmt.Fprintf(os.Stderr, "чтение конфига: %v\n", err)
		return 1
	}

	// -test означает «валидировать и выйти» в любом стиле аргументов:
	// и в xray-стиле (xrayui: xray -c a [-c b] -test), и в подкоманде
	// run (failover-скрипты xrayui: xray run -test -config f). Без этого
	// run -test запускал бы настоящий демон и ждал сигналы вечно.
	if *testOnly {
		return execValidate(config)
	}
	if err := action(config); err != nil {
		fmt.Fprintf(os.Stderr, "ошибка: %v\n", err)
		return 1
	}
	return 0
}

// multiFlag — повторяемый строковый флаг (-c a -c b).
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error {
	*m = append(*m, v)
	return nil
}

// readMerged читает конфиги и сливает их: объекты — рекурсивно, массивы —
// конкатенацией (как multi-json загрузчик Xray; порядок = порядок -c).
func readMerged(paths []string) ([]byte, error) {
	merged := map[string]any{}
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		var doc map[string]any
		if err := json.Unmarshal(raw, &doc); err != nil {
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		mergeJSON(merged, doc)
	}
	return json.Marshal(merged)
}

func mergeJSON(dst, src map[string]any) {
	for k, v := range src {
		if prev, ok := dst[k]; ok {
			if pm, ok1 := prev.(map[string]any); ok1 {
				if vm, ok2 := v.(map[string]any); ok2 {
					mergeJSON(pm, vm)
					continue
				}
			}
			if pa, ok1 := prev.([]any); ok1 {
				if va, ok2 := v.([]any); ok2 {
					dst[k] = append(pa, va...)
					continue
				}
			}
		}
		dst[k] = v
	}
}

func execValidate(config []byte) int {
	if err := validateOnly(config); err != nil {
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
