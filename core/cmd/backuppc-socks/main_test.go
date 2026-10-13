package main

import (
	"os"
	"path/filepath"
	"testing"

	"backuppc-core/link"
)

const testLink = "backuppc://0b3e6f1a-1111-4222-8333-944455556666@203.0.113.7:8443/?host=backup.example.org&fp=ABCDEF&insecure=1&endpoints=%2Fa.B%2FC,%2Fd.E%2FF&pad=64-512#Office"

func TestClientConfigFromLink(t *testing.T) {
	o, err := link.ParseLink(testLink)
	if err != nil {
		t.Fatal(err)
	}
	c, err := clientConfig(o, "127.0.0.1:1081")
	if err != nil {
		t.Fatal(err)
	}
	if c.ServerAddr != "203.0.113.7:8443" || c.SocksListen != "127.0.0.1:1081" || c.UUID == "" {
		t.Errorf("addr/listen/uuid: %+v", c)
	}
	if c.CertFingerprint != "abcdef" || c.Insecure {
		t.Errorf("pinning must win over insecure: fp=%q insecure=%v", c.CertFingerprint, c.Insecure)
	}
	if c.Host != "backup.example.org" || len(c.EndpointPaths) != 2 || c.MinPaddingSize != 64 || c.MaxPaddingSize != 512 {
		t.Errorf("transport: %+v", c.TransportConfig)
	}
}

func TestClientConfigRejectsBadListen(t *testing.T) {
	o, _ := link.ParseLink(testLink)
	for _, l := range []string{"localhost:1080", "127.0.0.1", ":1080"} {
		if _, err := clientConfig(o, l); err == nil {
			t.Errorf("listen %q: expected error", l)
		}
	}
}

func TestCheckMode(t *testing.T) {
	f := filepath.Join(t.TempDir(), "l")
	os.WriteFile(f, []byte(testLink+"\n"), 0o600)
	if err := run([]string{"-check", "-link-file", f, "-listen", "127.0.0.1:1090"}); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(f, []byte("vless://x@y:1"), 0o600)
	if err := run([]string{"-check", "-link-file", f}); err == nil {
		t.Error("vless link must be rejected")
	}
}
