package srp

import (
	"bytes"
	"math/big"
	"testing"
)

func TestGroupIsSafePrime(t *testing.T) {
	if N.BitLen() != 3072 {
		t.Fatalf("N 位数 = %d，期望 3072", N.BitLen())
	}
	if !N.ProbablyPrime(32) {
		t.Fatal("N 不是素数：群参数抄写有误")
	}
	q := new(big.Int).Rsh(N, 1)
	if !q.ProbablyPrime(32) {
		t.Fatal("(N-1)/2 不是素数：N 不是安全素数")
	}
}

func TestHandshake(t *testing.T) {
	salt := []byte("0123456789abcdef")
	authKey := bytes.Repeat([]byte{7}, 32)
	x := ComputeX(salt, authKey)
	v := ComputeVerifier(x)

	srv, err := NewServer(v)
	if err != nil {
		t.Fatal(err)
	}
	cli, err := NewClient()
	if err != nil {
		t.Fatal(err)
	}
	m1, err := cli.Process(x, srv.PublicB())
	if err != nil {
		t.Fatal(err)
	}
	m2, key, err := srv.Verify(cli.PublicA(), m1)
	if err != nil {
		t.Fatal(err)
	}
	if !cli.VerifyM2(m2) {
		t.Fatal("客户端未能校验 M2")
	}
	if !bytes.Equal(key, cli.Key()) {
		t.Fatal("双方会话密钥不一致")
	}
}

func TestWrongPasswordFails(t *testing.T) {
	salt := []byte("0123456789abcdef")
	v := ComputeVerifier(ComputeX(salt, []byte("right")))
	srv, _ := NewServer(v)
	cli, _ := NewClient()
	m1, _ := cli.Process(ComputeX(salt, []byte("wrong")), srv.PublicB())
	if _, _, err := srv.Verify(cli.PublicA(), m1); err != ErrBadProof {
		t.Fatalf("期望 ErrBadProof，得到 %v", err)
	}
}

func TestRejectsZeroA(t *testing.T) {
	v := ComputeVerifier(ComputeX([]byte("s"), []byte("k")))
	srv, _ := NewServer(v)
	if _, _, err := srv.Verify(Pad(big.NewInt(0)), []byte("x")); err != ErrInvalidPublic {
		t.Fatal("A=0 应被拒绝")
	}
	if _, _, err := srv.Verify(Pad(N), []byte("x")); err != ErrInvalidPublic {
		t.Fatal("A=N 应被拒绝")
	}
}
