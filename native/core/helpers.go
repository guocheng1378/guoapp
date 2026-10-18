package core

import (
	"duanjuapp/native/provider"
	"regexp"
)

var (
	badNameChars = regexp.MustCompile(`[\\/\?%\*:|"<>\x00-\x1f]+`)
	spaceChars   = regexp.MustCompile(`\s+`)
)

type redactedError = provider.RedactedError

func publicError(err error) error {
	return provider.PublicError(err)
}

func redactErrorString(s string) string {
	return provider.RedactErrorString(s)
}

func truncate(s string, n int) string {
	return provider.Truncate(s, n)
}
