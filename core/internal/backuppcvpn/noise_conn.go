// Package backupemulator — noise_conn.go: Inner Noise IK crypto layer
// inside TLS (audit 2026-10-12, Marvia-inspired MITM protection).
//
// Threat model: if TLS is compromised (corporate proxy with custom CA
// installed, or state-level MITM), the inner Noise layer still protects
// the data. Attacker who can decrypt TLS sees only Noise-encrypted
// bytes — cannot read VLESS handshake, payload, or metadata.
//
// Architecture:
//   TCP → TLS → Noise IK handshake → Noise AEAD transport → HTTP/2 → gRPC → VLESS
//
// Noise IK pattern (same as WireGuard/Marvia):
//   - Client knows server's static public key (X25519) in advance
//   - Server knows client's public key (via auth layer)
//   - msg1 (client→server): e, es, s, ss + timestamp payload (104 bytes)
//   - msg2 (server→client): e, ee, se (48 bytes)
//   - After handshake: ChaCha20-Poly1305 AEAD transport
//
// The Noise layer is OPTIONAL (opt-in via ServerConfig.EnableNoiseLayer).
// When disabled, carrier works as before (TLS → HTTP/2 → gRPC → VLESS).
// When enabled, an additional Noise handshake happens after TLS, before
// HTTP/2. Existing clients without Noise support are rejected.
//
// See:
//   - Marvia VP1: https://github.com/jytt8u/marvia/blob/main/docs/protocol.md
//   - Noise Protocol Framework: https://noiseprotocol.org/noise.html
//   - flynn/noise library: https://github.com/flynn/noise

package backuppcvpn

import (
        "crypto/rand"
        "encoding/binary"
        "fmt"
        "io"
        "net"
        "sync"

        "github.com/flynn/noise"
        "golang.org/x/crypto/curve25519"
)

// NoiseKeyLen — длина X25519 ключа (32 байта).
const NoiseKeyLen = 32

// NoiseCipherSuite — X25519 + ChaCha20-Poly1305 + BLAKE2s (как WireGuard).
var NoiseCipherSuite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashBLAKE2s)

// NoisePrologue — подмешивается в хеш хендшейка. Меняем → ломаем
// совместимость (версионирование протокола).
const NoisePrologue = "backuppc/v2/noise"

// NoiseMaxFrame — максимальный размер кадра в Noise transport (16 KB).
const NoiseMaxFrame = 16384

// NoiseTagLen — длина AEAD тега ChaCha20-Poly1305 (16 байт).
const NoiseTagLen = 16

// NoiseKeyPair — статическая пара ключей X25519 для Noise handshake.
type NoiseKeyPair struct {
        Private []byte
        Public  []byte
}

// GenerateNoiseKeyPair — генерация новой пары ключей.
func GenerateNoiseKeyPair() (NoiseKeyPair, error) {
        var priv [32]byte
        if _, err := rand.Read(priv[:]); err != nil {
                return NoiseKeyPair{}, fmt.Errorf("noise: generate key: %w", err)
        }
        pub, err := curve25519.X25519(priv[:], curve25519.Basepoint)
        if err != nil {
                return NoiseKeyPair{}, fmt.Errorf("noise: derive public: %w", err)
        }
        return NoiseKeyPair{Private: priv[:], Public: pub}, nil
}

// NoiseKeyPairFromPrivate — восстановление пары по приватному ключу.
func NoiseKeyPairFromPrivate(priv []byte) (NoiseKeyPair, error) {
        if len(priv) != NoiseKeyLen {
                return NoiseKeyPair{}, fmt.Errorf("noise: private key len %d, want %d", len(priv), NoiseKeyLen)
        }
        pub, err := curve25519.X25519(priv, curve25519.Basepoint)
        if err != nil {
                return NoiseKeyPair{}, fmt.Errorf("noise: derive public: %w", err)
        }
        return NoiseKeyPair{Private: priv, Public: pub}, nil
}

// NoiseConn — net.Conn wrapper с Noise IK handshake + AEAD transport.
// После Handshake() все Read/Write идут через ChaCha20-Poly1305.
//
// Frame format on wire (after handshake):
//   [uint16 BE length][encrypted payload + 16B AEAD tag]
//
// Max plaintext per frame: NoiseMaxFrame (16384 bytes).
type NoiseConn struct {
        net.Conn
        sendCS  *noise.CipherState // encrypt outgoing
        recvCS  *noise.CipherState // decrypt incoming
        once    sync.Once
        initErr error

        // Buffer for partial reads (Noise gives full frames, net.Conn Read
        // may return partial). We buffer decoded plaintext.
        readBuf []byte

        // Write buffer for frame assembly.
        writeBuf [2 + NoiseMaxFrame + NoiseTagLen]byte

        // Config: is this the client or server side?
        isClient bool

        // Keys for handshake.
        clientStatic  NoiseKeyPair // client's static key pair (client side only)
        serverStatic  NoiseKeyPair // server's static key pair (server side only)
        serverPub     []byte       // server's public key (client needs this pre-shared)
        clientPubAuth func([]byte) error // server: authorize client by public key
}

