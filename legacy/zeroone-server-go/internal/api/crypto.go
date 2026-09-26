package api

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"strings"
)

// serverCrypto 处理服务端仅有的两类"需要服务端密钥"的数据：
//   - email_hash：HMAC-SHA256(规范化邮箱)，用于登录查找，不可逆
//   - email_enc：AES-256-GCM 应用层加密，仅用于给用户发送告警邮件
//
// 这两者都与保险库内容无关，服务端依然无法解密任何条目。
type serverCrypto struct {
	macKey []byte
	aead   cipher.AEAD
}

func newServerCrypto(secret []byte) (*serverCrypto, error) {
	macKey := derive(secret, "zeroone/server/email-hash")
	encKey := derive(secret, "zeroone/server/email-enc")
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &serverCrypto{macKey: macKey, aead: aead}, nil
}

func derive(secret []byte, label string) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write([]byte(label))
	return m.Sum(nil)
}

func normalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

func (c *serverCrypto) emailHash(email string) []byte {
	m := hmac.New(sha256.New, c.macKey)
	m.Write([]byte(normalizeEmail(email)))
	return m.Sum(nil)
}

func (c *serverCrypto) encryptEmail(email string) ([]byte, error) {
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return c.aead.Seal(nonce, nonce, []byte(normalizeEmail(email)), []byte("email")), nil
}

func (c *serverCrypto) decryptEmail(blob []byte) (string, error) {
	n := c.aead.NonceSize()
	if len(blob) < n {
		return "", errors.New("email_enc 损坏")
	}
	pt, err := c.aead.Open(nil, blob[:n], blob[n:], []byte("email"))
	return string(pt), err
}

// fakeSalt 为不存在的邮箱返回确定性的伪造盐，防止通过登录接口枚举账号。
func (c *serverCrypto) fakeSalt(email string) []byte {
	m := hmac.New(sha256.New, c.macKey)
	m.Write([]byte("fake-salt|" + normalizeEmail(email)))
	return m.Sum(nil)[:16]
}

func sha256Sum(b []byte) []byte {
	s := sha256.Sum256(b)
	return s[:]
}
