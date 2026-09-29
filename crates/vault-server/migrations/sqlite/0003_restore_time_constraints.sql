-- 恢复 0002 列级转换丢失的 NOT NULL 约束；已有 NULL 数据拒绝迁移，不猜测时间。
-- 新子表先引用新父表，复制后先删除旧子表，再替换父表；事务内无需关闭外键。
-- AUTOINCREMENT 的高水位可能大于现存最大 ID，必须同时保留，避免同步游标倒退。

CREATE TEMP TABLE vaultone_sequence_v3 (name TEXT PRIMARY KEY, seq INTEGER NOT NULL);
INSERT INTO vaultone_sequence_v3 SELECT name, seq FROM sqlite_sequence
WHERE name IN ('item_versions', 'change_log', 'audit_events');

CREATE TABLE users_v3 (
  id TEXT PRIMARY KEY,
  email_hash BLOB NOT NULL UNIQUE,
  email_enc BLOB NOT NULL,
  kdf TEXT NOT NULL,
  srp_salt BLOB NOT NULL,
  srp_verifier BLOB NOT NULL,
  vault_id TEXT NOT NULL,
  vk_wrap BLOB NOT NULL,
  vk_gen BIGINT NOT NULL DEFAULT 1,
  recovery_wrap BLOB NOT NULL,
  recovery_auth_hash BLOB NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
INSERT INTO users_v3 (id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,
  vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, created_at, updated_at)
SELECT id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,
  vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, created_at, updated_at FROM users;

CREATE TABLE devices_v3 (
  user_id TEXT NOT NULL REFERENCES users_v3(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  approved_at TEXT,
  approved_by TEXT,
  last_seen_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, id)
);
INSERT INTO devices_v3 (user_id, id, name, platform, approved_at, approved_by, last_seen_at, revoked_at, created_at)
SELECT user_id, id, name, platform, approved_at, approved_by, last_seen_at, revoked_at, created_at FROM devices;

CREATE TABLE sessions_v3 (
  token_hash BLOB PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users_v3(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);
INSERT INTO sessions_v3 (token_hash, user_id, device_id, expires_at, revoked_at, created_at)
SELECT token_hash, user_id, device_id, expires_at, revoked_at, created_at FROM sessions;

CREATE TABLE handshakes_v3 (
  id TEXT PRIMARY KEY,
  user_id TEXT,
  b_enc BLOB NOT NULL,
  expires_at TEXT NOT NULL
);
INSERT INTO handshakes_v3 (id, user_id, b_enc, expires_at)
SELECT id, user_id, b_enc, expires_at FROM handshakes;

CREATE TABLE device_otps_v3 (
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  code_hash BLOB NOT NULL,
  expires_at TEXT NOT NULL,
  attempts BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, device_id)
);
INSERT INTO device_otps_v3 (user_id, device_id, code_hash, expires_at, attempts)
SELECT user_id, device_id, code_hash, expires_at, attempts FROM device_otps;

CREATE TABLE items_v3 (
  user_id TEXT NOT NULL REFERENCES users_v3(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  kind TEXT NOT NULL,
  blob BLOB NOT NULL,
  blob_hash BLOB NOT NULL,
  revision BIGINT NOT NULL,
  deleted BIGINT NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  device_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, id)
);
INSERT INTO items_v3 (user_id, id, kind, blob, blob_hash, revision, deleted, updated_at, device_id, created_at)
SELECT user_id, id, kind, blob, blob_hash, revision, deleted, updated_at, device_id, created_at FROM items;

CREATE TABLE item_versions_v3 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users_v3(id) ON DELETE CASCADE,
  item_id TEXT NOT NULL,
  revision BIGINT NOT NULL,
  blob BLOB NOT NULL,
  device_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
INSERT INTO item_versions_v3 (id, user_id, item_id, revision, blob, device_id, created_at)
SELECT id, user_id, item_id, revision, blob, device_id, created_at FROM item_versions;

CREATE TABLE change_log_v3 (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  revision BIGINT NOT NULL,
  created_at TEXT NOT NULL
);
INSERT INTO change_log_v3 (seq, user_id, item_id, revision, created_at)
SELECT seq, user_id, item_id, revision, created_at FROM change_log;

CREATE TABLE audit_events_v3 (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  device_id TEXT,
  event TEXT NOT NULL,
  ip_hash BLOB,
  created_at TEXT NOT NULL
);
INSERT INTO audit_events_v3 (id, user_id, device_id, event, ip_hash, created_at)
SELECT id, user_id, device_id, event, ip_hash, created_at FROM audit_events;

DROP TABLE devices;
DROP TABLE sessions;
DROP TABLE items;
DROP TABLE item_versions;
DROP TABLE users;
DROP TABLE handshakes;
DROP TABLE device_otps;
DROP TABLE change_log;
DROP TABLE audit_events;

ALTER TABLE users_v3 RENAME TO users;
ALTER TABLE devices_v3 RENAME TO devices;
ALTER TABLE sessions_v3 RENAME TO sessions;
ALTER TABLE handshakes_v3 RENAME TO handshakes;
ALTER TABLE device_otps_v3 RENAME TO device_otps;
ALTER TABLE items_v3 RENAME TO items;
ALTER TABLE item_versions_v3 RENAME TO item_versions;
ALTER TABLE change_log_v3 RENAME TO change_log;
ALTER TABLE audit_events_v3 RENAME TO audit_events;

CREATE INDEX idx_sessions_user ON sessions(user_id);
CREATE INDEX idx_versions_item ON item_versions(user_id, item_id);
CREATE INDEX idx_changelog_user_seq ON change_log(user_id, seq);
CREATE INDEX idx_changelog_item ON change_log(user_id, item_id);
CREATE INDEX idx_audit_user ON audit_events(user_id, id);

UPDATE sqlite_sequence SET seq = MAX(seq, COALESCE(
  (SELECT seq FROM vaultone_sequence_v3 WHERE name = sqlite_sequence.name), 0))
WHERE name IN ('item_versions', 'change_log', 'audit_events');
DROP TABLE vaultone_sequence_v3;
