// Package pgstore 是 store.Store 的 PostgreSQL 实现（pgx v5）。
package pgstore

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/zeroone/server/internal/store"
)

//go:embed migrations/*.sql
var migrations embed.FS

type Store struct {
	pool *pgxpool.Pool
}

func Open(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("连接数据库失败: %w", err)
	}
	s := &Store{pool: pool}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

// migrate 按文件名顺序执行未应用的迁移，每个迁移一个事务，用 advisory lock 防止多实例并发迁移。
func (s *Store) migrate(ctx context.Context) error {
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(7351001)`); err != nil {
		return err
	}
	defer conn.Exec(context.WithoutCancel(ctx), `SELECT pg_advisory_unlock(7351001)`)

	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	names, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, name := range names {
		var exists bool
		if err := conn.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE name=$1)`, name).Scan(&exists); err != nil {
			return err
		}
		if exists {
			continue
		}
		sql, err := migrations.ReadFile(name)
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return fmt.Errorf("迁移 %s 失败: %w", name, err)
			}
			_, err := tx.Exec(ctx, `INSERT INTO schema_migrations(name) VALUES($1)`, name)
			return err
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }
func (s *Store) Close()                         { s.pool.Close() }

func isUniqueViolation(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && pg.Code == "23505"
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return store.ErrNotFound
	}
	return err
}

// ---------- 账户 ----------

func (s *Store) CreateAccount(ctx context.Context, r *store.Registration) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		u := &r.User
		_, err := tx.Exec(ctx, `INSERT INTO users(id, email_enc, email_hash, kdf_params, srp_verifier, srp_salt, status)
			VALUES($1,$2,$3,$4,$5,$6,$7)`, u.ID, u.EmailEnc, u.EmailHash, u.KDFParams, u.SRPVerifier, u.SRPSalt, u.Status)
		if isUniqueViolation(err) {
			return store.ErrExists
		}
		if err != nil {
			return err
		}
		d := &r.Device
		if _, err := tx.Exec(ctx, `INSERT INTO devices(id, user_id, name, platform, pub_key, approved_at)
			VALUES($1,$2,$3,$4,$5,$6)`, d.ID, u.ID, d.Name, d.Platform, d.PubKey, d.ApprovedAt); err != nil {
			return err
		}
		v := &r.Vault
		_, err = tx.Exec(ctx, `INSERT INTO vaults(id, owner_id, kind, name_enc, vk_wrap, vk_gen) VALUES($1,$2,$3,$4,$5,$6)`,
			v.ID, u.ID, v.Kind, v.NameEnc, v.VKWrap, v.VKGen)
		if isUniqueViolation(err) {
			return store.ErrExists
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO recovery_kits(user_id, vk_wrap_enc, auth_hash) VALUES($1,$2,$3)`,
			u.ID, r.Recovery.VKWrapEnc, r.Recovery.AuthHash)
		return err
	})
}

const userCols = `id, email_enc, email_hash, kdf_params, srp_salt, srp_verifier, status, created_at, updated_at`

func scanUser(row pgx.Row) (*store.User, error) {
	var u store.User
	err := row.Scan(&u.ID, &u.EmailEnc, &u.EmailHash, &u.KDFParams, &u.SRPSalt, &u.SRPVerifier, &u.Status, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &u, nil
}

func (s *Store) UserByEmailHash(ctx context.Context, hash []byte) (*store.User, error) {
	return scanUser(s.pool.QueryRow(ctx, `SELECT `+userCols+` FROM users WHERE email_hash=$1`, hash))
}

func (s *Store) UserByID(ctx context.Context, id string) (*store.User, error) {
	return scanUser(s.pool.QueryRow(ctx, `SELECT `+userCols+` FROM users WHERE id=$1`, id))
}

func (s *Store) UpdateCredentials(ctx context.Context, userID string, up *store.CredentialUpdate) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE users SET kdf_params=$2, srp_salt=$3, srp_verifier=$4, updated_at=now() WHERE id=$1`,
			userID, up.KDFParams, up.SRPSalt, up.SRPVerifier)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return store.ErrNotFound
		}
		for vaultID, wrap := range up.VaultWraps {
			tag, err := tx.Exec(ctx, `UPDATE vaults SET vk_wrap=$3, vk_gen=vk_gen+1 WHERE id=$1 AND owner_id=$2`, vaultID, userID, wrap)
			if err != nil {
				return err
			}
			if tag.RowsAffected() == 0 {
				return store.ErrNotFound
			}
		}
		if up.Recovery != nil {
			_, err := tx.Exec(ctx, `INSERT INTO recovery_kits(user_id, vk_wrap_enc, auth_hash) VALUES($1,$2,$3)
				ON CONFLICT (user_id) DO UPDATE SET vk_wrap_enc=excluded.vk_wrap_enc, auth_hash=excluded.auth_hash,
				created_at=now(), used_at=NULL`, userID, up.Recovery.VKWrapEnc, up.Recovery.AuthHash)
			if err != nil {
				return err
			}
		}
		return nil
	})
}

