package provider

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	UserAgent     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	MaxBodyBytes  = 8 * 1024 * 1024
	Timeout       = 12 * time.Second
	MaxBodyLimit  = 20 * 1024 * 1024
	plainTextHTML = `<[^>]{1,80}>`
)

var (
	rePlainText  = regexp.MustCompile(plainTextHTML)
	reNumericID  = regexp.MustCompile(`^[1-9][0-9]{0,17}$`)
	rePublicURL  = regexp.MustCompile(`(?i)(?:https?|socks5h?)://[^\s"'<>]+`)
	htmlEntities = strings.NewReplacer("&nbsp;", " ", "&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", `"`, "&#39;", "'")
)

func NativeText(value any) string {
	switch v := value.(type) {
	case string:
		return strings.TrimSpace(v)
	case map[string]any:
		for _, key := range []string{"url", "src", "cover", "image", "pic"} {
			if text := NativeText(v[key]); text != "" {
				return text
			}
		}
	case []any:
		for _, entry := range v {
			if text := NativeText(entry); text != "" {
				return text
			}
		}
	case json.Number:
		return string(v)
	case float64:
		return strconv.Itoa(int(v))
	case int:
		return strconv.Itoa(v)
	}
	return ""
}

func FirstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func Truncate(s string, n int) string {
	s = strings.TrimSpace(s)
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "..."
}

type RedactedError struct{ cause error }

func (err RedactedError) Error() string { return RedactErrorString(err.cause.Error()) }
func (err RedactedError) Unwrap() error { return err.cause }

func PublicError(err error) error {
	if err == nil {
		return nil
	}
	return RedactedError{cause: err}
}

func RedactErrorString(s string) string {
	return rePublicURL.ReplaceAllStringFunc(s, func(raw string) string {
		u, err := url.Parse(raw)
		if err != nil {
			return "[无效 URL 已隐藏]"
		}
		if u.Host == "" {
			return raw
		}
		if u.User != nil {
			u.User = url.User("redacted")
		}
		if u.RawQuery != "" {
			u.RawQuery = "[redacted]"
		}
		if u.Fragment != "" {
			u.Fragment = "redacted"
		}
		return u.String()
	})
}

func FindString(node map[string]any, keys ...string) string {
	for _, key := range keys {
		if value, found := node[key]; found {
			if text := NativeText(value); text != "" {
				return text
			}
		}
	}
	return ""
}

func FindInt(node map[string]any, keys ...string) int {
	for _, key := range keys {
		if value, found := node[key]; found {
			switch typed := value.(type) {
			case json.Number:
				if number, err := typed.Int64(); err == nil {
					return int(number)
				}
			case float64:
				return int(typed)
			case string:
				if number, err := ParseNumber(typed); err == nil {
					return number
				}
			}
		}
	}
	return 0
}

func ParseNumber(value string) (int, error) {
	trimmed := strings.TrimSpace(value)
	if number, err := strconv.Atoi(trimmed); err == nil {
		return number, nil
	}
	trimmed = strings.TrimSuffix(strings.TrimSuffix(trimmed, "集"), "全集")
	trimmed = strings.TrimSpace(trimmed)
	if number, err := strconv.Atoi(trimmed); err == nil {
		return number, nil
	}
	return 0, errNotNumber
}

var errNotNumber = &numberError{}

type numberError struct{}

func (*numberError) Error() string { return "不是数字" }

func FindMap(node map[string]any, keys ...string) map[string]any {
	for _, key := range keys {
		if value, found := node[key]; found {
			if mapped, ok := value.(map[string]any); ok {
				return mapped
			}
		}
	}
	return nil
}

func FindList(node map[string]any, keys ...string) []any {
	for _, key := range keys {
		if value, found := node[key]; found {
			if listed, ok := value.([]any); ok {
				return listed
			}
		}
	}
	return nil
}

func MapList(value any) []map[string]any {
	listed, ok := value.([]any)
	if !ok {
		return nil
	}
	rows := make([]map[string]any, 0, len(listed))
	for _, entry := range listed {
		if mapped, ok := entry.(map[string]any); ok {
			rows = append(rows, mapped)
		}
	}
	return rows
}

func StringList(value any) []string {
	listed, ok := value.([]any)
	if !ok {
		return nil
	}
	values := make([]string, 0, len(listed))
	for _, entry := range listed {
		switch typed := entry.(type) {
		case string:
			if text := strings.TrimSpace(typed); text != "" {
				values = append(values, text)
			}
		case map[string]any:
			if text := FindString(typed, "name", "title", "class_name"); text != "" {
				values = append(values, text)
			}
		}
	}
	return values
}

func CSV(values []string) string {
	return strings.Join(values, ", ")
}