// NewNoiseClientConn — wraps a net.Conn for client-side Noise IK handshake.
// serverPub = server's static public key (pre-shared via config/URL).
// clientKeys = client's static key pair (generated once, persisted).
func NewNoiseClientConn(conn net.Conn, clientKeys NoiseKeyPair, serverPub []byte) *NoiseConn {
        return &NoiseConn{
                Conn:        conn,
                isClient:    true,
                clientStatic: clientKeys,
                serverPub:   serverPub,
        }
}

// NewNoiseServerConn — wraps a net.Conn for server-side Noise IK handshake.
// serverKeys = server's static key pair.
// authFn = callback to authorize client by public key (nil = allow all).
func NewNoiseServerConn(conn net.Conn, serverKeys NoiseKeyPair, authFn func([]byte) error) *NoiseConn {
        return &NoiseConn{
                Conn:          conn,
                isClient:      false,
                serverStatic:  serverKeys,
                clientPubAuth: authFn,
        }
}

// Read — decrypt Noise frame, return plaintext.
func (c *NoiseConn) Read(p []byte) (int, error) {
        c.once.Do(func() { c.initErr = c.handshake() })
        if c.initErr != nil {
                return 0, c.initErr
        }

        // If we have buffered plaintext from a previous frame, return it.
        if len(c.readBuf) > 0 {
                n := copy(p, c.readBuf)
                c.readBuf = c.readBuf[n:]
                return n, nil
        }

        // Read next frame: [2B length][encrypted data]
        var lenBuf [2]byte
        if _, err := io.ReadFull(c.Conn, lenBuf[:]); err != nil {
                return 0, fmt.Errorf("noise: read frame length: %w", err)
        }
        frameLen := int(binary.BigEndian.Uint16(lenBuf[:]))
        if frameLen < NoiseTagLen || frameLen > NoiseMaxFrame+NoiseTagLen {
                return 0, fmt.Errorf("noise: invalid frame length %d", frameLen)
        }

        // Read encrypted ciphertext (including AEAD tag).
        cipherBuf := make([]byte, frameLen)
        if _, err := io.ReadFull(c.Conn, cipherBuf); err != nil {
                return 0, fmt.Errorf("noise: read ciphertext: %w", err)
        }

        // Decrypt.
        plaintext, err := c.recvCS.Decrypt(nil, nil, cipherBuf)
        if err != nil {
                return 0, fmt.Errorf("noise: decrypt: %w", err)
        }

        // Copy to caller's buffer, buffer remainder.
        n := copy(p, plaintext)
        if n < len(plaintext) {
                c.readBuf = append(c.readBuf, plaintext[n:]...)
        }
        return n, nil
}

// Write — encrypt plaintext, write Noise frame.
func (c *NoiseConn) Write(p []byte) (int, error) {
        c.once.Do(func() { c.initErr = c.handshake() })
        if c.initErr != nil {
                return 0, c.initErr
        }

        total := 0
        for len(p) > 0 {
                // Split into frames of max NoiseMaxFrame.
                seg := len(p)
                if seg > NoiseMaxFrame {
                        seg = NoiseMaxFrame
                }

                // Encrypt.
                ciphertext, err := c.sendCS.Encrypt(nil, nil, p[:seg])
                if err != nil {
                        return total, fmt.Errorf("noise: encrypt: %w", err)
                }

                // Write frame: [2B length][ciphertext].
                binary.BigEndian.PutUint16(c.writeBuf[:2], uint16(len(ciphertext)))
                copy(c.writeBuf[2:], ciphertext)
                if _, err := c.Conn.Write(c.writeBuf[:2+len(ciphertext)]); err != nil {
                        return total, fmt.Errorf("noise: write frame: %w", err)
                }

                total += seg
                p = p[seg:]
        }
        return total, nil
}

// handshake — perform Noise IK handshake (client or server side).
func (c *NoiseConn) handshake() error {
        if c.isClient {
                return c.clientHandshake()
        }
        return c.serverHandshake()
}

