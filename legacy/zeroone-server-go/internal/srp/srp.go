// Package srp 实现 SRP-6a（RFC 5054 3072-bit 群，H = SHA-256）。
//
// 服务端只保存 verifier v = g^x mod N，x 由客户端从 AuthKey 派生，
// 因此数据库被拖库也拿不到可离线爆破主密码的哈希（计划书 S-01）。
//
// 证明消息采用：
//
//	u  = H(PAD(A) | PAD(B))
//	K  = H(PAD(S))
//	M1 = H(PAD(A) | PAD(B) | K)
//	M2 = H(PAD(A) | M1 | K)
package srp

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"math/big"
	"strings"
)

const nHex = `
FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1 29024E08
8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD EF9519B3 CD3A431B
302B0A6D F25F1437 4FE1356D 6D51C245 E485B576 625E7EC6 F44C42E9
A637ED6B 0BFF5CB6 F406B7ED EE386BFB 5A899FA5 AE9F2411 7C4B1FE6
49286651 ECE45B3D C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8
FD24CF5F 83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B E39E772C
180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9 DE2BCBF6 95581718
3995497C EA956AE5 15D22618 98FA0510 15728E5A 8AAAC42D AD33170D
04507A33 A85521AB DF1CBA64 ECFB8504 58DBEF0A 8AEA7157 5D060C7D
B3970F85 A6E1E4C7 ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226
1AD2EE6B F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31 43DB5BFC
E0FD108E 4B82D120 A93AD2CA FFFFFFFF FFFFFFFF`

var (
	N    *big.Int
	g    = big.NewInt(5)
	k    *big.Int
	nLen int
)

var (
	ErrInvalidPublic = errors.New("srp: 非法公钥")
	ErrBadProof      = errors.New("srp: 证明校验失败")
)

func init() {
	clean := strings.Map(func(r rune) rune {
		if r == ' ' || r == '\n' || r == '\t' || r == '\r' {
			return -1
		}
		return r
	}, nHex)
	var ok bool
	N, ok = new(big.Int).SetString(clean, 16)
	if !ok {
		panic("srp: 群参数解析失败")
	}
	nLen = (N.BitLen() + 7) / 8
	k = new(big.Int).SetBytes(H(Pad(N), Pad(g)))
}

// H 计算各段拼接后的 SHA-256。
func H(parts ...[]byte) []byte {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

// Pad 把整数左填充到 N 的字节长度。
func Pad(x *big.Int) []byte {
	b := x.Bytes()
	if len(b) >= nLen {
		return b
	}
	out := make([]byte, nLen)
	copy(out[nLen-len(b):], b)
	return out
}

// GroupSize 返回公钥字节长度。
func GroupSize() int { return nLen }

func randomExponent() (*big.Int, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return nil, err
	}
	return new(big.Int).SetBytes(buf), nil
}

// ComputeX 由盐与 AuthKey 计算私有值 x（客户端逻辑，服务端仅用于测试）。
func ComputeX(salt, authKey []byte) []byte { return H(salt, authKey) }

// ComputeVerifier 计算 v = g^x mod N。
func ComputeVerifier(x []byte) []byte {
	return Pad(new(big.Int).Exp(g, new(big.Int).SetBytes(x), N))
}

// Server 是一次登录握手的服务端状态。
type Server struct {
	v, b, B *big.Int
}

// NewServer 用存储的 verifier 创建握手，生成 B = k·v + g^b。
func NewServer(verifier []byte) (*Server, error) {
	v := new(big.Int).SetBytes(verifier)
	if v.Sign() == 0 || v.Cmp(N) >= 0 {
		return nil, ErrInvalidPublic
	}
	for {
		b, err := randomExponent()
		if err != nil {
			return nil, err
		}
		B := new(big.Int).Mul(k, v)
		B.Add(B, new(big.Int).Exp(g, b, N))
		B.Mod(B, N)
		if B.Sign() != 0 {
			return &Server{v: v, b: b, B: B}, nil
		}
	}
}

// PublicB 返回 PAD(B)。
func (s *Server) PublicB() []byte { return Pad(s.B) }

// Verify 校验客户端 A 与 M1，成功返回 M2 与会话密钥 K。
func (s *Server) Verify(aBytes, m1 []byte) (m2, key []byte, err error) {
	A := new(big.Int).SetBytes(aBytes)
	if new(big.Int).Mod(A, N).Sign() == 0 {
		return nil, nil, ErrInvalidPublic
	}
	u := new(big.Int).SetBytes(H(Pad(A), Pad(s.B)))
	if u.Sign() == 0 {
		return nil, nil, ErrInvalidPublic
	}
	S := new(big.Int).Exp(s.v, u, N)
	S.Mul(S, A)
	S.Mod(S, N)
	S.Exp(S, s.b, N)
	key = H(Pad(S))
	expected := H(Pad(A), Pad(s.B), key)
	if subtle.ConstantTimeCompare(expected, m1) != 1 {
		return nil, nil, ErrBadProof
	}
	return H(Pad(A), m1, key), key, nil
}

// Client 是客户端握手状态。生产客户端在 Rust 内核中实现，这里用于测试与联调。
type Client struct {
	a, A *big.Int
	m1   []byte
	key  []byte
}

func NewClient() (*Client, error) {
	a, err := randomExponent()
	if err != nil {
		return nil, err
	}
	return &Client{a: a, A: new(big.Int).Exp(g, a, N)}, nil
}

func (c *Client) PublicA() []byte { return Pad(c.A) }

// Process 根据服务端 B 与私有值 x 计算 M1。
func (c *Client) Process(x, bBytes []byte) ([]byte, error) {
	B := new(big.Int).SetBytes(bBytes)
	if new(big.Int).Mod(B, N).Sign() == 0 {
		return nil, ErrInvalidPublic
	}
	u := new(big.Int).SetBytes(H(Pad(c.A), Pad(B)))
	if u.Sign() == 0 {
		return nil, ErrInvalidPublic
	}
	xi := new(big.Int).SetBytes(x)
	// S = (B - k·g^x)^(a + u·x) mod N
	base := new(big.Int).Exp(g, xi, N)
	base.Mul(base, k)
	base.Sub(B, base)
	base.Mod(base, N)
	exp := new(big.Int).Mul(u, xi)
	exp.Add(exp, c.a)
	S := new(big.Int).Exp(base, exp, N)
	c.key = H(Pad(S))
	c.m1 = H(Pad(c.A), Pad(B), c.key)
	return c.m1, nil
}

// VerifyM2 校验服务端证明，防止中间人伪装服务端。
func (c *Client) VerifyM2(m2 []byte) bool {
	return subtle.ConstantTimeCompare(H(Pad(c.A), c.m1, c.key), m2) == 1
}

func (c *Client) Key() []byte { return c.key }