// ---------- 设备 ----------

const deviceCols = `id, user_id, name, platform, pub_key, approved_by, approved_at, last_seen_at, revoked_at, created_at`

func scanDevice(row pgx.Row) (*store.Device, error) {
	var d store.Device
	err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.PubKey, &d.ApprovedBy, &d.ApprovedAt, &d.LastSeenAt, &d.RevokedAt, &d.CreatedAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &d, nil
}

func (s *Store) CreateDevice(ctx context.Context, d *store.Device) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO devices(id, user_id, name, platform, pub_key, approved_at) VALUES($1,$2,$3,$4,$5,$6)`,
		d.ID, d.UserID, d.Name, d.Platform, d.PubKey, d.ApprovedAt)
	if isUniqueViolation(err) {
		return store.ErrExists
	}
	return err
}

func (s *Store) GetDevice(ctx context.Context, userID, deviceID string) (*store.Device, error) {
	return scanDevice(s.pool.QueryRow(ctx, `SELECT `+deviceCols+` FROM devices WHERE id=$1 AND user_id=$2`, deviceID, userID))
}

func (s *Store) ListDevices(ctx context.Context, userID string) ([]store.Device, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+deviceCols+` FROM devices WHERE user_id=$1 ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.Device
	for rows.Next() {
		d, err := scanDevice(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *d)
	}
	return out, rows.Err()
}

func (s *Store) ApproveDevice(ctx context.Context, userID, deviceID, approverID string) error {
	var approver *string
	if approverID != "" {
		approver = &approverID
	}
	tag, err := s.pool.Exec(ctx, `UPDATE devices SET approved_at=now(), approved_by=$3
		WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL`, deviceID, userID, approver)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return store.ErrNotFound
	}
	return nil
}

func (s *Store) RevokeDevice(ctx context.Context, userID, deviceID string) error {
	return pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE devices SET revoked_at=now() WHERE id=$1 AND user_id=$2`, deviceID, userID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return store.ErrNotFound
		}
		_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE device_id=$1 AND revoked_at IS NULL`, deviceID)
		return err
	})
}

func (s *Store) TouchDevice(ctx context.Context, deviceID string, at time.Time) error {
	// 降低写放大：一分钟内只更新一次
	_, err := s.pool.Exec(ctx, `UPDATE devices SET last_seen_at=$2
		WHERE id=$1 AND (last_seen_at IS NULL OR last_seen_at < $2 - interval '1 minute')`, deviceID, at)
	return err
}

// ---------- 会话 ----------