func CoverAddress(value any, pageURL string) string {
	switch item := value.(type) {
	case []any:
		for _, value := range item {
			if address := CoverAddress(value, pageURL); address != "" {
				return address
			}
		}
	case map[string]any:
		for _, key := range []string{"url", "contentUrl", "thumbnailUrl"} {
			if address := CoverAddress(item[key], pageURL); address != "" {
				return address
			}
		}
	case string:
		if strings.TrimSpace(item) == "" {
			return ""
		}
		address, err := url.Parse(strings.TrimSpace(item))
		if err != nil {
			return ""
		}
		if base, err := url.Parse(pageURL); err == nil && base.IsAbs() {
			address = base.ResolveReference(address)
		}
		if ValidCoverURL(address) {
			return address.String()
		}
	}
	return ""
}

func ValidCoverURL(address *url.URL) bool {
	return address != nil && (address.Scheme == "https" || address.Scheme == "http") && address.Hostname() != "" && address.User == nil
}

func Cover(base string, node map[string]any, keys ...string) string {
	for _, key := range keys {
		if address := CoverAddress(node[key], base); address != "" {
			return address
		}
	}
	return ""
}

func ReleaseStatus(raw string, total, current int) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "over", "finished", "completed", "2", "已完结", "完结":
		return "finished"
	case "ongoing", "serializing", "1", "连载中", "更新中":
		return "ongoing"
	}
	if total > 0 && current >= total {
		return "finished"
	}
	if current > 0 {
		return "ongoing"
	}
	return ""
}

func PlainText(raw string) string {
	text := strings.TrimSpace(raw)
	if !strings.Contains(text, "<") {
		return text
	}
	text = rePlainText.ReplaceAllString(text, "")
	text = htmlEntities.Replace(text)
	return strings.Join(strings.Fields(text), " ")
}

func DramaID(source, sourceID string) string {
	return source + ":" + strings.TrimSpace(sourceID)
}

func ChapterID(source, sourceID, chapterKey string) string {
	return source + ":" + strings.TrimSpace(sourceID) + ":" + strings.TrimSpace(chapterKey)
}

func SplitDramaID(id string) (source, sourceID string, ok bool) {
	source, sourceID, ok = strings.Cut(strings.TrimSpace(id), ":")
	source = Canonical(source)
	if !ok || strings.TrimSpace(sourceID) == "" || !KnownSource(source) {
		return "", "", false
	}
	return source, strings.TrimSpace(sourceID), true
}

func SourceFromDramaID(id string) string {
	if source, _, ok := SplitDramaID(id); ok {
		return source
	}
	return ""
}

func FindBool(node map[string]any, keys ...string) bool {
	for _, key := range keys {
		if value, found := node[key]; found {
			switch typed := value.(type) {
			case bool:
				return typed
			case string:
				return typed == "true" || typed == "1"
			case float64:
				return typed != 0
			}
		}
	}
	return false
}

func MD5(value string) string {
	sum := md5.Sum([]byte(value))
	return hex.EncodeToString(sum[:])
}

func ViewsText(count int) string {
	if count <= 0 {
		return ""
	}
	if count >= 10000 {
		return strconv.FormatFloat(float64(count)/10000, 'f', 1, 64) + "万次播放"
	}
	return strconv.Itoa(count) + "次播放"
}

func IsNumericID(value string) bool {
	return reNumericID.MatchString(strings.TrimSpace(value))
}

type tokenEntry struct {
	token     string
	expiresAt time.Time
}

var tokens struct {
	sync.Mutex
	entries map[string]tokenEntry
}

func CachedToken(source string, ttl time.Duration, fetch func(context.Context) (string, error)) (string, error) {
	tokens.Lock()
	entry, found := tokens.entries[source]
	tokens.Unlock()
	if found && entry.token != "" && time.Now().Before(entry.expiresAt) {
		return entry.token, nil
	}
	token, err := fetch(context.Background())
	if err != nil {
		return "", err
	}
	tokens.Lock()
	if tokens.entries == nil {
		tokens.entries = map[string]tokenEntry{}
	}
	tokens.entries[source] = tokenEntry{token: token, expiresAt: time.Now().Add(ttl)}
	tokens.Unlock()
	return token, nil
}

func LooksLikeMedia(address string) bool {
	lower := strings.ToLower(address)
	return strings.Contains(lower, ".m3u8") || strings.Contains(lower, ".mp4") || strings.Contains(lower, ".flv")
}

func RawEpisode(n int) json.RawMessage {
	if n <= 0 {
		n = 1
	}
	return json.RawMessage(strconv.Itoa(n))
}

func SourceName(source string) string {
	if spec, found := SpecOf(source); found && spec.Name != "" {
		return spec.Name
	}
	return Canonical(source)
}

func HTTPMediaURL(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Hostname() != "" && parsed.User == nil
}
