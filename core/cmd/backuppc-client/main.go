// backuppc-client — настройка безголового Linux-клиента backuppc.
//
// Разбирает share-ссылку backuppc:// (панель сервера → «Конфиг клиента»)
// и генерирует конфиги ядра backuppc-xray для двух режимов:
//
//	socks.json — локальный SOCKS5 (backuppc-client.service)
//	tun.json   — системный VPN через TUN (backuppc-client-tun.service)
//	tun.env    — параметры для tun-routes (маршруты и DNS интерфейса)
//
// Использование:
//
//	backuppc-client import [флаги] 'backuppc://…'   # или «-» — ссылка из stdin
//	backuppc-client show   [-dir DIR]                # текущий профиль
//	backuppc-client version
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"backuppc-core/link"
)

// version подставляется при сборке: -ldflags "-X main.version=…".
var version = "dev"

const (
	defaultDir   = "/etc/backuppc-client"
	serviceGroup = "backuppc-client"
)

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "backuppc-client:", err)
		os.Exit(1)
	}
}

func run(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return errors.New("ожидается команда: import | show | version")
	}
	switch args[0] {
	case "import":
		return cmdImport(args[1:], stdin, stdout)
	case "show":
		return cmdShow(args[1:], stdout)
	case "version", "-v", "--version":
		fmt.Fprintln(stdout, "backuppc-client", version)
		return nil
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return nil
	}
	return fmt.Errorf("неизвестная команда %q (import | show | version)", args[0])
}

const usage = `backuppc-client import [флаги] <backuppc://…|->
    -dir DIR         каталог конфигов (` + defaultDir + `)
    -socks ADDR      SOCKS5-вход (127.0.0.1:1080)
    -tun NAME        имя TUN-интерфейса (bpc0)
    -mtu N           MTU TUN (1500)
    -dns IP[,IP]     DNS через туннель, по TCP (1.1.1.1,8.8.8.8)
    -loglevel LEVEL  debug|info|warning|error|none (warning)
    -server-mode     TUN на сервере: входящие соединения и ответы на них —
                     мимо туннеля, UDP — напрямую (нужен nftables)
backuppc-client show [-dir DIR]
backuppc-client version
`

func cmdImport(args []string, stdin io.Reader, stdout io.Writer) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	dir := fs.String("dir", defaultDir, "")
	socks := fs.String("socks", "127.0.0.1:1080", "")
	tun := fs.String("tun", "bpc0", "")
	mtu := fs.Int("mtu", 1500, "")
	dns := fs.String("dns", "1.1.1.1,8.8.8.8", "")
	logLevel := fs.String("loglevel", "warning", "")
	serverMode := fs.Bool("server-mode", false, "")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("import: %w\n%s", err, usage)
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("import: ожидается одна ссылка backuppc:// или «-»\n%s", usage)
	}
	raw := fs.Arg(0)
	if raw == "-" {
		line, err := bufio.NewReader(stdin).ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return fmt.Errorf("import: чтение stdin: %w", err)
		}
		raw = line
	}
	raw = strings.TrimSpace(raw)

	o, err := link.ParseLink(raw)
	if err != nil {
		return err
	}
	p := Profile{
		SocksListen: *socks, TunName: *tun, TunMTU: *mtu,
		DNS: splitList(*dns), LogLevel: *logLevel, ServerMode: *serverMode,
	}
	if err := p.validate(); err != nil {
		return err
	}
	switch p.LogLevel {
	case "debug", "info", "warning", "error", "none":
	default:
		return fmt.Errorf("loglevel: неизвестный уровень %q", p.LogLevel)
	}

	socksJSON, err := marshal(SocksConfig(o, p))
	if err != nil {
		return err
	}
	tunJSON, err := marshal(TunConfig(o, p))
	if err != nil {
		return err
	}
	files := []struct {
		name string
		data []byte
	}{
		{"link", []byte(raw + "\n")},
		{"socks.json", socksJSON},
		{"tun.json", tunJSON},
		{"tun.env", []byte(TunEnv(o, p))},
	}
	if err := os.MkdirAll(*dir, 0o750); err != nil {
		return err
	}
	gid := lookupGroup(serviceGroup)
	for _, f := range files {
		if err := writeSecret(filepath.Join(*dir, f.name), f.data, gid); err != nil {
			return err
		}
	}
	fmt.Fprintf(stdout, "сервер %s (%s) → конфиги в %s\n", o.ServerAddr, displayTag(o), *dir)
	fmt.Fprintln(stdout, "перезапустите службу: systemctl restart backuppc-client  (или backuppc-client-tun)")
	return nil
}

func cmdShow(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("show", flag.ContinueOnError)
	dir := fs.String("dir", defaultDir, "")
	fs.SetOutput(io.Discard)
	if err := fs.Parse(args); err != nil {
		return err
	}
	raw, err := os.ReadFile(filepath.Join(*dir, "link"))
	if err != nil {
		return fmt.Errorf("профиль не импортирован (%w); выполните backuppc-client import", err)
	}
	o, err := link.ParseLink(string(raw))
	if err != nil {
		return err
	}
	fp := o.CertFingerprint
	switch {
	case fp == "" && o.Insecure:
		fp = "нет (insecure — TLS не проверяется!)"
	case fp == "":
		fp = "нет (системные CA)"
	}
	mode := "десктоп (весь трафик в туннель, UDP блокируется)"
	if env, err := os.ReadFile(filepath.Join(*dir, "tun.env")); err == nil &&
		strings.Contains(string(env), "SERVER_MODE=1") {
		mode = "сервер (входящие — мимо туннеля, UDP напрямую)"
	}
	fmt.Fprintf(stdout, "узел:     %s\nсервер:   %s\nuuid:     %s\nhost/SNI: %s\nпиннинг:  %s\nTUN:      %s\n",
		displayTag(o), o.ServerAddr, maskUUID(o.UUID), orDash(o.Host), fp, mode)
	return nil
}

func marshal(v any) ([]byte, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// writeSecret — атомарная запись 0640 (UUID — секрет): root и группа
// службы читают, остальные нет.
func writeSecret(path string, data []byte, gid int) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o640); err != nil {
		tmp.Close()
		return err
	}
	if gid >= 0 && os.Geteuid() == 0 {
		if err := tmp.Chown(0, gid); err != nil {
			tmp.Close()
			return err
		}
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func lookupGroup(name string) int {
	g, err := user.LookupGroup(name)
	if err != nil {
		return -1
	}
	gid, err := strconv.Atoi(g.Gid)
	if err != nil {
		return -1
	}
	return gid
}

func splitList(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func maskUUID(u string) string {
	if len(u) <= 8 {
		return "****"
	}
	return u[:8] + "-****"
}

func displayTag(o *link.Outbound) string {
	if o.Tag != "" {
		return o.Tag
	}
	return "без имени"
}

func orDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
