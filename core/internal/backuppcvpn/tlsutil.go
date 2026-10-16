package backuppcvpn

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// loadOrGenCert — сертификат из файлов конфигурации, либо
// самоподписанный с персистенцией в <dataDir>/selfsigned.{pem,key}.
//
// Цель: фингерпринт должен быть стабилен между перезапусками сервера
// (при пустых certFile/keyFile). Пароды self-signed без этого создают новый ключ ECDSA P-256
// и новый serial на каждом старте — отпечаток меняется, клиенты с пиннингом
// по нему перестают подключаться.
//
// Параллель с loadOrCreateToken в main.go: первый запуск — генерация + запись атомарно (tmp+rename, 0o600),
// последующие — прочтение с диска. Если dataDir пуст — падаем в in-memory
// SelfSignedCert (старое поведение для тестов).
func loadOrGenCert(cfg *ServerConfig) (tls.Certificate, error) {
	if cfg.CertFile != "" && cfg.KeyFile != "" {
		return tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	}
	host := cfg.Host
	if host == "" {
		host = "localhost"
	}
	if cfg.DataDir == "" {
		// Без dataDir (тесты, эмулятор) — in-memory, как раньше.
		return SelfSignedCert([]string{host})
	}
	return loadOrGenSelfSignedCert([]string{host}, cfg.DataDir)
}

// loadOrGenSelfSignedCert — прочитать <dataDir>/selfsigned.{pem,key}; если нет — сгенерировать
// и персистить атомарно (tmp+rename, 0o600).
func loadOrGenSelfSignedCert(hosts []string, dataDir string) (tls.Certificate, error) {
	certPath := filepath.Join(dataDir, "selfsigned.pem")
	keyPath := filepath.Join(dataDir, "selfsigned.key")

	if cert, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		return cert, nil
	} else if !errors.Is(err, os.ErrNotExist) && !os.IsNotExist(err) {
		// Файл есть, но не читается — не перезаписываем молча, чтобы не потерять конфиг оператора.
		return tls.Certificate{}, fmt.Errorf("selfsigned cert: чтение %s/%s: %w", certPath, keyPath, err)
	}

	// Генерация + персистенция.
	cert, err := SelfSignedCert(hosts)
	if err != nil {
		return tls.Certificate{}, err
	}
	if err := persistSelfSigned(certPath, keyPath, cert); err != nil {
		return tls.Certificate{}, fmt.Errorf("selfsigned cert: %w", err)
	}
	return cert, nil
}

// persistSelfSigned — атомарная запись PEM-файлов (tmp+rename, 0o600).
// Условие: dataDir уже создан (main.go: os.MkdirAll(*dataDir, 0o700)).
func persistSelfSigned(certPath, keyPath string, cert tls.Certificate) error {
	if err := os.MkdirAll(filepath.Dir(certPath), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(certPath), err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]})
	keyDER, err := x509.MarshalECPrivateKey(cert.PrivateKey.(*ecdsa.PrivateKey))
	if err != nil {
		return fmt.Errorf("marshal key: %w", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	// Атомарно: tmp+rename, 0o600. Чтобы не оставить половину при сбое — пишем оба файла через .tmp.
	for _, p := range []struct{ path, data string }{
		{certPath, string(certPEM)},
		{keyPath, string(keyPEM)},
	} {
		tmp := p.path + ".tmp"
		if err := os.WriteFile(tmp, []byte(p.data), 0o600); err != nil {
			_ = os.Remove(tmp)
			return fmt.Errorf("write %s: %w", tmp, err)
		}
		if err := os.Rename(tmp, p.path); err != nil {
			_ = os.Remove(tmp)
			return fmt.Errorf("rename %s → %s: %w", tmp, p.path, err)
		}
	}
	return nil
}

// SelfSignedCert — ECDSA P-256 сертификат "шлюза хранилища".
func SelfSignedCert(hosts []string) (tls.Certificate, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, big.NewInt(1<<62))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   hosts[0],
			Organization: []string{"Storage Cloud Ltd"},
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(90 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
	}
	seen := map[string]bool{}
	addHost := func(h string) {
		h = stripBrackets(h) // IPv6 literal "[2001:db8::1]" → "2001:db8::1"
		if h == "" || seen[h] {
			return
		}
		seen[h] = true
		if ip := net.ParseIP(h); ip != nil {
			tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
		} else {
			tmpl.DNSNames = append(tmpl.DNSNames, h)
		}
	}
	for _, h := range hosts {
		addHost(h)
	}
	addHost("localhost")
	addHost("127.0.0.1")
	addHost("::1")

	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{
		Certificate: [][]byte{der},
		PrivateKey:  key,
	}, nil
}

// CertFingerprint — SHA-256 (hex) leaf-сертификата для пиннинга.
func CertFingerprint(cert tls.Certificate) string {
	if len(cert.Certificate) == 0 {
		return ""
	}
	sum := sha256.Sum256(cert.Certificate[0])
	return hex.EncodeToString(sum[:])
}

// clientTLSConfig — TLS клиента: ALPN h2, домен-донор в SNI и опциональный
// пиннинг по SHA-256 отпечатку вместо CA-верификации.
func clientTLSConfig(cfg *ClientConfig) (*tls.Config, error) {
	if cfg.CertFingerprint != "" && cfg.Insecure {
		return nil, errors.New("config: указан и insecure, и certFingerprint — выберите одно")
	}
	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"h2"},
	}
	if cfg.Host != "" {
		tlsCfg.ServerName = cfg.Host // SNI домена-донора
	}
	if cfg.CertFingerprint != "" {
		want := cfg.CertFingerprint
		tlsCfg.InsecureSkipVerify = true // верификация только по пину
		tlsCfg.VerifyPeerCertificate = func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("tls: сервер не предоставил сертификат")
			}
			sum := sha256.Sum256(rawCerts[0])
			got := hex.EncodeToString(sum[:])
			if got != want {
				return fmt.Errorf("tls: отпечаток не совпал (пиннинг): got %s", got)
			}
			return nil
		}
		return tlsCfg, nil
	}
	if cfg.Insecure {
		tlsCfg.InsecureSkipVerify = true
	}
	return tlsCfg, nil
}
