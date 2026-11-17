package provider

import (
	"errors"
	"sync"
)

type Store interface {
	Read(key string) ([]byte, error)
	Write(key string, value []byte) error
}

var (
	storeMu sync.RWMutex
	store   Store
)

func SetStore(s Store) {
	storeMu.Lock()
	store = s
	storeMu.Unlock()
}

func ReadStore(key string) ([]byte, error) {
	storeMu.RLock()
	s := store
	storeMu.RUnlock()
	if s == nil {
		return nil, errors.New("provider: store unavailable")
	}
	return s.Read(key)
}

func WriteStore(key string, value []byte) error {
	storeMu.RLock()
	s := store
	storeMu.RUnlock()
	if s == nil {
		return errors.New("provider: store unavailable")
	}
	return s.Write(key, value)
}
