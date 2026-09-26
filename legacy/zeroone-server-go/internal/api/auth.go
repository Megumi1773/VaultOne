package api

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"time"

	"github.com/zeroone/server/internal/ids"
	"github.com/zeroone/server/internal/srp"
	"github.com/zeroone/server/internal/store"
)

var validPlatforms = map[string]bool{"windows": true, "macos": true, "ios": true, "android": true, "extension": true, "linux": true}

type deviceIn struct {
	ID       string `json:"id,omitempty"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
	PubKey   []byte `json:"pubKey"`
}

func (d *deviceIn) validate() error {
	if d.Name == "" || len(d.Name) > 64 {
		return errors.New("设备名需为 1-64 字符")
	}
	if !validPlatforms[d.Platform] {
		return errors.New("未知平台")
	}
	if len(d.PubKey) != 32 {
		return errors.New("设备公钥需为 32 字节 Ed25519 公钥")
	}
	return nil
}

func validKDF(raw json.RawMessage) error {
	var k struct {
		Alg  string `json:"alg"`
		M    int    `json:"m"`
		T    int    `json:"t"`
		P    int    `json:"p"`
		Salt string `json:"salt"`
	}
	if err := json.Unmarshal(raw, &k); err != nil {
		return errors.New("kdfParams 格式错误")
	}
	if k.Alg != "argon2id" || k.M < 19*1024 || k.T < 1 || k.P < 1 || len(k.Salt) < 16 {
		return errors.New("kdfParams 低于安全下限")
	}
	return nil
}

func validSRP(salt, verifier []byte) error {
	if len(salt) < 16 || len(salt) > 64 {
		return errors.New("srpSalt 长度不合法")
	}
	if len(verifier) == 0 || len(verifier) > srp.GroupSize() {
		return errors.New("srpVerifier 长度不合法")
	}
	return nil
}

type sessionOut struct {
	Token          string    `json:"token"`
	ExpiresAt      time.Time `json:"expiresAt"`
	UserID         string    `json:"userId"`
	DeviceID       string    `json:"deviceId"`
	DeviceApproved bool      `json:"deviceApproved"`
}

func (s *Server) issueSession(r *http.Request, userID string, dev *store.Device) (*sessionOut, error) {
	token := ids.Token(32)
	sess := &store.Session{
		ID:        ids.UUID(),
		UserID:    userID,
		DeviceID:  dev.ID,
		TokenHash: sha256Sum([]byte(token)),
		ExpiresAt: time.Now().UTC().Add(s.cfg.SessionTTL),
		IPHash:    s.crypto.emailHash("ip|" + clientIP(r))[:16],
	}
	if err := s.store.CreateSession(r.Context(), sess); err != nil {
		return nil, err
	}
	return &sessionOut{Token: token, ExpiresAt: sess.ExpiresAt, UserID: userID, DeviceID: dev.ID, DeviceApproved: dev.Approved()}, nil
}

// ---------- 注册 ----------

type registerReq struct {
	Email       string          `json:"email"`
	KDFParams   json.RawMessage `json:"kdfParams"`
	SRPSalt     []byte          `json:"srpSalt"`
	SRPVerifier []byte          `json:"srpVerifier"`
	Device      deviceIn        `json:"device"`
	Vault       struct {
		ID      string `json:"id"`
		NameEnc []byte `json:"nameEnc"`
		VKWrap  []byte `json:"vkWrap"`
	} `json:"vault"`
	Recovery struct {
		VKWrapEnc []byte `json:"vkWrapEnc"`
		AuthHash  []byte `json:"authHash"`
	} `json:"recovery"`
}

func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	email := normalizeEmail(req.Email)
	var verr error
	switch {
	case len(email) < 3 || len(email) > 254 || !containsAt(email):
		verr = errors.New("邮箱格式不正确")
	case !ids.ValidUUID(req.Vault.ID):
		verr = errors.New("vault.id 需为 UUID")
	case len(req.Vault.VKWrap) == 0 || len(req.Vault.NameEnc) == 0:
		verr = errors.New("缺少 Vault Key 封装")
	case len(req.Recovery.VKWrapEnc) == 0 || len(req.Recovery.AuthHash) != 32:
		verr = errors.New("缺少恢复套件")
	}
	if verr == nil {
		verr = validKDF(req.KDFParams)
	}
	if verr == nil {
		verr = validSRP(req.SRPSalt, req.SRPVerifier)
	}
	if verr == nil {
		verr = req.Device.validate()
	}
	if verr != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", verr.Error())
		return
	}

	emailEnc, err := s.crypto.encryptEmail(email)
	if err != nil {
		s.internal(w, err)
		return
	}
	userID := ids.UUID()
	now := time.Now().UTC()
	dev := store.Device{
		ID: ids.UUID(), UserID: userID, Name: req.Device.Name, Platform: req.Device.Platform,
		PubKey: req.Device.PubKey, ApprovedAt: &now,
	}
	reg := &store.Registration{
		User: store.User{
			ID: userID, EmailEnc: emailEnc, EmailHash: s.crypto.emailHash(email),
			KDFParams: req.KDFParams, SRPSalt: req.SRPSalt, SRPVerifier: req.SRPVerifier, Status: "active",
		},
		Device:   dev,
		Vault:    store.Vault{ID: req.Vault.ID, OwnerID: userID, Kind: "personal", NameEnc: req.Vault.NameEnc, VKWrap: req.Vault.VKWrap, VKGen: 1},
		Recovery: store.RecoveryKit{UserID: userID, VKWrapEnc: req.Recovery.VKWrapEnc, AuthHash: req.Recovery.AuthHash},
	}
	if err := s.store.CreateAccount(r.Context(), reg); err != nil {
		if errors.Is(err, store.ErrExists) {
			writeError(w, http.StatusConflict, "exists", "该邮箱已注册")
			return
		}
		s.internal(w, err)
		return
	}
	out, err := s.issueSession(r, userID, &dev)
	if err != nil {
		s.internal(w, err)
		return
	}
	s.audit(r.Context(), r, userID, &dev.ID, "device_added")
	writeJSON(w, http.StatusCreated, out)
}

func containsAt(s string) bool {
	for i := 1; i < len(s)-1; i++ {
		if s[i] == '@' {
			return true
		}
	}
	return false
}

// ---------- 登录（SRP-6a 两步握手） ----------

type loginStartReq struct {
	Email string `json:"email"`
}

type loginStartResp struct {
	HandshakeID string          `json:"handshakeId"`
	KDFParams   json.RawMessage `json:"kdfParams"`
	SRPSalt     []byte          `json:"srpSalt"`
	B           []byte          `json:"B"`
}

func (s *Server) handleLoginStart(w http.ResponseWriter, r *http.Request) {
	var req loginStartReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	user, err := s.store.UserByEmailHash(r.Context(), s.crypto.emailHash(req.Email))
	var verifier, salt []byte
	var kdf json.RawMessage
	userID := ""
	switch {
	case err == nil && user.Status == "active":
		verifier, salt, kdf, userID = user.SRPVerifier, user.SRPSalt, user.KDFParams, user.ID
	case err == nil || errors.Is(err, store.ErrNotFound):
		// 账号不存在时返回伪造但稳定的参数，响应形态与真实账号一致，防止枚举
		salt = s.crypto.fakeSalt(req.Email)
		kdf = json.RawMessage(fmt.Sprintf(`{"alg":"argon2id","m":65536,"t":3,"p":4,"salt":%q}`, base64.StdEncoding.EncodeToString(s.crypto.fakeSalt("kdf|"+req.Email))))
		fake, _ := rand.Int(rand.Reader, srp.N)
		verifier = srp.Pad(fake)
	default:
		s.internal(w, err)
		return
	}
	hs, err := srp.NewServer(verifier)
	if err != nil {
		s.internal(w, err)
		return
	}
	id := ids.Token(16)
	s.handshakes.Store(id, &handshake{userID: userID, srv: hs, expires: time.Now().Add(2 * time.Minute)})
	writeJSON(w, http.StatusOK, loginStartResp{HandshakeID: id, KDFParams: kdf, SRPSalt: salt, B: hs.PublicB()})
}

type loginFinishReq struct {
	HandshakeID string   `json:"handshakeId"`
	A           []byte   `json:"A"`
	M1          []byte   `json:"M1"`
	Device      deviceIn `json:"device"`
}

type loginFinishResp struct {
	M2 []byte `json:"M2"`
	sessionOut
}

func (s *Server) handleLoginFinish(w http.ResponseWriter, r *http.Request) {
	var req loginFinishReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	v, ok := s.handshakes.LoadAndDelete(req.HandshakeID)
	if !ok || time.Now().After(v.(*handshake).expires) {
		writeError(w, http.StatusUnauthorized, "handshake_expired", "登录握手已过期，请重试")
		return
	}
	hs := v.(*handshake)
	m2, _, err := hs.srv.Verify(req.A, req.M1)
	if err != nil || hs.userID == "" {
		if hs.userID != "" {
			s.audit(r.Context(), r, hs.userID, nil, "login_fail")
		}
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "主密码或 Secret Key 不正确")
		return
	}
	user, err := s.store.UserByID(r.Context(), hs.userID)
	if err != nil {
		s.internal(w, err)
		return
	}

	dev, err := s.resolveDevice(r, user, &req.Device)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
		return
	}
	out, err := s.issueSession(r, user.ID, dev)
	if err != nil {
		s.internal(w, err)
		return
	}
	s.audit(r.Context(), r, user.ID, &dev.ID, "login_ok")
	writeJSON(w, http.StatusOK, loginFinishResp{M2: m2, sessionOut: *out})
}

// resolveDevice 复用已知设备，或登记为待批准的新设备并发送邮箱验证码（计划书 F-01）。
func (s *Server) resolveDevice(r *http.Request, user *store.User, in *deviceIn) (*store.Device, error) {
	if in.ID != "" {
		if d, err := s.store.GetDevice(r.Context(), user.ID, in.ID); err == nil && d.RevokedAt == nil {
			return d, nil
		}
	}
	if err := in.validate(); err != nil {
		return nil, err
	}
	d := &store.Device{ID: ids.UUID(), UserID: user.ID, Name: in.Name, Platform: in.Platform, PubKey: in.PubKey}
	if err := s.store.CreateDevice(r.Context(), d); err != nil {
		return nil, err
	}
	code := otpCode()
	s.otps.Store(d.ID, &deviceOTP{codeHash: sha256Sum([]byte(code)), expires: time.Now().Add(15 * time.Minute)})
	s.audit(r.Context(), r, user.ID, &d.ID, "device_added")
	s.notifyUser(r.Context(), user, "ZeroOne：新设备登录验证",
		fmt.Sprintf("设备「%s」(%s) 正在登录你的账户。验证码：%s（15 分钟内有效）。如非本人操作，请立即修改主密码。", d.Name, d.Platform, code))
	return d, nil
}

func otpCode() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1_000_000))
	return fmt.Sprintf("%06d", n.Int64())
}

type verifyReq struct {
	Code string `json:"code"`
}

func (s *Server) handleDeviceVerifyEmail(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	var req verifyReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	if a.device.Approved() {
		writeJSON(w, http.StatusOK, map[string]bool{"approved": true})
		return
	}
	v, ok := s.otps.Load(a.device.ID)
	if !ok {
		writeError(w, http.StatusBadRequest, "otp_expired", "验证码已过期，请重新登录")
		return
	}
	otp := v.(*deviceOTP)
	otp.attempts++
	if otp.attempts > 5 {
		s.otps.Delete(a.device.ID)
		writeError(w, http.StatusTooManyRequests, "otp_locked", "尝试次数过多，请重新登录")
		return
	}
	if subtle.ConstantTimeCompare(otp.codeHash, sha256Sum([]byte(req.Code))) != 1 {
		writeError(w, http.StatusBadRequest, "otp_invalid", "验证码不正确")
		return
	}
	s.otps.Delete(a.device.ID)
	if err := s.store.ApproveDevice(r.Context(), a.session.UserID, a.device.ID, ""); err != nil {
		s.internal(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"approved": true})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	if err := s.store.RevokeSession(r.Context(), a.session.ID); err != nil {
		s.internal(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- 账户 ----------

type vaultOut struct {
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	NameEnc []byte `json:"nameEnc"`
	VKWrap  []byte `json:"vkWrap"`
	VKGen   int    `json:"vkGen"`
}

func (s *Server) handleAccount(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	user, err := s.store.UserByID(r.Context(), a.session.UserID)
	if err != nil {
		s.internal(w, err)
		return
	}
	vaults, err := s.store.VaultsByOwner(r.Context(), user.ID)
	if err != nil {
		s.internal(w, err)
		return
	}
	out := make([]vaultOut, 0, len(vaults))
	for _, v := range vaults {
		out = append(out, vaultOut{ID: v.ID, Kind: v.Kind, NameEnc: v.NameEnc, VKWrap: v.VKWrap, VKGen: v.VKGen})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"userId": user.ID, "deviceId": a.device.ID, "kdfParams": user.KDFParams, "vaults": out,
	})
}

type credentialsReq struct {
	KDFParams   json.RawMessage   `json:"kdfParams"`
	SRPSalt     []byte            `json:"srpSalt"`
	SRPVerifier []byte            `json:"srpVerifier"`
	VaultWraps  map[string][]byte `json:"vaultWraps"`
}

func (r *credentialsReq) validate() error {
	if err := validKDF(r.KDFParams); err != nil {
		return err
	}
	if err := validSRP(r.SRPSalt, r.SRPVerifier); err != nil {
		return err
	}
	if len(r.VaultWraps) == 0 {
		return errors.New("缺少 Vault Key 重新封装结果")
	}
	return nil
}

// handleChangeCredentials：变更主密码后只替换 SRP 凭据与 Vault Key 封装（计划书 S-08），
// 并注销其他设备上的会话。
func (s *Server) handleChangeCredentials(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	var req credentialsReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	if err := req.validate(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
		return
	}
	up := &store.CredentialUpdate{KDFParams: req.KDFParams, SRPSalt: req.SRPSalt, SRPVerifier: req.SRPVerifier, VaultWraps: req.VaultWraps}
	if err := s.store.UpdateCredentials(r.Context(), a.session.UserID, up); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusBadRequest, "invalid_input", "vaultWraps 包含未知保险库")
			return
		}
		s.internal(w, err)
		return
	}
	_ = s.store.RevokeUserSessions(r.Context(), a.session.UserID, a.session.ID)
	s.audit(r.Context(), r, a.session.UserID, &a.device.ID, "pwd_changed")
	if user, err := s.store.UserByID(r.Context(), a.session.UserID); err == nil {
		s.notifyUser(r.Context(), user, "ZeroOne：主密码已变更", "你的主密码刚刚被修改，其他设备需要重新登录。如非本人操作，请立即使用 Recovery Kit 恢复账户。")
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------- 恢复 ----------

type recoveryAuthReq struct {
	Email        string `json:"email"`
	RecoveryAuth []byte `json:"recoveryAuth"`
}

func (s *Server) checkRecovery(r *http.Request, email string, proof []byte) (*store.User, *store.RecoveryKit, bool) {
	user, err := s.store.UserByEmailHash(r.Context(), s.crypto.emailHash(email))
	if err != nil {
		return nil, nil, false
	}
	kit, err := s.store.RecoveryKit(r.Context(), user.ID)
	if err != nil {
		return nil, nil, false
	}
	if subtle.ConstantTimeCompare(kit.AuthHash, sha256Sum(proof)) != 1 {
		s.audit(r.Context(), r, user.ID, nil, "recovery_fail")
		return nil, nil, false
	}
	return user, kit, true
}

// handleRecoveryKit 返回被恢复码封装的 Vault Key 密文，客户端用恢复码在本地解封。
func (s *Server) handleRecoveryKit(w http.ResponseWriter, r *http.Request) {
	var req recoveryAuthReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	user, kit, ok := s.checkRecovery(r, req.Email, req.RecoveryAuth)
	if !ok {
		writeError(w, http.StatusUnauthorized, "invalid_recovery_code", "恢复码不正确")
		return
	}
	vaults, err := s.store.VaultsByOwner(r.Context(), user.ID)
	if err != nil {
		s.internal(w, err)
		return
	}
	ids := make([]string, 0, len(vaults))
	for _, v := range vaults {
		ids = append(ids, v.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"userId": user.ID, "vkWrapEnc": kit.VKWrapEnc, "vaultIds": ids})
}

type recoveryCompleteReq struct {
	Email        string `json:"email"`
	RecoveryAuth []byte `json:"recoveryAuth"`
	credentialsReq
	NewRecovery struct {
		VKWrapEnc []byte `json:"vkWrapEnc"`
		AuthHash  []byte `json:"authHash"`
	} `json:"newRecovery"`
}

func (s *Server) handleRecoveryComplete(w http.ResponseWriter, r *http.Request) {
	var req recoveryCompleteReq
	if !decode(w, r, maxBody, &req) {
		return
	}
	if err := req.credentialsReq.validate(); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_input", err.Error())
		return
	}
	if len(req.NewRecovery.VKWrapEnc) == 0 || len(req.NewRecovery.AuthHash) != 32 {
		writeError(w, http.StatusBadRequest, "invalid_input", "恢复后必须轮换恢复套件")
		return
	}
	user, _, ok := s.checkRecovery(r, req.Email, req.RecoveryAuth)
	if !ok {
		writeError(w, http.StatusUnauthorized, "invalid_recovery_code", "恢复码不正确")
		return
	}
	up := &store.CredentialUpdate{
		KDFParams: req.KDFParams, SRPSalt: req.SRPSalt, SRPVerifier: req.SRPVerifier, VaultWraps: req.VaultWraps,
		Recovery: &store.RecoveryKit{VKWrapEnc: req.NewRecovery.VKWrapEnc, AuthHash: req.NewRecovery.AuthHash},
	}
	if err := s.store.UpdateCredentials(r.Context(), user.ID, up); err != nil {
		s.internal(w, err)
		return
	}
	_ = s.store.RevokeUserSessions(r.Context(), user.ID, "")
	s.audit(r.Context(), r, user.ID, nil, "recovery_used")
	s.notifyUser(r.Context(), user, "ZeroOne：账户已通过 Recovery Kit 恢复", "你的账户刚刚使用 Recovery Kit 重设了主密码，所有设备已退出登录。旧恢复码已作废，请妥善保管新的 Recovery Kit。")
	w.WriteHeader(http.StatusNoContent)
}
