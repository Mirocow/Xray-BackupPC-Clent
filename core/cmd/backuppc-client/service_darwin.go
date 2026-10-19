package main

// Службы macOS — системные демоны launchd (/Library/LaunchDaemons):
// стартуют при загрузке, перезапускаются при падении. Остановка
// (bootout) шлёт SIGTERM — run снимает маршруты и возвращает DNS.

import (
	"fmt"
	"html"
	"io"
	"os"
	"strings"
)

const launchdPrefix = "local.backuppc-client."

func launchdPlist(label, exe, dir, mode, logPath string) string {
	args := []string{exe, "run", "-dir", dir, mode}
	var b strings.Builder
	for _, a := range args {
		fmt.Fprintf(&b, "\t\t<string>%s</string>\n", html.EscapeString(a))
	}
	return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + label + `</string>
	<key>ProgramArguments</key>
	<array>
` + b.String() + `	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>StandardOutPath</key>
	<string>` + html.EscapeString(logPath) + `</string>
	<key>StandardErrorPath</key>
	<string>` + html.EscapeString(logPath) + `</string>
</dict>
</plist>
`
}

func cmdService(args []string, stdout io.Writer) error {
	action, mode, dir, err := serviceArgs(args)
	if err != nil {
		return err
	}
	label := launchdPrefix + mode
	plist := "/Library/LaunchDaemons/" + label + ".plist"
	logPath := "/var/log/backuppc-client-" + mode + ".log"
	target := "system/" + label
	if action != "status" {
		if err := requireAdmin(); err != nil {
			return err
		}
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
		_, _ = sh("launchctl", "bootout", target) // переустановка
		if err := os.WriteFile(plist, []byte(launchdPlist(label, exe, dir, mode, logPath)), 0o644); err != nil {
			return err
		}
		if _, err := sh("launchctl", "bootstrap", "system", plist); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "служба %s установлена и запущена (журнал: %s)\n", label, logPath)
	case "uninstall":
		_, _ = sh("launchctl", "bootout", target)
		if err := os.Remove(plist); err != nil && !os.IsNotExist(err) {
			return err
		}
		fmt.Fprintf(stdout, "служба %s удалена\n", label)
	case "restart":
		if _, err := sh("launchctl", "kickstart", "-k", target); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "служба %s перезапущена\n", label)
	case "status":
		out, err := sh("launchctl", "print", target)
		if err != nil {
			fmt.Fprintf(stdout, "%s: не установлена\n", label)
			return nil
		}
		state, pid := "?", ""
		for _, line := range strings.Split(out, "\n") {
			line = strings.TrimSpace(line)
			if v, ok := strings.CutPrefix(line, "state = "); ok && state == "?" {
				state = v
			}
			if v, ok := strings.CutPrefix(line, "pid = "); ok && pid == "" {
				pid = " (pid " + v + ")"
			}
		}
		fmt.Fprintf(stdout, "%s: %s%s, журнал %s\n", label, state, pid, logPath)
	}
	return nil
}

// serviceMain — на macOS launchd запускает обычный run, отдельного
// служебного протокола нет.
func serviceMain(string, string) (bool, error) { return false, nil }
