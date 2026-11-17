package core

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// fileStore 是 provider 身份/令牌的磁盘后端（provider.SetStore 注入）。
// 语义要求：同一 key 的写入不能互相截断，rename 失败也不能静默丢值——
// 丢一次 token 就等于换一个新游客身份。因此写入走 CreateTemp + 短退避重试，
// 并按进程级串行化（调用点低频，全局锁足够）。
type fileStore struct {
	dir string
}

var fileStoreWriteMu sync.Mutex

func (f fileStore) path(key string) string {
	safe := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-', r == '_':
			return r
		}
		return '_'
	}, strings.ToLower(key))
	return filepath.Join(f.dir, safe+".json")
}

func (f fileStore) Read(key string) ([]byte, error) {
	return os.ReadFile(f.path(key))
}

func (f fileStore) Write(key string, value []byte) error {
	if err := os.MkdirAll(f.dir, 0700); err != nil {
		return err
	}
	fileStoreWriteMu.Lock()
	defer fileStoreWriteMu.Unlock()

	target := f.path(key)
	file, err := os.CreateTemp(f.dir, ".store-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if _, err = file.Write(value); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	// Windows 上目标可能被并发读句柄短暂占用：短退避重试，别让身份写丢。
	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		if lastErr = os.Rename(temporary, target); lastErr == nil {
			return nil
		}
		time.Sleep(time.Duration(40*(attempt+1)) * time.Millisecond)
	}
	return lastErr
}