func (s *Store) CreateSession(ctx context.Context, sess *store.Session) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO sessions(id, user_id, device_id, token_hash, expires_at, ip_hash) VALUES($1,$2,$3,$4,$5,$6)`,
		sess.ID, sess.UserID, sess.DeviceID, sess.TokenHash, sess.ExpiresAt, sess.IPHash)
	return err
}

func (s *Store) SessionByTokenHash(ctx context.Context, hash []byte) (*store.Session, error) {
	var x store.Session
	err := s.pool.QueryRow(ctx, `SELECT id, user_id, device_id, token_hash, expires_at, ip_hash, revoked_at, created_at
		FROM sessions WHERE token_hash=$1`, hash).
		Scan(&x.ID, &x.UserID, &x.DeviceID, &x.TokenHash, &x.ExpiresAt, &x.IPHash, &x.RevokedAt, &x.CreatedAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &x, nil
}

func (s *Store) RevokeSession(ctx context.Context, id string) error {
	_, err := s.pool.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE id=$1 AND revoked_at IS NULL`, id)
	return err
}

func (s *Store) RevokeUserSessions(ctx context.Context, userID, except string) error {
	var err error
	if except == "" {
		_, err = s.pool.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL`, userID)
	} else {
		_, err = s.pool.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND id<>$2 AND revoked_at IS NULL`, userID, except)
	}
	return err
}

// ---------- 保险库与恢复 ----------

func (s *Store) VaultsByOwner(ctx context.Context, userID string) ([]store.Vault, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, owner_id, kind, name_enc, vk_wrap, vk_gen, created_at FROM vaults WHERE owner_id=$1 ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.Vault
	for rows.Next() {
		var v store.Vault
		if err := rows.Scan(&v.ID, &v.OwnerID, &v.Kind, &v.NameEnc, &v.VKWrap, &v.VKGen, &v.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

func (s *Store) RecoveryKit(ctx context.Context, userID string) (*store.RecoveryKit, error) {
	var k store.RecoveryKit
	err := s.pool.QueryRow(ctx, `SELECT user_id, vk_wrap_enc, auth_hash, created_at, used_at FROM recovery_kits WHERE user_id=$1`, userID).
		Scan(&k.UserID, &k.VKWrapEnc, &k.AuthHash, &k.CreatedAt, &k.UsedAt)
	if err != nil {
		return nil, notFound(err)
	}
	return &k, nil
}

// ---------- 同步 ----------

// PushItem 在单事务内完成：行锁 → 乐观锁校验 → 旧版本入历史 → 写入 → 追加 change_log。
func (s *Store) PushItem(ctx context.Context, userID, deviceID string, c *store.PushChange) (*store.PushResult, error) {
	res := &store.PushResult{ItemID: c.ItemID}
	err := pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		var owner string
		err := tx.QueryRow(ctx, `SELECT owner_id FROM vaults WHERE id=$1`, c.VaultID).Scan(&owner)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && owner != userID) {
			res.Status = store.PushForbidden
			return nil
		}
		if err != nil {
			return err
		}

		var cur struct {
			vaultID  string
			revision int64
			sha      []byte
			blob     []byte
			device   string
		}
		exists := true
		err = tx.QueryRow(ctx, `SELECT vault_id, revision, blob_sha256, blob, device_id FROM items WHERE id=$1 FOR UPDATE`, c.ItemID).
			Scan(&cur.vaultID, &cur.revision, &cur.sha, &cur.blob, &cur.device)
		if errors.Is(err, pgx.ErrNoRows) {
			exists = false
		} else if err != nil {
			return err
		}
		if exists && cur.vaultID != c.VaultID {
			res.Status = store.PushForbidden
			return nil
		}

		sum := sha256sum(c.Blob)
		if exists && cur.revision == c.Revision && bytesEqual(cur.sha, sum) {
			res.Status, res.ServerRevision = store.PushDuplicate, cur.revision
			return nil
		}
		var curRev int64
		if exists {
			curRev = cur.revision
		}
		if curRev != c.BaseRevision || c.Revision <= c.BaseRevision {
			res.Status, res.ServerRevision = store.PushConflict, curRev
			return nil
		}

		var deletedAt *time.Time
		op := "upsert"
		if c.Deleted {
			now := time.Now().UTC()
			deletedAt = &now
			op = "delete"
		}
		if exists {
			if _, err := tx.Exec(ctx, `INSERT INTO item_versions(item_id, revision, blob, device_id) VALUES($1,$2,$3,$4)`,
				c.ItemID, cur.revision, cur.blob, cur.device); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE items SET kind=$2, blob=$3, blob_bytes=$4, blob_sha256=$5, revision=$6,
				device_id=$7, deleted_at=$8, updated_at=now() WHERE id=$1`,
				c.ItemID, c.Kind, c.Blob, len(c.Blob), sum, c.Revision, deviceID, deletedAt); err != nil {
				return err
			}
		} else {
			if _, err := tx.Exec(ctx, `INSERT INTO items(id, vault_id, kind, blob, blob_bytes, blob_sha256, revision, device_id, deleted_at)
				VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
				c.ItemID, c.VaultID, c.Kind, c.Blob, len(c.Blob), sum, c.Revision, deviceID, deletedAt); err != nil {
				return err
			}
		}
		var seq int64
		if err := tx.QueryRow(ctx, `INSERT INTO change_log(user_id, vault_id, entity, entity_id, op, revision)
			VALUES($1,$2,'item',$3,$4,$5) RETURNING seq`, userID, c.VaultID, c.ItemID, op, c.Revision).Scan(&seq); err != nil {
			return err
		}
		res.Status, res.Seq, res.ServerRevision = store.PushApplied, seq, c.Revision
		return nil
	})
	if err != nil {
		return nil, err
	}
	return res, nil
}

