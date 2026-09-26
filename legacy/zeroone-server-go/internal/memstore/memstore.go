// Package memstore 是 store.Store 的内存实现，用于本地开发（无需 PostgreSQL）与测试。
package memstore

import (
	"bytes"
	"context"
	"crypto/sha256"
	"sort"
	"sync"
	"time"

	"github.com/zeroone/server/internal/store"
)

type Store struct {
	mu       sync.Mutex
	users    map[string]*store.User
	devices  map[string]*store.Device
	vaults   map[string]*store.Vault
	items    map[string]*store.Item
	versions map[string][]store.Item
	changes  []changeRow
	sessions map[string]*store.Session
	recovery map[string]*store.RecoveryKit
	audit    []store.AuditEvent
	seq      int64
	auditSeq int64
}

type changeRow struct {
	store.Change
	UserID string
}

func New() *Store {
	return &Store{
		users:    map[string]*store.User{},
		devices:  map[string]*store.Device{},
		vaults:   map[string]*store.Vault{},
		items:    map[string]*store.Item{},
		versions: map[string][]store.Item{},
		sessions: map[string]*store.Session{},
		recovery: map[string]*store.RecoveryKit{},
	}
}

func (s *Store) Ping(context.Context) error { return nil }
func (s *Store) Close()                     {}

func (s *Store) CreateAccount(_ context.Context, r *store.Registration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, u := range s.users {
		if bytes.Equal(u.EmailHash, r.User.EmailHash) {
			return store.ErrExists
		}
	}
	now := time.Now().UTC()
	u := r.User
	u.CreatedAt, u.UpdatedAt = now, now
	if u.Status == "" {
		u.Status = "active"
	}
	s.users[u.ID] = &u
	d := r.Device
	d.CreatedAt = now
	s.devices[d.ID] = &d
	v := r.Vault
	v.CreatedAt = now
	s.vaults[v.ID] = &v
	rk := r.Recovery
	rk.CreatedAt = now
	s.recovery[u.ID] = &rk
	return nil
}

func (s *Store) UserByEmailHash(_ context.Context, hash []byte) (*store.User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, u := range s.users {
		if bytes.Equal(u.EmailHash, hash) {
			c := *u
			return &c, nil
		}
	}
	return nil, store.ErrNotFound
}

func (s *Store) UserByID(_ context.Context, id string) (*store.User, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[id]
	if !ok {
		return nil, store.ErrNotFound
	}
	c := *u
	return &c, nil
}

func (s *Store) UpdateCredentials(_ context.Context, userID string, up *store.CredentialUpdate) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	u, ok := s.users[userID]
	if !ok {
		return store.ErrNotFound
	}
	for id := range up.VaultWraps {
		if v, ok := s.vaults[id]; !ok || v.OwnerID != userID {
			return store.ErrNotFound
		}
	}
	u.KDFParams, u.SRPSalt, u.SRPVerifier = up.KDFParams, up.SRPSalt, up.SRPVerifier
	u.UpdatedAt = time.Now().UTC()
	for id, wrap := range up.VaultWraps {
		v := s.vaults[id]
		v.VKWrap = wrap
		v.VKGen++
	}
	if up.Recovery != nil {
		rk := *up.Recovery
		rk.UserID = userID
		rk.CreatedAt = time.Now().UTC()
		s.recovery[userID] = &rk
	}
	return nil
}

func (s *Store) CreateDevice(_ context.Context, d *store.Device) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.devices[d.ID]; ok {
		return store.ErrExists
	}
	c := *d
	c.CreatedAt = time.Now().UTC()
	s.devices[d.ID] = &c
	return nil
}

func (s *Store) GetDevice(_ context.Context, userID, deviceID string) (*store.Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[deviceID]
	if !ok || d.UserID != userID {
		return nil, store.ErrNotFound
	}
	c := *d
	return &c, nil
}

func (s *Store) ListDevices(_ context.Context, userID string) ([]store.Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []store.Device
	for _, d := range s.devices {
		if d.UserID == userID {
			out = append(out, *d)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CreatedAt.Before(out[j].CreatedAt) })
	return out, nil
}

func (s *Store) ApproveDevice(_ context.Context, userID, deviceID, approverID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[deviceID]
	if !ok || d.UserID != userID || d.RevokedAt != nil {
		return store.ErrNotFound
	}
	now := time.Now().UTC()
	d.ApprovedAt = &now
	if approverID != "" {
		d.ApprovedBy = &approverID
	}
	return nil
}

func (s *Store) RevokeDevice(_ context.Context, userID, deviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[deviceID]
	if !ok || d.UserID != userID {
		return store.ErrNotFound
	}
	now := time.Now().UTC()
	d.RevokedAt = &now
	for _, sess := range s.sessions {
		if sess.DeviceID == deviceID && sess.RevokedAt == nil {
			sess.RevokedAt = &now
		}
	}
	return nil
}

