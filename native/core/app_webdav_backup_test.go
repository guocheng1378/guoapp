package core

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// 内存 WebDAV 服务器：覆盖 PUT/GET/MKCOL/PROPFIND 与鉴权。
type fakeWebDAV struct {
	mu    sync.Mutex
	files map[string][]byte
	dirs  map[string]bool
	// putFailRemaining > 0 时，接下来 N 次 PUT 返回 409（模拟父目录不存在）
	putFailRemaining int
	// getFileStatus 覆盖 GET 文件的状态码（0 = 正常逻辑）
	getFileStatus int
	propStatus    int // PROPFIND 文件状态码覆盖（0 = 正常逻辑）
}

func newFakeWebDAV() *fakeWebDAV {
	return &fakeWebDAV{files: map[string][]byte{}, dirs: map[string]bool{}}
}

func (f *fakeWebDAV) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	user, pass, ok := r.BasicAuth()
	if !ok || user != "user" || pass != "pass" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	switch r.Method {
	case "PUT":
		body, _ := io.ReadAll(r.Body)
		if f.putFailRemaining > 0 {
			f.putFailRemaining--
			w.WriteHeader(http.StatusConflict)
			return
		}
		f.files[r.URL.Path] = body
		w.WriteHeader(http.StatusCreated)
	case "GET":
		if f.getFileStatus != 0 {
			w.WriteHeader(f.getFileStatus)
			return
		}
		body, ok := f.files[r.URL.Path]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Write(body)
	case "MKCOL":
		f.dirs[r.URL.Path] = true
		w.WriteHeader(http.StatusCreated)
	case "PROPFIND":
		if f.propStatus != 0 {
			w.WriteHeader(f.propStatus)
			return
		}
		if body, ok := f.files[r.URL.Path]; ok {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusMultiStatus)
			w.Write([]byte(`<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>` +
				r.URL.Path + `</d:href><d:propstat><d:prop><d:getcontentlength>` +
				strconv.Itoa(len(body)) + `</d:getcontentlength><d:getlastmodified>Thu, 30 Oct 2026 12:00:00 GMT</d:getlastmodified>` +
				`</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>`))
			return
		}
		if f.dirs[strings.TrimSuffix(r.URL.Path, "/")] {
			w.WriteHeader(http.StatusMultiStatus)
			w.Write([]byte(`<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>`))
			return
		}
		w.WriteHeader(http.StatusNotFound)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func webdavCall(t *testing.T, command string, input nativeWebDAVInput) (any, error) {
	t.Helper()
	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatalf("marshal input: %v", err)
	}
	return nativeWebDAV(context.Background(), command, raw)
}

func TestWebDAVUploadDownloadRoundTrip(t *testing.T) {
	server := httptest.NewServer(newFakeWebDAV())
	defer server.Close()
	input := nativeWebDAVInput{
		URL:            server.URL + "/dav/duanju_backup/backup.json",
		Username:       "user",
		Password:       "pass",
		BackupPassword: "备份密码123",
		Data:           `{"schema":1,"app":"zhenguojian","profiles":[]}`,
	}
	up, err := webdavCall(t, "upload", input)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	if !up.(webdavUploadResult).OK {
		t.Fatal("upload not ok")
	}
	down, err := webdavCall(t, "download", input)
	if err != nil {
		t.Fatalf("download: %v", err)
	}
	result := down.(webdavDownloadResult)
	if !result.Exists || result.Data != input.Data {
		t.Fatalf("round trip mismatch: %+v", result)
	}
}

