package xray

import (
        "errors"
        "runtime/debug"
        "strings"
        "sync"

        "github.com/xtls/libxray/memory"
        "github.com/xtls/xray-core/core"

        backuppcpre "backuppc-core/preprocess" // backuppc-core: JSON preprocessing
        _ "backuppc-core/core/outbound"        // backuppc-core: native outbound handler
                                               // (registers {"protocol":"backuppc"} in
                                               //  Xray's protocol registry via init().
                                                   //  Without this, Xray on Android
                                                   //  says "unknown protocol: backuppc"
                                                   //  when compiler.dart emits native
                                                   //  outbound instead of socks.)
        _ "github.com/xtls/xray-core/main/distro/all"
)

var (
        coreServerMu sync.Mutex
        coreServer   *core.Instance
)

var ErrAlreadyRunning = errors.New("xray is already running")

func newXrayInstance(xrayJSON string) (*core.Instance, error) {
        patched, backuppcReplacements, err := backuppcpre.NormalizeJSON([]byte(xrayJSON))
        if err != nil {
                return nil, err
        }
        config, err := core.LoadConfig("json", strings.NewReader(string(patched)))
        if err != nil {
                return nil, err
        }
        if err := backuppcpre.Apply(config, backuppcReplacements); err != nil {
                return nil, err
        }

        server, err := core.New(config)
        if err != nil {
                return nil, err
        }

        return server, nil
}

// Run Xray instance.
// xrayJSON is the serialized Xray JSON configuration.
func RunXray(xrayJSON string) error {
        coreServerMu.Lock()
        defer coreServerMu.Unlock()
        if coreServer != nil {
                return ErrAlreadyRunning
        }
        memory.InitForceFree()
        server, err := newXrayInstance(xrayJSON)
        if err != nil {
                return err
        }
        if err = server.Start(); err != nil {
                _ = server.Close()
                return err
        }
        coreServer = server

        debug.FreeOSMemory()
        return nil
}

// Get Xray State
func GetXrayState() bool {
        coreServerMu.Lock()
        defer coreServerMu.Unlock()
        return coreServer != nil && coreServer.IsRunning()
}

// Stop Xray instance.
func StopXray() error {
        coreServerMu.Lock()
        defer coreServerMu.Unlock()
        if coreServer != nil {
                err := coreServer.Close()
                coreServer = nil
                if err != nil {
                        return err
                }
        }
        return nil
}

// Xray's version
func XrayVersion() string {
        return core.Version()
}