func (s *Store) TouchDevice(_ context.Context, deviceID string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d, ok := s.devices[deviceID]; ok {
		d.LastSeenAt = &at
	}
	return nil
}

func (s *Store) CreateSession(_ context.Context, sess *store.Session) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := *sess
	c.CreatedAt = time.Now().UTC()
	s.sessions[sess.ID] = &c
	return nil
}

func (s *Store) SessionByTokenHash(_ context.Context, hash []byte) (*store.Session, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, sess := range s.sessions {
		if bytes.Equal(sess.TokenHash, hash) {
			c := *sess
			return &c, nil
		}
	}
	return nil, store.ErrNotFound
}

func (s *Store) RevokeSession(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.sessions[id]; ok && sess.RevokedAt == nil {
		now := time.Now().UTC()
		sess.RevokedAt = &now
	}
	return nil
}

func (s *Store) RevokeUserSessions(_ context.Context, userID, except string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now().UTC()
	for _, sess := range s.sessions {
		if sess.UserID == userID && sess.ID != except && sess.RevokedAt == nil {
			sess.RevokedAt = &now
		}
	}
	return nil
}

func (s *Store) VaultsByOwner(_ context.Context, userID string) ([]store.Vault, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []store.Vault
	for _, v := range s.vaults {
		if v.OwnerID == userID {
			out = append(out, *v)
		}
	}
	return out, nil
}

func (s *Store) RecoveryKit(_ context.Context, userID string) (*store.RecoveryKit, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rk, ok := s.recovery[userID]
	if !ok {
		return nil, store.ErrNotFound
	}
	c := *rk
	return &c, nil
}

func (s *Store) PushItem(_ context.Context, userID, deviceID string, c *store.PushChange) (*store.PushResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res := &store.PushResult{ItemID: c.ItemID}
	v, ok := s.vaults[c.VaultID]
	if !ok || v.OwnerID != userID {
		res.Status = store.PushForbidden
		return res, nil
	}
	sum := sha256.Sum256(c.Blob)
	now := time.Now().UTC()
	cur, exists := s.items[c.ItemID]
	if exists && cur.VaultID != c.VaultID {
		res.Status = store.PushForbidden
		return res, nil
	}
	var curRev int64
	if exists {
		curRev = cur.Revision
		if cur.Revision == c.Revision && bytes.Equal(cur.BlobSHA256, sum[:]) {
			res.Status, res.ServerRevision = store.PushDuplicate, cur.Revision
			return res, nil
		}
	}
	if curRev != c.BaseRevision || c.Revision <= c.BaseRevision {
		res.Status, res.ServerRevision = store.PushConflict, curRev
		return res, nil
	}
	if exists {
		s.versions[c.ItemID] = append(s.versions[c.ItemID], *cur)
	}
	item := &store.Item{
		ID: c.ItemID, VaultID: c.VaultID, Kind: c.Kind, Blob: c.Blob, BlobBytes: len(c.Blob),
		BlobSHA256: sum[:], Revision: c.Revision, DeviceID: deviceID, CreatedAt: now, UpdatedAt: now,
	}
	if exists {
		item.CreatedAt = cur.CreatedAt
	}
	op := "upsert"
	if c.Deleted {
		item.DeletedAt = &now
		op = "delete"
	}
	s.items[c.ItemID] = item
	s.seq++
	s.changes = append(s.changes, changeRow{
		Change: store.Change{Seq: s.seq, VaultID: c.VaultID, Entity: "item", EntityID: c.ItemID, Op: op, Revision: c.Revision, CreatedAt: now},
		UserID: userID,
	})
	res.Status, res.Seq, res.ServerRevision = store.PushApplied, s.seq, c.Revision
	return res, nil
}

func (s *Store) Pull(_ context.Context, userID string, since int64, limit int) ([]store.Change, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []store.Change
	for _, row := range s.changes {
		if row.UserID != userID || row.Seq <= since {
			continue
		}
		c := row.Change
		if it, ok := s.items[c.EntityID]; ok {
			snapshot := *it
			c.Item = &snapshot
		}
		out = append(out, c)
		if len(out) >= limit {
			break
		}
	}
	return out, nil
}

func (s *Store) AddAudit(_ context.Context, e *store.AuditEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.auditSeq++
	c := *e
	c.ID = s.auditSeq
	c.CreatedAt = time.Now().UTC()
	s.audit = append(s.audit, c)
	return nil
}

func (s *Store) ListAudit(_ context.Context, userID string, limit int) ([]store.AuditEvent, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []store.AuditEvent
	for i := len(s.audit) - 1; i >= 0 && len(out) < limit; i-- {
		if s.audit[i].UserID == userID {
			out = append(out, s.audit[i])
		}
	}
	return out, nil
}

var _ store.Store = (*Store)(nil)
