package yunzhui

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
)

const (
	signKey = "zD9[bM4~sF4~uY2)"
	aesKey  = "aZ9$kU5%qI7=yC2=zH2#gM0@pX7^wF3a"
	aesIV   = "hY2&tN3]kF7,dL7="
)

func sign(device, ts string) string {
	sum := md5.Sum([]byte(signKey + device + ts))
	return strings.ToUpper(hex.EncodeToString(sum[:]))
}

func decrypt(body []byte) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(body)))
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || len(raw)%aes.BlockSize != 0 {
		return nil, errors.New("yunzhui: bad cipher length")
	}
	block, err := aes.NewCipher([]byte(aesKey))
	if err != nil {
		return nil, err
	}
	out := make([]byte, len(raw))
	cipher.NewCBCDecrypter(block, []byte(aesIV)).CryptBlocks(out, raw)
	pad := int(out[len(out)-1])
	if pad <= 0 || pad > aes.BlockSize || pad > len(out) {
		return nil, errors.New("yunzhui: bad padding")
	}
	return bytes.TrimSuffix(out, bytes.Repeat([]byte{byte(pad)}, pad)), nil
}
