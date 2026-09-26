package pgstore

import (
	"bytes"
	"crypto/sha256"
)

func sha256sum(b []byte) []byte {
	s := sha256.Sum256(b)
	return s[:]
}

func bytesEqual(a, b []byte) bool { return bytes.Equal(a, b) }
