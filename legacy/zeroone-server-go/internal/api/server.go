// Package api 实现 ZeroOne 同步服务的 HTTP 接口。
//
// 服务端永远不接收主密码、Secret Key 或任何明文条目字段（计划书 §3.1 核心原则）。
package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/zeroone/server/internal/config"
	"github.com/zeroone/server/internal/ids"
	"github.com/zeroone/server/internal/notify"
	"github.com/zeroone/server/internal/srp"
	"github.com/zeroone/server/internal/store"
)

const (
	maxBody     = 1 << 20
	maxSyncBody = 16 << 20
)

type Server struct {
	cfg    *config.Config
	store  store.Store
	mailer notify.Mailer
	crypto *serverCrypto

	handshakes sync.Map // handshakeID -> *handshake
	otps       sync.Map // deviceID -> *deviceOTP

	authLimiter *rateLimiter
	apiLimiter  *rateLimiter
}

type handshake struct {
	userID  string
	srv     *srp.Server
	expires time.Time
}

type deviceOTP struct {
	codeHash []byte
	expires  time.Time
	attempts int
}

func New(cfg *config.Config, st store.Store, mailer notify.Mailer) (*Server, error) {
	sc, err := newServerCrypto(cfg.ServerSecret)
	if err != nil {
		return nil, err
	}
	s := &Server{
		cfg:         cfg,
		store:       st,
		mailer:      mailer,
		crypto:      sc,
		authLimiter: newRateLimiter(20, 10),
		apiLimiter:  newRateLimiter(600, 120),
	}
	go s.gcLoop()
	return s, nil
}

func (s *Server) gcLoop() {
	for range time.Tick(time.Minute) {
		now := time.Now()
		s.handshakes.Range(func(k, v any) bool {
			if now.After(v.(*handshake).expires) {
				s.handshakes.Delete(k)
			}
			return true
		})
		s.otps.Range(func(k, v any) bool {
			if now.After(v.(*deviceOTP).expires) {
				s.otps.Delete(k)
			}
			return true
		})
	}
}

// Handler 组装路由与中间件。
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", s.handleHealth)
	mux.HandleFunc("GET /readyz", s.handleReady)

	auth := func(h http.HandlerFunc) http.Handler { return s.authLimiter.middleware(h) }
	mux.Handle("POST /v1/auth/register", auth(s.handleRegister))
	mux.Handle("POST /v1/auth/login/start", auth(s.handleLoginStart))
	mux.Handle("POST /v1/auth/login/finish", auth(s.handleLoginFinish))
	mux.Handle("POST /v1/recovery/kit", auth(s.handleRecoveryKit))
	mux.Handle("POST /v1/recovery/complete", auth(s.handleRecoveryComplete))

	// 已登录即可访问（新设备待批准期间也可用）
	session := func(h http.HandlerFunc) http.Handler { return s.apiLimiter.middleware(s.requireSession(false, h)) }
	mux.Handle("POST /v1/auth/logout", session(s.handleLogout))
	mux.Handle("GET /v1/devices/self", session(s.handleDeviceSelf))
	mux.Handle("POST /v1/devices/self/verify", auth(s.requireSession(false, s.handleDeviceVerifyEmail)))

	// 需要设备已被批准
	approved := func(h http.HandlerFunc) http.Handler { return s.apiLimiter.middleware(s.requireSession(true, h)) }
	mux.Handle("GET /v1/account", approved(s.handleAccount))
	mux.Handle("PUT /v1/account/credentials", approved(s.handleChangeCredentials))
	mux.Handle("GET /v1/devices", approved(s.handleListDevices))
	mux.Handle("POST /v1/devices/{id}/approve", approved(s.handleApproveDevice))
	mux.Handle("DELETE /v1/devices/{id}", approved(s.handleRevokeDevice))
	mux.Handle("GET /v1/audit", approved(s.handleAudit))
	mux.Handle("POST /v1/sync/push", approved(s.handlePush))
	mux.Handle("GET /v1/sync/pull", approved(s.handlePull))

	return s.recoverer(s.logRequests(securityHeaders(s.cors(mux))))
}

