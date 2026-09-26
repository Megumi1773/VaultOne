-- VaultOne 同步服务数据库（SQLite 版，单机/内测）
-- 零知识：除 email_hash（HMAC）与 email_enc（AES-256-GCM）外不含任何用户可识别信息；
-- vk_wrap / recovery_wrap / items.blob 均为客户端 AES-256-GCM 密封盒密文。

CREATE TABLE users (
  id                  TEXT PRIMARY KEY,
  email_hash          BLOB NOT NULL UNIQUE,
  email_enc           BLOB NOT NULL,
  kdf                 TEXT NOT NULL,
  srp_salt            BLOB NOT NULL,
  srp_verifier        BLOB NOT NULL,
  vault_id            TEXT NOT NULL,
  vk_wrap             BLOB NOT NULL,
  vk_gen              BIGINT NOT NULL DEFAULT 1,
  recovery_wrap       BLOB NOT NULL,
  recovery_auth_hash  BLOB NOT NULL,
  created_at          BIGINT NOT NULL,
  updated_at          BIGINT NOT NULL
);

CREATE TABLE devices (
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id            TEXT NOT NULL,
  name          TEXT NOT NULL,
  platform      TEXT NOT NULL,
  approved_at   BIGINT,
  approved_by   TEXT,
  last_seen_at  BIGINT,
  revoked_at    BIGINT,
  created_at    BIGINT NOT NULL,
  PRIMARY KEY (user_id, id)
);

CREATE TABLE sessions (
  token_hash  BLOB PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id   TEXT NOT NULL,
  expires_at  BIGINT NOT NULL,
  revoked_at  BIGINT,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_sessions_user ON sessions(user_id);

CREATE TABLE handshakes (
  id          TEXT PRIMARY KEY,
  user_id     TEXT,
  b_enc       BLOB NOT NULL,
  expires_at  BIGINT NOT NULL
);

CREATE TABLE device_otps (
  user_id     TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  code_hash   BLOB NOT NULL,
  expires_at  BIGINT NOT NULL,
  attempts    BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, device_id)
);

CREATE TABLE items (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id          TEXT NOT NULL,
  kind        TEXT NOT NULL,
  blob        BLOB NOT NULL,
  blob_hash   BLOB NOT NULL,
  revision    BIGINT NOT NULL,
  deleted     BIGINT NOT NULL DEFAULT 0,
  updated_at  BIGINT NOT NULL,
  device_id   TEXT NOT NULL,
  created_at  BIGINT NOT NULL,
  PRIMARY KEY (user_id, id)
);

CREATE TABLE item_versions (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  item_id     TEXT NOT NULL,
  revision    BIGINT NOT NULL,
  blob        BLOB NOT NULL,
  device_id   TEXT NOT NULL,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_versions_item ON item_versions(user_id, item_id);

CREATE TABLE change_log (
  seq         INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id     TEXT NOT NULL,
  item_id     TEXT NOT NULL,
  revision    BIGINT NOT NULL,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_changelog_user_seq ON change_log(user_id, seq);
CREATE INDEX idx_changelog_item ON change_log(user_id, item_id);

CREATE TABLE audit_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id     TEXT NOT NULL,
  device_id   TEXT,
  event       TEXT NOT NULL,
  ip_hash     BLOB,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_audit_user ON audit_events(user_id, id);
