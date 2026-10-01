package backupemulator

import (
	"bufio"
	"bytes"
	"strings"
	"testing"
)

// TestVlessRoundTrip — кодирование/декодирование VLESS-заголовков
// для IPv4, домена и IPv6 + остаток потока за заголовком.
func TestVlessRoundTrip(t *testing.T) {
	id, err := ParseUUID("52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e90")
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		addr string
		port uint16
	}{
		{"example.com", 443},
		{"192.0.2.10", 80},
		{"2001:db8::1", 22},
		{"a-very-long-domain-name.example.storage.internal", 8443},
	}
	for _, tc := range cases {
		req := BuildVlessRequest(id, tc.addr, tc.port)
		br := bufio.NewReader(bytes.NewReader(req))
		got, err := ParseVlessRequest(br)
		if err != nil {
			t.Fatalf("[%s]: %v", tc.addr, err)
		}
		if got.UUID != id {
			t.Fatalf("[%s]: UUID не совпал", tc.addr)
		}
		if got.Address != tc.addr {
			t.Fatalf("[%s]: адрес: got %q", tc.addr, got.Address)
		}
		if got.Port != tc.port {
			t.Fatalf("[%s]: порт: got %d", tc.addr, got.Port)
		}
		if got.Command != vlessCmdTCP {
			t.Fatalf("[%s]: команда: %d", tc.addr, got.Command)
		}
		// остаток потока за заголовком не должен теряться
		tail := []byte("PAYLOAD-DATA")
		full := append(append([]byte{}, req...), tail...)
		br2 := bufio.NewReader(bytes.NewReader(full))
		if _, err := ParseVlessRequest(br2); err != nil {
			t.Fatalf("[%s]: второй разбор: %v", tc.addr, err)
		}
		rest, _ := br2.Read(make([]byte, 64))
		if !bytes.Equal(full[len(req):len(req)+rest], tail) || br2.Buffered() != 0 {
			t.Fatalf("[%s]: остаток за заголовком потерян (buffered=%d)", tc.addr, br2.Buffered())
		}
	}
}

// TestParseUUID — форматы с дефисами и без.
func TestParseUUID(t *testing.T) {
	if _, err := ParseUUID("52724a0e6d3a4b1c9f2e8a7c3d5b1e90"); err != nil {
		t.Fatalf("без дефисов: %v", err)
	}
	if _, err := ParseUUID("not-a-uuid"); err == nil {
		t.Fatal("мусор должен давать ошибку")
	}
	if _, err := ParseUUID("52724a0e-6d3a-4b1c-9f2e-8a7c3d5b1e9"); err == nil {
		t.Fatal("короткий UUID должен давать ошибку")
	}
}

// TestBuildVlessResponse — двухбайтный ответ.
func TestBuildVlessResponse(t *testing.T) {
	resp := BuildVlessResponse()
	if len(resp) != 2 || resp[0] != vlessVersion || resp[1] != 0 {
		t.Fatalf("ответ VLESS: %v", resp)
	}
}

// TestVlessBadInput — мусор отклоняется (анти-пробинг).
func TestVlessBadInput(t *testing.T) {
	if _, err := ParseVlessRequest(bytes.NewReader(nil)); err == nil {
		t.Fatal("пустой поток должен давать ошибку")
	}
	garbage := bytes.Repeat([]byte{0xAB}, 64)
	if _, err := ParseVlessRequest(bytes.NewReader(garbage)); err == nil {
		t.Fatal("мусор должен давать ошибку")
	}
	if !strings.Contains("x", "x") {
		t.Fatal("unreachable")
	}
}
