package backupemulator

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"net"
	"time"
)

// loadOrGenCert — сертификат из файлов конфигурации либо самоподписанный
// (для тестов/первичного запуска; в продакшене — реальный сертификат домена).
func loadOrGenCert(cfg *ServerConfig) (tls.Certificate, error) {
	if cfg.CertFile != "" && cfg.KeyFile != "" {
		return tls.LoadX509KeyPair(cfg.CertFile, cfg.KeyFile)
	}
	host := cfg.Host
	if host == "" {
		host = "localhost"
	}
	return SelfSignedCert([]string{host})
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
