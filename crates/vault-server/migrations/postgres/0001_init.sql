-- VaultOne 同步服务数据库（PostgreSQL 16 版，生产）
-- 零知识：除 email_hash（HMAC）与 email_enc（AES-256-GCM）外不含任何用户可识别信息；
-- vk_wrap / recovery_wrap / items.blob 均为客户端 AES-256-GCM 密封盒密文。

CREATE TABLE users (
  id                  TEXT PRIMARY KEY,
  email_hash          BYTEA NOT NULL UNIQUE,
  email_enc           BYTEA NOT NULL,
  kdf                 TEXT NOT NULL,
  srp_salt            BYTEA NOT NULL,
  srp_verifier        BYTEA NOT NULL,
  vault_id            TEXT NOT NULL,
  vk_wrap             BYTEA NOT NULL,
  vk_gen              BIGINT NOT NULL DEFAULT 1,
  recovery_wrap       BYTEA NOT NULL,
  recovery_auth_hash  BYTEA NOT NULL,
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
  token_hash  BYTEA PRIMARY KEY,
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
  b_enc       BYTEA NOT NULL,
  expires_at  BIGINT NOT NULL
);

CREATE TABLE device_otps (
  user_id     TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  code_hash   BYTEA NOT NULL,
  expires_at  BIGINT NOT NULL,
  attempts    BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, device_id)
);

CREATE TABLE items (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id          TEXT NOT NULL,
  kind        TEXT NOT NULL,
  blob        BYTEA NOT NULL,
  blob_hash   BYTEA NOT NULL,
  revision    BIGINT NOT NULL,
  deleted     BIGINT NOT NULL DEFAULT 0,
  updated_at  BIGINT NOT NULL,
  device_id   TEXT NOT NULL,
  created_at  BIGINT NOT NULL,
  PRIMARY KEY (user_id, id)
);

CREATE TABLE item_versions (
  id          BIGSERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  item_id     TEXT NOT NULL,
  revision    BIGINT NOT NULL,
  blob        BYTEA NOT NULL,
  device_id   TEXT NOT NULL,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_versions_item ON item_versions(user_id, item_id);

CREATE TABLE change_log (
  seq         BIGSERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL,
  item_id     TEXT NOT NULL,
  revision    BIGINT NOT NULL,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_changelog_user_seq ON change_log(user_id, seq);
CREATE INDEX idx_changelog_item ON change_log(user_id, item_id);

CREATE TABLE audit_events (
  id          BIGSERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL,
  device_id   TEXT,
  event       TEXT NOT NULL,
  ip_hash     BYTEA,
  created_at  BIGINT NOT NULL
);
CREATE INDEX idx_audit_user ON audit_events(user_id, id);