func (s *Store) Pull(ctx context.Context, userID string, since int64, limit int) ([]store.Change, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT c.seq, c.vault_id, c.entity, c.entity_id, c.op, c.revision, c.created_at,
		       i.id, i.kind, i.blob, i.revision, i.device_id, i.deleted_at, i.updated_at
		FROM change_log c
		LEFT JOIN items i ON c.entity = 'item' AND i.id = c.entity_id
		WHERE c.user_id = $1 AND c.seq > $2
		ORDER BY c.seq
		LIMIT $3`, userID, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.Change
	for rows.Next() {
		var c store.Change
		var (
			id, kind, dev *string
			blob          []byte
			rev           *int64
			deletedAt     *time.Time
			updatedAt     *time.Time
		)
		if err := rows.Scan(&c.Seq, &c.VaultID, &c.Entity, &c.EntityID, &c.Op, &c.Revision, &c.CreatedAt,
			&id, &kind, &blob, &rev, &dev, &deletedAt, &updatedAt); err != nil {
			return nil, err
		}
		if id != nil {
			c.Item = &store.Item{ID: *id, VaultID: c.VaultID, Kind: *kind, Blob: blob, Revision: *rev, DeviceID: *dev, DeletedAt: deletedAt, UpdatedAt: *updatedAt}
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// ---------- 审计 ----------

func (s *Store) AddAudit(ctx context.Context, e *store.AuditEvent) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO audit_events(user_id, device_id, event, ip_hash, ua_hash) VALUES($1,$2,$3,$4,$5)`,
		e.UserID, e.DeviceID, e.Event, e.IPHash, e.UAHash)
	return err
}

func (s *Store) ListAudit(ctx context.Context, userID string, limit int) ([]store.AuditEvent, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, user_id, device_id, event, ip_hash, ua_hash, created_at
		FROM audit_events WHERE user_id=$1 ORDER BY id DESC LIMIT $2`, userID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []store.AuditEvent
	for rows.Next() {
		var e store.AuditEvent
		if err := rows.Scan(&e.ID, &e.UserID, &e.DeviceID, &e.Event, &e.IPHash, &e.UAHash, &e.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

var _ store.Store = (*Store)(nil)
