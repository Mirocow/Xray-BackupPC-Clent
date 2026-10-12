// Package link — share-ссылки backuppc:// для импорта серверов в OneXray.
//
// Формат повторяет vless://: authority несет uuid и адрес сервера,
// параметры запроса — профиль маскировки, фрагмент — имя узла:
//
//	backuppc://<uuid>@<server-host>:<port>/?host=<домен-донор>&fp=<sha256>&insecure=0#My%20Server
//
// Ссылка разворачивается в JSON outbound-а Xray с protocol=="backuppc"
// (settings совпадают со схемой транспортной библиотеки).
package link

import (
	"fmt"
	"net/url"
	"strconv"
	"strings"
)

// Scheme — схема ссылки.
const Scheme = "backuppc"

// Outbound — минимальная модель outbound-а для генерации/разбора.
type Outbound struct {
	Tag             string
	ServerAddr      string // host:port
	UUID            string
	Host            string // домен-донор (Host/SNI)
	CertFingerprint string
	Insecure        bool
	UserAgent       string
	EndpointPaths   []string
	MinPadding      int
	MaxPadding      int
}

// ParseLink разбирает backuppc://-ссылку. Порт опускается → 443.
func ParseLink(link string) (*Outbound, error) {
	u, err := url.Parse(strings.TrimSpace(link))
	if err != nil {
		return nil, fmt.Errorf("backuppc link: %w", err)
	}
	if !strings.EqualFold(u.Scheme, Scheme) {
		return nil, fmt.Errorf("backuppc link: схема %q, ожидается %s://", u.Scheme, Scheme)
	}
	if u.User == nil || u.User.Username() == "" {
		return nil, fmt.Errorf("backuppc link: отсутствует uuid в userinfo")
	}
	out := &Outbound{
		UUID: u.User.Username(),
		Host: u.Hostname(),
	}
	if out.Host == "" {
		return nil, fmt.Errorf("backuppc link: отсутствует адрес сервера")
	}
	port := 443
	if p := u.Port(); p != "" {
		if v, err := strconv.Atoi(p); err == nil && v > 0 && v < 65536 {
			port = v
		} else {
			return nil, fmt.Errorf("backuppc link: некорректный порт %q", p)
		}
	}
	out.ServerAddr = netJoinHostPort(out.Host, port)

	q := u.Query()
	out.Host = q.Get("host")
	if out.Host == "" {
		out.Host = q.Get("sni")
	}
	out.CertFingerprint = strings.ToLower(q.Get("fp"))
	if out.CertFingerprint == "" {
		out.CertFingerprint = strings.ToLower(q.Get("fingerprint"))
	}
	switch v := strings.ToLower(q.Get("insecure")); v {
	case "1", "true", "yes":
		out.Insecure = true
	case "", "0", "false", "no":
	default:
		return nil, fmt.Errorf("backuppc link: некорректный insecure=%q", v)
	}
	out.UserAgent = q.Get("ua")
	if eps := q.Get("endpoints"); eps != "" {
		for _, e := range strings.Split(eps, ",") {
			if e = strings.TrimSpace(e); e != "" {
				out.EndpointPaths = append(out.EndpointPaths, e)
			}
		}
	}
	if pad := q.Get("pad"); pad != "" {
		lo, hi, err := parsePadRange(pad)
		if err != nil {
			return nil, fmt.Errorf("backuppc link: %w", err)
		}
		out.MinPadding, out.MaxPadding = lo, hi
	}
	out.Tag = strings.TrimSpace(u.Fragment)
	return out, nil
}

// OutboundJSON — JSON-представление outbound-а Xray (один элемент outbounds).
func (o *Outbound) OutboundJSON() map[string]any {
	settings := map[string]any{
		"serverAddr": o.ServerAddr,
		"uuid":       o.UUID,
	}
	if o.Host != "" {
		settings["host"] = o.Host
	}
	if o.CertFingerprint != "" {
		settings["certFingerprint"] = strings.ToLower(o.CertFingerprint)
	}
	if o.Insecure {
		settings["insecure"] = true
	}
	if o.UserAgent != "" {
		settings["userAgent"] = o.UserAgent
	}
	if len(o.EndpointPaths) > 0 {
		settings["endpointPaths"] = o.EndpointPaths
	}
	if o.MinPadding != 0 && o.MaxPadding != 0 {
		settings["minPaddingSize"] = o.MinPadding
		settings["maxPaddingSize"] = o.MaxPadding
	}
	outbound := map[string]any{
		"protocol": Scheme,
		"settings": settings,
	}
	if tag := strings.TrimSpace(o.Tag); tag != "" {
		outbound["tag"] = tag
	}
	return outbound
}

// BuildLink собирает share-ссылку из outbound-модели (обратный ParseLink).
func (o *Outbound) BuildLink() string {
	host, port := splitServerAddr(o.ServerAddr)
	u := &url.URL{
		Scheme: Scheme,
		User:   url.User(o.UUID),
		Host:   netJoinHostPort(host, port),
	}
	q := url.Values{}
	if o.Host != "" {
		q.Set("host", o.Host)
	}
	if o.CertFingerprint != "" {
		q.Set("fp", strings.ToLower(o.CertFingerprint))
	}
	if o.Insecure {
		q.Set("insecure", "1")
	}
	if o.UserAgent != "" {
		q.Set("ua", o.UserAgent)
	}
	if len(o.EndpointPaths) > 0 {
		q.Set("endpoints", strings.Join(o.EndpointPaths, ","))
	}
	if o.MinPadding != 0 && o.MaxPadding != 0 {
		q.Set("pad", fmt.Sprintf("%d-%d", o.MinPadding, o.MaxPadding))
	}
	u.RawQuery = q.Encode()
	if tag := strings.TrimSpace(o.Tag); tag != "" {
		u.Fragment = tag
	}
	return u.String()
}

// parsePadRange — «32-1400» → (32, 1400).
func parsePadRange(s string) (int, int, error) {
	lo, hi, ok := strings.Cut(s, "-")
	if !ok {
		return 0, 0, fmt.Errorf("pad=%q ожидается в формате MIN-MAX", s)
	}
	a, err1 := strconv.Atoi(strings.TrimSpace(lo))
	b, err2 := strconv.Atoi(strings.TrimSpace(hi))
	if err1 != nil || err2 != nil || a <= 0 || b < a {
		return 0, 0, fmt.Errorf("pad=%q: некорректный диапазон", s)
	}
	return a, b, nil
}

// netJoinHostPort — host:port с учетом IPv6-скобок.
func netJoinHostPort(host string, port int) string {
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		return "[" + host + "]:" + strconv.Itoa(port)
	}
	return host + ":" + strconv.Itoa(port)
}

// splitServerAddr — «host:port» → (host, port), порт 443 по умолчанию.
func splitServerAddr(addr string) (string, int) {
	i := strings.LastIndex(addr, ":")
	if i < 0 {
		return addr, 443
	}
	port, err := strconv.Atoi(addr[i+1:])
	if err != nil || port <= 0 {
		return addr, 443
	}
	return strings.Trim(addr[:i], "[]"), port
}
