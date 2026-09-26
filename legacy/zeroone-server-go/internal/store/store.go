// Package store 定义持久化接口与领域模型。服务端只保存密文与非敏感元数据。
package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

var (
	ErrNotFound = errors.New("not found")
	ErrExists   = errors.New("already exists")
)

type User struct {
	ID          string
	EmailEnc    []byte
	EmailHash   []byte
	KDFParams   json.RawMessage
	SRPSalt     []byte
	SRPVerifier []byte
	Status      string
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

type Device struct {
	ID         string
	UserID     string
	Name       string
	Platform   string
	PubKey     []byte
	ApprovedBy *string
	ApprovedAt *time.Time
	LastSeenAt *time.Time
	RevokedAt  *time.Time
	CreatedAt  time.Time
}

func (d *Device) Approved() bool { return d.ApprovedAt != nil && d.RevokedAt == nil }

type Vault struct {
	ID        string
	OwnerID   string
	Kind      string
	NameEnc   []byte
	VKWrap    []byte
	VKGen     int
	CreatedAt time.Time
}

type Item struct {
	ID         string
	VaultID    string
	Kind       string
	Blob       []byte
	BlobBytes  int
	BlobSHA256 []byte
	Revision   int64
	DeviceID   string
	DeletedAt  *time.Time
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

type Session struct {
	ID        string
	UserID    string
	DeviceID  string
	TokenHash []byte
	ExpiresAt time.Time
	IPHash    []byte
	RevokedAt *time.Time
	CreatedAt time.Time
}

type RecoveryKit struct {
	UserID    string
	VKWrapEnc []byte
	AuthHash  []byte
	CreatedAt time.Time
	UsedAt    *time.Time
}

type AuditEvent struct {
	ID        int64
	UserID    string
	DeviceID  *string
	Event     string
	IPHash    []byte
	UAHash    []byte
	CreatedAt time.Time
}

// Registration 是注册时一次性写入的全部数据（单事务）。
type Registration struct {
	User     User
	Device   Device
	Vault    Vault
	Recovery RecoveryKit
}

// PushChange 是客户端上行的一条条目变更。
type PushChange struct {
	ItemID       string
	VaultID      string
	Kind         string
	Blob         []byte
	BaseRevision int64
	Revision     int64
	Deleted      bool
}

type PushStatus string

const (
	PushApplied   PushStatus = "applied"
	PushDuplicate PushStatus = "duplicate"
	PushConflict  PushStatus = "conflict"
	PushForbidden PushStatus = "forbidden"
)

type PushResult struct {
	ItemID         string
	Status         PushStatus
	Seq            int64
	ServerRevision int64
}

// Change 是 change_log 的一行，Item 为该实体的当前快照（已删除时仍返回墓碑）。
type Change struct {
	Seq       int64
	VaultID   string
	Entity    string
	EntityID  string
	Op        string
	Revision  int64
	CreatedAt time.Time
	Item      *Item
}

// CredentialUpdate 用于变更主密码或恢复：替换 SRP 凭据与 Vault Key 封装。
type CredentialUpdate struct {
	KDFParams   json.RawMessage
	SRPSalt     []byte
	SRPVerifier []byte
	VaultWraps  map[string][]byte
	// 恢复场景下同时轮换恢复套件；变更主密码时为 nil
	Recovery *RecoveryKit
}

type Store interface {
	Ping(ctx context.Context) error
	Close()

	CreateAccount(ctx context.Context, r *Registration) error
	UserByEmailHash(ctx context.Context, hash []byte) (*User, error)
	UserByID(ctx context.Context, id string) (*User, error)
	UpdateCredentials(ctx context.Context, userID string, u *CredentialUpdate) error

	CreateDevice(ctx context.Context, d *Device) error
	GetDevice(ctx context.Context, userID, deviceID string) (*Device, error)
	ListDevices(ctx context.Context, userID string) ([]Device, error)
	ApproveDevice(ctx context.Context, userID, deviceID, approverID string) error
	RevokeDevice(ctx context.Context, userID, deviceID string) error
	TouchDevice(ctx context.Context, deviceID string, at time.Time) error

	CreateSession(ctx context.Context, s *Session) error
	SessionByTokenHash(ctx context.Context, hash []byte) (*Session, error)
	RevokeSession(ctx context.Context, id string) error
	RevokeUserSessions(ctx context.Context, userID, exceptSessionID string) error

	VaultsByOwner(ctx context.Context, userID string) ([]Vault, error)
	RecoveryKit(ctx context.Context, userID string) (*RecoveryKit, error)

	PushItem(ctx context.Context, userID, deviceID string, c *PushChange) (*PushResult, error)
	Pull(ctx context.Context, userID string, since int64, limit int) ([]Change, error)

	AddAudit(ctx context.Context, e *AuditEvent) error
	ListAudit(ctx context.Context, userID string, limit int) ([]AuditEvent, error)
}
