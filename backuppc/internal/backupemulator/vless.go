package backupemulator

import (
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
)

// VLESS data-plane заголовок запроса:
//
//	+---------+------+-------------+---------+--------+--------+---------+
//	| Version | UUID | Addons Len  | Addons  | Command| Port   | Address |
//	|  1B     | 16B  | 1B          | X B     | 1B     | 2B BE  | type+val|
//	+---------+------+-------------+---------+--------+--------+---------+
//
// Address: 0x01 = IPv4 (4B), 0x02 = домен (1B длина + байты), 0x03 = IPv6 (16B).
// Ответ сервера: [Version (1B)][Addons Length (1B)] — 2 байта, затем поток.

const (
	vlessVersion    = 0x00
	vlessCmdTCP     = 0x01
	vlessCmdUDP     = 0x02
	vlessAtypIPv4   = 0x01
	vlessAtypDomain = 0x02
	vlessAtypIPv6   = 0x03
	vlessHeaderMin  = 1 + 16 + 1 + 1 + 2 + 1 // 22 байта без адреса
)

// ErrBadVless — некорректный VLESS-заголовок (анти-пробинг: лог + мимикрия 413).
var ErrBadVless = errors.New("vless: некорректный заголовок запроса")

// ErrUUIDMismatch — UUID не зарегистрирован на сервере.
var ErrUUIDMismatch = errors.New("vless: UUID не авторизован")

// ErrUnsupportedCommand — поддержан только TCP (command 0x01).
var ErrUnsupportedCommand = errors.New("vless: поддерживается только команда TCP")

// BuildVlessRequest — кодирование клиентского запроса VLESS (TCP).
func BuildVlessRequest(id [16]byte, address string, port uint16) []byte {
	// адрес
	var atyp byte
	var addr []byte
	if ip := net.ParseIP(stripBrackets(address)); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			atyp = vlessAtypIPv4
			addr = v4
		} else {
			atyp = vlessAtypIPv6
			addr = ip.To16()
		}
	} else {
		atyp = vlessAtypDomain
		addr = make([]byte, 1+len(address))
		addr[0] = byte(len(address))
		copy(addr[1:], address)
	}
	buf := make([]byte, 0, vlessHeaderMin+len(addr)+16)
	buf = append(buf, vlessVersion)
	buf = append(buf, id[:]...)
	buf = append(buf, 0) // addons length = 0
	buf = append(buf, vlessCmdTCP)
	buf = append(buf, byte(port>>8), byte(port&0xFF))
	buf = append(buf, atyp)
	buf = append(buf, addr...)
	return buf
}

// VlessTarget — разобранный заголовок.
type VlessTarget struct {
	UUID      [16]byte
	Command   byte
	Address   string
	Port      uint16
	HeaderLen int // сколько байт потока съел заголовок
}

// ParseVlessRequest — разбор заголовка из потока (последовательное чтение;
// удобно оборачивать bufio.Reader — остаток буфера не теряется).
func ParseVlessRequest(r io.Reader) (*VlessTarget, error) {
	var hdr [22]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrBadVless, err)
	}
	t := &VlessTarget{}
	if hdr[0] != vlessVersion {
		return nil, fmt.Errorf("%w: версия %d не поддерживается", ErrBadVless, hdr[0])
	}
	copy(t.UUID[:], hdr[1:17])
	addonsLen := int(hdr[17])
	if addonsLen > 0 {
		addons := getFrameBuf(addonsLen)
		if _, err := io.ReadFull(r, addons); err != nil {
			putFrameBuf(addons)
			return nil, fmt.Errorf("%w: addons: %v", ErrBadVless, err)
		}
		putFrameBuf(addons)
	}
	t.Command = hdr[18]
	t.Port = uint16(hdr[19])<<8 | uint16(hdr[20])
	atyp := hdr[21]
	used := len(hdr) + addonsLen
	var addr []byte
	switch atyp {
	case vlessAtypIPv4:
		addr = make([]byte, 4)
		if _, err := io.ReadFull(r, addr); err != nil {
			return nil, fmt.Errorf("%w: ipv4: %v", ErrBadVless, err)
		}
		t.Address = net.IP(addr).String()
		used += 4
	case vlessAtypIPv6:
		addr = make([]byte, 16)
		if _, err := io.ReadFull(r, addr); err != nil {
			return nil, fmt.Errorf("%w: ipv6: %v", ErrBadVless, err)
		}
		t.Address = net.IP(addr).String()
		used += 16
	case vlessAtypDomain:
		var l [1]byte
		if _, err := io.ReadFull(r, l[:]); err != nil {
			return nil, fmt.Errorf("%w: domain len: %v", ErrBadVless, err)
		}
		addr = make([]byte, l[0])
		if _, err := io.ReadFull(r, addr); err != nil {
			return nil, fmt.Errorf("%w: domain: %v", ErrBadVless, err)
		}
		t.Address = string(addr)
		used += 1 + int(l[0])
	default:
		return nil, fmt.Errorf("%w: неизвестный тип адреса %d", ErrBadVless, atyp)
	}
	t.HeaderLen = used
	return t, nil
}

// Target — адрес назначения в формате dial.
func (t *VlessTarget) Target() string {
	return net.JoinHostPort(stripBrackets(t.Address), strconv.Itoa(int(t.Port)))
}

// stripBrackets — IPv6-литерал в скобках («[2a00:…]», так его отдаёт
// xray-core ipv6Address.String) → без скобок: net.ParseIP скобки не
// понимает, и адрес уезжал бы полем «домен» — сервер дважды оборачивал
// его в скобки и диал падал («[[…]]:443: missing port»).
func stripBrackets(address string) string {
	if len(address) >= 2 && address[0] == '[' && address[len(address)-1] == ']' {
		return address[1 : len(address)-1]
	}
	return address
}

// BuildVlessResponse — заголовок ответа сервера: [version][addons len=0].
func BuildVlessResponse() []byte { return []byte{vlessVersion, 0x00} }