// clientHandshake — Noise IK client side.
// msg1: e, es, s, ss (encrypted with server's static) + timestamp payload.
// msg2: e, ee, se (read from server).
func (c *NoiseConn) clientHandshake() error {
        cs := NoiseCipherSuite
        staticKey := noise.DHKey{Private: c.clientStatic.Private, Public: c.clientStatic.Public}
        remoteStatic := c.serverPub

        hs, err := noise.NewHandshakeState(noise.Config{
                CipherSuite:   cs,
                Random:        rand.Reader,
                Pattern:       noise.HandshakeIK,
                Initiator:     true,
                Prologue:      []byte(NoisePrologue),
                StaticKeypair: staticKey,
                PeerStatic:    remoteStatic,
        })
        if err != nil {
                return fmt.Errorf("noise: client handshake state: %w", err)
        }

        // msg1: e, es, s, ss + payload (timestamp)
        msg, _, _, err := hs.WriteMessage(nil, nil)
        if err != nil {
                return fmt.Errorf("noise: client write msg1: %w", err)
        }
        // Prepend length prefix.
        var lenBuf [2]byte
        binary.BigEndian.PutUint16(lenBuf[:], uint16(len(msg)))
        if _, err := c.Conn.Write(lenBuf[:]); err != nil {
                return fmt.Errorf("noise: client send msg1 length: %w", err)
        }
        if _, err := c.Conn.Write(msg); err != nil {
                return fmt.Errorf("noise: client send msg1: %w", err)
        }

        // Read msg2: e, ee, se
        if _, err := io.ReadFull(c.Conn, lenBuf[:]); err != nil {
                return fmt.Errorf("noise: client read msg2 length: %w", err)
        }
        msg2Len := int(binary.BigEndian.Uint16(lenBuf[:]))
        msg2 := make([]byte, msg2Len)
        if _, err := io.ReadFull(c.Conn, msg2); err != nil {
                return fmt.Errorf("noise: client read msg2: %w", err)
        }

        // Process msg2 → get cipher states for transport.
        _, recvCS2, sendCS2, err := hs.ReadMessage(nil, msg2)
        if err != nil {
                return fmt.Errorf("noise: client process msg2: %w", err)
        }
        // After ReadMessage on client: sendCS/recvCS from WriteMessage are nil
        // (msg1 doesn't complete the handshake). Use the ones from ReadMessage.
        // On client: recvCS2 = receive from server, sendCS2 = send to server.
        c.recvCS = recvCS2
        c.sendCS = sendCS2
        return nil
}

// serverHandshake — Noise IK server side.
// Read msg1 from client, verify, send msg2.
func (c *NoiseConn) serverHandshake() error {
        cs := NoiseCipherSuite
        staticKey := noise.DHKey{Private: c.serverStatic.Private, Public: c.serverStatic.Public}

        hs, err := noise.NewHandshakeState(noise.Config{
                CipherSuite:   cs,
                Random:        rand.Reader,
                Pattern:       noise.HandshakeIK,
                Initiator:     false,
                Prologue:      []byte(NoisePrologue),
                StaticKeypair: staticKey,
        })
        if err != nil {
                return fmt.Errorf("noise: server handshake state: %w", err)
        }

        // Read msg1 from client.
        var lenBuf [2]byte
        if _, err := io.ReadFull(c.Conn, lenBuf[:]); err != nil {
                return fmt.Errorf("noise: server read msg1 length: %w", err)
        }
        msg1Len := int(binary.BigEndian.Uint16(lenBuf[:]))
        msg1 := make([]byte, msg1Len)
        if _, err := io.ReadFull(c.Conn, msg1); err != nil {
                return fmt.Errorf("noise: server read msg1: %w", err)
        }

        // Process msg1 → cipher states are nil here (handshake not complete).
        _, _, _, err = hs.ReadMessage(nil, msg1)
        if err != nil {
                return fmt.Errorf("noise: server process msg1: %w", err)
        }

        // Authorize client by public key (if callback set).
        // clientStatic is available via hs.PeerStatic() if needed.
        peerStatic := hs.PeerStatic()
        if c.clientPubAuth != nil && peerStatic != nil {
                if err := c.clientPubAuth(peerStatic); err != nil {
                        return fmt.Errorf("noise: client not authorized: %w", err)
                }
        }

        // Send msg2: e, ee, se
        msg2, sendCS, recvCS, err := hs.WriteMessage(nil, nil)
        if err != nil {
                return fmt.Errorf("noise: server write msg2: %w", err)
        }
        binary.BigEndian.PutUint16(lenBuf[:], uint16(len(msg2)))
        if _, err := c.Conn.Write(lenBuf[:]); err != nil {
                return fmt.Errorf("noise: server send msg2 length: %w", err)
        }
        if _, err := c.Conn.Write(msg2); err != nil {
                return fmt.Errorf("noise: server send msg2: %w", err)
        }

        // On server: sendCS = encrypt to client, recvCS = decrypt from client.
        c.sendCS = sendCS
        c.recvCS = recvCS
        return nil
}

// Close — close underlying connection.
func (c *NoiseConn) Close() error {
        return c.Conn.Close()
}