func TestWebDAVUploadAutoMkdir(t *testing.T) {
	fake := newFakeWebDAV()
	fake.putFailRemaining = 1
	server := httptest.NewServer(fake)
	defer server.Close()
	input := nativeWebDAVInput{
		URL:            server.URL + "/dav/deep/nest/backup.json",
		Username:       "user",
		Password:       "pass",
		BackupPassword: "pw",
		Data:           `{"schema":1}`,
	}
	if _, err := webdavCall(t, "upload", input); err != nil {
		t.Fatalf("upload with auto mkdir: %v", err)
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	if !fake.dirs["/dav"] || !fake.dirs["/dav/deep"] || !fake.dirs["/dav/deep/nest"] {
		t.Fatalf("expected all parent dirs created, dirs=%v", fake.dirs)
	}
}

func TestWebDAVTestCommand(t *testing.T) {
	fake := newFakeWebDAV()
	server := httptest.NewServer(fake)
	defer server.Close()
	input := nativeWebDAVInput{
		URL:      server.URL + "/dav/backup.json",
		Username: "user",
		Password: "pass",
	}

	// 服务器空：可达但无备份
	res, err := webdavCall(t, "test", input)
	if err != nil {
		t.Fatalf("test empty: %v", err)
	}
	if r := res.(webdavTestResult); !r.Reachable || r.Exists {
		t.Fatalf("expected reachable without backup: %+v", r)
	}

	// 有备份：exists + size + modified
	fake.mu.Lock()
	fake.files["/dav/backup.json"] = []byte("0123456789")
	fake.mu.Unlock()
	res, err = webdavCall(t, "test", input)
	if err != nil {
		t.Fatalf("test with file: %v", err)
	}
	r := res.(webdavTestResult)
	if !r.Reachable || !r.Exists || r.Size != 10 || r.Modified == "" {
		t.Fatalf("expected exists with size/modified: %+v", r)
	}

	// 鉴权失败
	input.Password = "wrong"
	if _, err := webdavCall(t, "test", input); err == nil || !strings.Contains(err.Error(), "401") {
		t.Fatalf("expected 401 error, got %v", err)
	}
}

func TestWebDAVDownloadMissing(t *testing.T) {
	server := httptest.NewServer(newFakeWebDAV())
	defer server.Close()
	input := nativeWebDAVInput{
		URL:            server.URL + "/dav/none.json",
		Username:       "user",
		Password:       "pass",
		BackupPassword: "pw",
	}
	res, err := webdavCall(t, "download", input)
	if err != nil {
		t.Fatalf("download missing should not error: %v", err)
	}
	if res.(webdavDownloadResult).Exists {
		t.Fatal("expected exists=false")
	}
}

func TestWebDAVWrongPasswordAndTamper(t *testing.T) {
	server := httptest.NewServer(newFakeWebDAV())
	defer server.Close()
	input := nativeWebDAVInput{
		URL:            server.URL + "/dav/backup.json",
		Username:       "user",
		Password:       "pass",
		BackupPassword: "right-pw",
		Data:           `{"schema":1}`,
	}
	if _, err := webdavCall(t, "upload", input); err != nil {
		t.Fatalf("upload: %v", err)
	}

	// 错误密码
	wrong := input
	wrong.BackupPassword = "wrong-pw"
	if _, err := webdavCall(t, "download", wrong); err == nil || !strings.Contains(err.Error(), "备份密码不正确") {
		t.Fatalf("expected wrong password error, got %v", err)
	}

	// 篡改密文：GCM 校验必须失败
	fake := server.Config.Handler.(*fakeWebDAV)
	fake.mu.Lock()
	envelope := fake.files["/dav/backup.json"]
	tampered := append([]byte{}, envelope...)
	tampered[len(tampered)-1] ^= 0xFF
	fake.files["/dav/backup.json"] = tampered
	fake.mu.Unlock()
	if _, err := webdavCall(t, "download", input); err == nil || !strings.Contains(err.Error(), "损坏") {
		t.Fatalf("expected tamper error, got %v", err)
	}

	// 非本应用文件（魔数不匹配，长度足够走过头部校验）
	fake.mu.Lock()
	fake.files["/dav/backup.json"] = []byte("plain text content that is definitely not a backup envelope")
	fake.mu.Unlock()
	if _, err := webdavCall(t, "download", input); err == nil || !strings.Contains(err.Error(), "不是本应用") {
		t.Fatalf("expected magic mismatch error, got %v", err)
	}
}

func TestWebDAVEnvelopeBinding(t *testing.T) {
	plain := []byte(`{"schema":1}`)
	envelope, err := webdavSeal(plain, "pw")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	got, err := webdavOpen(envelope, "pw")
	if err != nil || string(got) != string(plain) {
		t.Fatalf("round trip: %v", err)
	}
	// AAD 绑定：改版本字节必须解密失败
	envelope[4] = 2
	if _, err := webdavOpen(envelope, "pw"); err == nil {
		t.Fatal("expected version byte to be authenticated")
	}
}

func TestWebDAVInputValidation(t *testing.T) {
	ctx := context.Background()
	if _, err := nativeWebDAV(ctx, "test", json.RawMessage(`{"url":""}`)); err == nil {
		t.Fatal("expected empty url error")
	}
	if _, err := nativeWebDAV(ctx, "test", json.RawMessage(`{"url":"ftp://x"}`)); err == nil {
		t.Fatal("expected scheme error")
	}
	if _, err := nativeWebDAV(ctx, "noop", json.RawMessage(`{"url":"https://x/f.json"}`)); err == nil {
		t.Fatal("expected unknown command error")
	}
	server := httptest.NewServer(newFakeWebDAV())
	defer server.Close()
	if _, err := nativeWebDAV(ctx, "upload", json.RawMessage(`{"url":"`+server.URL+`/dav/f.json"}`)); err == nil {
		t.Fatal("expected missing backup password error")
	}
	if _, err := nativeWebDAV(ctx, "test", json.RawMessage(`not-json`)); err == nil {
		t.Fatal("expected invalid payload error")
	}
}