// ---------- 通用中间件 ----------

type ctxKey int

const sessionKey ctxKey = 1

type authContext struct {
	session *store.Session
	device  *store.Device
}

func sessionFrom(ctx context.Context) *authContext {
	a, _ := ctx.Value(sessionKey).(*authContext)
	return a
}

func (s *Server) requireSession(needApproved bool, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			writeError(w, http.StatusUnauthorized, "unauthorized", "缺少会话令牌")
			return
		}
		sess, err := s.store.SessionByTokenHash(r.Context(), sha256Sum([]byte(token)))
		if err != nil || sess.RevokedAt != nil || time.Now().After(sess.ExpiresAt) {
			writeError(w, http.StatusUnauthorized, "unauthorized", "会话无效或已过期")
			return
		}
		dev, err := s.store.GetDevice(r.Context(), sess.UserID, sess.DeviceID)
		if err != nil || dev.RevokedAt != nil {
			writeError(w, http.StatusUnauthorized, "device_revoked", "设备已被移除")
			return
		}
		if needApproved && !dev.Approved() {
			writeError(w, http.StatusForbidden, "device_pending", "新设备需要在已登录设备上批准或通过邮箱验证")
			return
		}
		_ = s.store.TouchDevice(r.Context(), dev.ID, time.Now().UTC())
		ctx := context.WithValue(r.Context(), sessionKey, &authContext{session: sess, device: dev})
		next(w, r.WithContext(ctx))
	}
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := false
		for _, o := range s.cfg.CORSOrigins {
			if o == origin {
				allowed = true
			}
		}
		if allowed {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE")
			w.Header().Set("Vary", "Origin")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// logRequests 只记录方法、路由、状态与耗时——不记录请求体、令牌与查询参数中的邮箱。
func (s *Server) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rid := ids.Token(8)
		w.Header().Set("X-Request-Id", rid)
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		slog.Info("http", "rid", rid, "method", r.Method, "path", r.URL.Path, "status", rec.status, "ms", time.Since(start).Milliseconds())
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				slog.Error("panic", "err", v, "stack", string(debug.Stack()))
				writeError(w, http.StatusInternalServerError, "internal", "服务器内部错误")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// ---------- JSON 工具 ----------

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	var b errorBody
	b.Error.Code, b.Error.Message = code, msg
	writeJSON(w, status, b)
}

func decode(w http.ResponseWriter, r *http.Request, limit int64, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large", "请求体过大")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request", "请求格式错误: "+err.Error())
		}
		return false
	}
	return true
}

func (s *Server) internal(w http.ResponseWriter, err error) {
	slog.Error("internal error", "err", err)
	writeError(w, http.StatusInternalServerError, "internal", "服务器内部错误")
}

// ---------- 健康检查 ----------

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "not_ready", "数据库不可用")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// ---------- 审计与通知 ----------

func (s *Server) audit(ctx context.Context, r *http.Request, userID string, deviceID *string, event string) {
	e := &store.AuditEvent{
		UserID:   userID,
		DeviceID: deviceID,
		Event:    event,
		IPHash:   s.crypto.emailHash("ip|" + clientIP(r))[:16],
		UAHash:   sha256Sum([]byte(r.UserAgent()))[:16],
	}
	if err := s.store.AddAudit(ctx, e); err != nil {
		slog.Warn("audit write failed", "err", err)
	}
}

func (s *Server) notifyUser(ctx context.Context, u *store.User, subject, body string) {
	email, err := s.crypto.decryptEmail(u.EmailEnc)
	if err != nil {
		slog.Warn("cannot decrypt email for notification", "user", u.ID)
		return
	}
	go func() {
		c, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		if err := s.mailer.Send(c, notify.Message{To: email, Subject: subject, Body: body}); err != nil {
			slog.Warn("mail send failed", "err", err)
		}
	}()
}
