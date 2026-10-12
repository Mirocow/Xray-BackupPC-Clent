package preprocess

import "testing"

// TestMergeTLSSettings — streamSettings.tlsSettings (кнопка «Транспорт»
// панели) мержится в настройки backuppc; явные поля settings выигрывают.
func TestMergeTLSSettings(t *testing.T) {
	doc := []byte(`{
	  "outbounds": [{
	    "tag": "bp",
	    "protocol": "backuppc",
	    "settings": {"address": "gw.example", "port": 8443, "uuid": "3f2a9c1e-7b44-4d8a-9c21-5e6b8d0a1f47"},
	    "streamSettings": {
	      "network": "tcp",
	      "security": "tls",
	      "tlsSettings": {
	        "serverName": "cdn.donor.example",
	        "allowInsecure": true,
	        "pinnedPeerCertificates": ["460D1C0E9F2B7A4D5C8E1F0A3B2C4D5E6F7A8B9C0D1E2F3A4B5C6D7E8F9A0B1C"]
	      }
	    }
	  }]
	}`)
	_, reps, err := NormalizeJSON(doc)
	if err != nil {
		t.Fatal(err)
	}
	if len(reps) != 1 {
		t.Fatalf("ожидался 1 replacement, got %d", len(reps))
	}
	cfg := reps[0].Config
	if cfg.GetHost() != "cdn.donor.example" {
		t.Fatalf("host: %q", cfg.GetHost())
	}
	if !cfg.GetInsecure() {
		t.Fatal("insecure должен перейти из allowInsecure")
	}
	wantFP := "460d1c0e9f2b7a4d5c8e1f0a3b2c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c"
	if cfg.GetCertFingerprint() != wantFP {
		t.Fatalf("certFingerprint: %q", cfg.GetCertFingerprint())
	}
}

// TestMergeTLSSettingsExplicitWins — явные поля settings приоритетнее
// tlsSettings.
func TestMergeTLSSettingsExplicitWins(t *testing.T) {
	doc := []byte(`{
	  "outbounds": [{
	    "tag": "bp",
	    "protocol": "backuppc",
	    "settings": {"address": "gw.example", "port": 8443, "uuid": "3f2a9c1e-7b44-4d8a-9c21-5e6b8d0a1f47",
	                 "host": "explicit.example", "insecure": false,
	                 "certFingerprint": "aa00000000000000000000000000000000000000000000000000000000000000"},
	    "streamSettings": {"security": "tls", "tlsSettings": {"serverName": "tls.example", "allowInsecure": true,
	                     "pinnedPeerCertificates": ["bb00000000000000000000000000000000000000000000000000000000000000"]}}
	  }]
	}`)
	_, reps, err := NormalizeJSON(doc)
	if err != nil {
		t.Fatal(err)
	}
	cfg := reps[0].Config
	if cfg.GetHost() != "explicit.example" {
		t.Fatalf("host: %q (должен остаться явный)", cfg.GetHost())
	}
	if cfg.GetInsecure() {
		t.Fatal("явный insecure=false в settings не должен перетираться allowInsecure")
	}
	if cfg.GetCertFingerprint() != "aa00000000000000000000000000000000000000000000000000000000000000" {
		t.Fatalf("certFingerprint: %q (должен остаться явный)", cfg.GetCertFingerprint())
	}
}
