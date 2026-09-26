package api

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/zeroone/server/internal/config"
	"github.com/zeroone/server/internal/ids"
	"github.com/zeroone/server/internal/memstore"
	"github.com/zeroone/server/internal/notify"
	"github.com/zeroone/server/internal/srp"
)

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	cfg := &config.Config{ServerSecret: bytes.Repeat([]byte{1}, 32), SessionTTL: 3600e9}
	s, err := New(cfg, memstore.New(), notify.LogMailer{})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return ts
}

func call(t *testing.T, ts *httptest.Server, method, path, token string, body any, out any) int {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, ts.URL+path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		_ = json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

func rnd(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

type account struct {
	email, token, deviceID, vaultID string
	x                               []byte
}

func register(t *testing.T, ts *httptest.Server, email string) *account {
	t.Helper()
	salt := rnd(16)
	authKey := rnd(32)
	x := srp.ComputeX(salt, authKey)
	vaultID := ids.UUID()
	body := map[string]any{
		"email":       email,
		"kdfParams":   json.RawMessage(`{"alg":"argon2id","m":65536,"t":3,"p":4,"salt":"AAAAAAAAAAAAAAAAAAAAAA=="}`),
		"srpSalt":     salt,
		"srpVerifier": srp.ComputeVerifier(x),
		"device":      map[string]any{"name": "My PC", "platform": "windows", "pubKey": rnd(32)},
		"vault":       map[string]any{"id": vaultID, "nameEnc": rnd(40), "vkWrap": rnd(40)},
		"recovery":    map[string]any{"vkWrapEnc": rnd(40), "authHash": rnd(32)},
	}
	var out sessionOut
	if code := call(t, ts, "POST", "/v1/auth/register", "", body, &out); code != http.StatusCreated {
		t.Fatalf("register = %d", code)
	}
	if !out.DeviceApproved {
		t.Fatal("首个设备应自动批准")
	}
	return &account{email: email, token: out.Token, deviceID: out.DeviceID, vaultID: vaultID, x: x}
}

func login(t *testing.T, ts *httptest.Server, email string, x []byte, deviceID string) (int, *loginFinishResp) {
	t.Helper()
	var start loginStartResp
	if code := call(t, ts, "POST", "/v1/auth/login/start", "", map[string]string{"email": email}, &start); code != 200 {
		t.Fatalf("login/start = %d", code)
	}
	cli, _ := srp.NewClient()
	m1, err := cli.Process(x, start.B)
	if err != nil {
		t.Fatal(err)
	}
	var fin loginFinishResp
	code := call(t, ts, "POST", "/v1/auth/login/finish", "", map[string]any{
		"handshakeId": start.HandshakeID, "A": cli.PublicA(), "M1": m1,
		"device": map[string]any{"id": deviceID, "name": "Laptop", "platform": "macos", "pubKey": rnd(32)},
	}, &fin)
	if code == 200 && !cli.VerifyM2(fin.M2) {
		t.Fatal("M2 校验失败")
	}
	return code, &fin
}

func TestAuthFlow(t *testing.T) {
	ts := newTestServer(t)
	acct := register(t, ts, "Alice@Example.com")

	if code := call(t, ts, "POST", "/v1/auth/register", "", map[string]any{"email": "alice@example.com"}, nil); code != http.StatusBadRequest {
		t.Fatalf("不完整注册应返回 400，得到 %d", code)
	}

	// 已知设备登录：直接放行
	code, fin := login(t, ts, "alice@example.com", acct.x, acct.deviceID)
	if code != 200 || !fin.DeviceApproved {
		t.Fatalf("已知设备登录失败: %d", code)
	}

	// 错误凭据
	if code, _ := login(t, ts, "alice@example.com", rnd(32), ""); code != http.StatusUnauthorized {
		t.Fatalf("错误凭据应返回 401，得到 %d", code)
	}
	// 不存在的账号：start 形态一致，finish 失败
	if code, _ := login(t, ts, "nobody@example.com", rnd(32), ""); code != http.StatusUnauthorized {
		t.Fatalf("不存在账号应返回 401，得到 %d", code)
	}

	// 新设备：待批准，不能同步
	code, fin = login(t, ts, "alice@example.com", acct.x, "")
	if code != 200 || fin.DeviceApproved {
		t.Fatal("新设备应处于待批准状态")
	}
	if code := call(t, ts, "GET", "/v1/sync/pull", fin.Token, nil, nil); code != http.StatusForbidden {
		t.Fatalf("待批准设备不应能同步，得到 %d", code)
	}
	// 旧设备批准新设备
	if code := call(t, ts, "POST", "/v1/devices/"+fin.DeviceID+"/approve", acct.token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("approve = %d", code)
	}
	if code := call(t, ts, "GET", "/v1/sync/pull", fin.Token, nil, nil); code != 200 {
		t.Fatalf("批准后应能同步，得到 %d", code)
	}

	var devs struct{ Devices []deviceOut }
	call(t, ts, "GET", "/v1/devices", acct.token, nil, &devs)
	if len(devs.Devices) != 2 {
		t.Fatalf("设备数 = %d", len(devs.Devices))
	}

	// 移除设备后其会话失效
	if code := call(t, ts, "DELETE", "/v1/devices/"+fin.DeviceID, acct.token, nil, nil); code != http.StatusNoContent {
		t.Fatalf("revoke = %d", code)
	}
	if code := call(t, ts, "GET", "/v1/account", fin.Token, nil, nil); code != http.StatusUnauthorized {
		t.Fatalf("已移除设备应被拒绝，得到 %d", code)
	}

	// 登出
	call(t, ts, "POST", "/v1/auth/logout", acct.token, nil, nil)
	if code := call(t, ts, "GET", "/v1/account", acct.token, nil, nil); code != http.StatusUnauthorized {
		t.Fatal("登出后会话应失效")
	}
}

func TestSyncOptimisticLock(t *testing.T) {
	ts := newTestServer(t)
	acct := register(t, ts, "bob@example.com")
	item := ids.UUID()
	push := func(base, rev int64, blob []byte) pushResultOut {
		var out struct{ Results []pushResultOut }
		code := call(t, ts, "POST", "/v1/sync/push", acct.token, map[string]any{"changes": []map[string]any{{
			"itemId": item, "vaultId": acct.vaultID, "kind": "login", "blob": blob, "baseRevision": base, "revision": rev,
		}}}, &out)
		if code != 200 {
			t.Fatalf("push = %d", code)
		}
		return out.Results[0]
	}

	b1 := rnd(272)
	if r := push(0, 1, b1); r.Status != "applied" {
		t.Fatalf("首次写入: %+v", r)
	}
	if r := push(0, 1, b1); r.Status != "duplicate" {
		t.Fatalf("重放应幂等: %+v", r)
	}
	if r := push(0, 1, rnd(272)); r.Status != "conflict" || r.ServerRevision != 1 {
		t.Fatalf("并发写应冲突: %+v", r)
	}
	if r := push(1, 2, rnd(272)); r.Status != "applied" {
		t.Fatalf("基于最新版本写入: %+v", r)
	}

	var pulled struct {
		Changes []changeOut
		NextSeq int64
		HasMore bool
	}
	call(t, ts, "GET", "/v1/sync/pull?since=0", acct.token, nil, &pulled)
	if len(pulled.Changes) != 2 || pulled.NextSeq != 2 || pulled.Changes[1].Item.Revision != 2 {
		t.Fatalf("pull 结果异常: %+v", pulled)
	}
	call(t, ts, "GET", fmt.Sprintf("/v1/sync/pull?since=%d", pulled.NextSeq), acct.token, nil, &pulled)
	if len(pulled.Changes) != 0 {
		t.Fatal("游标之后不应有新变更")
	}

	// 其他用户不能写入别人的保险库
	eve := register(t, ts, "eve@example.com")
	var out struct{ Results []pushResultOut }
	call(t, ts, "POST", "/v1/sync/push", eve.token, map[string]any{"changes": []map[string]any{{
		"itemId": ids.UUID(), "vaultId": acct.vaultID, "kind": "login", "blob": rnd(10), "baseRevision": 0, "revision": 1,
	}}}, &out)
	if out.Results[0].Status != "forbidden" {
		t.Fatalf("跨用户写入应被拒绝: %+v", out.Results[0])
	}
}

func TestRateLimit(t *testing.T) {
	ts := newTestServer(t)
	limited := false
	for i := 0; i < 30; i++ {
		if call(t, ts, "POST", "/v1/auth/login/start", "", map[string]string{"email": "x@y.z"}, nil) == http.StatusTooManyRequests {
			limited = true
			break
		}
	}
	if !limited {
		t.Fatal("认证接口应被限流")
	}
}
