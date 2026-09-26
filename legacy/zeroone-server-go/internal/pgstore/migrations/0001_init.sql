-- ZeroOne 服务端 schema v1（计划书 §4.1）
-- 原则：服务端只保存密文与非敏感元数据；以下每个 BYTEA 字段要么是密文，要么是不可逆哈希。

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email_enc       BYTEA NOT NULL,                 -- 邮箱（应用层 AES-GCM 加密，仅用于发送告警）
  email_hash      BYTEA NOT NULL UNIQUE,          -- HMAC-SHA256(规范化邮箱, 服务端密钥)
  kdf_params      JSONB NOT NULL,                 -- {"alg":"argon2id","m":65536,"t":3,"p":4,"salt":"b64"}
  srp_verifier    BYTEA NOT NULL,                 -- SRP-6a verifier，不可逆
  srp_salt        BYTEA NOT NULL,
  mfa_type        TEXT,
  mfa_secret_enc  BYTEA,
  status          TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'locked', 'deleted')),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE devices (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  platform      TEXT NOT NULL CHECK (platform IN ('windows', 'macos', 'linux', 'ios', 'android', 'extension')),
  pub_key       BYTEA NOT NULL,
  approved_by   UUID,
  approved_at   TIMESTAMPTZ,
  last_seen_at  TIMESTAMPTZ,
  revoked_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_devices_user ON devices(user_id);

CREATE TABLE vaults (
  id            UUID PRIMARY KEY,
  owner_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL DEFAULT 'personal' CHECK (kind IN ('personal', 'shared')),
  name_enc      BYTEA NOT NULL,
  vk_wrap       BYTEA NOT NULL,
  vk_gen        INT NOT NULL DEFAULT 1,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_vaults_owner ON vaults(owner_id);

CREATE TABLE items (
  id            UUID PRIMARY KEY,
  vault_id      UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('login', 'card', 'note', 'identity')),
  blob          BYTEA NOT NULL,                  -- 条目密文信封
  blob_bytes    INT NOT NULL,
  blob_sha256   BYTEA NOT NULL,                  -- 密文摘要，用于幂等重放判定
  revision      BIGINT NOT NULL,
  device_id     UUID NOT NULL,
  deleted_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_items_vault_rev ON items(vault_id, revision);

CREATE TABLE change_log (
  seq         BIGSERIAL PRIMARY KEY,
  user_id     UUID NOT NULL,
  vault_id    UUID NOT NULL,
  entity      TEXT NOT NULL,
  entity_id   UUID NOT NULL,
  op          TEXT NOT NULL CHECK (op IN ('upsert', 'delete')),
  revision    BIGINT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_changelog_user_seq ON change_log(user_id, seq);

CREATE TABLE item_versions (
  id          BIGSERIAL PRIMARY KEY,
  item_id     UUID NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  revision    BIGINT NOT NULL,
  blob        BYTEA NOT NULL,
  device_id   UUID NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_item_versions_item ON item_versions(item_id, revision);

CREATE TABLE sessions (
  id           UUID PRIMARY KEY,
  user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id    UUID NOT NULL,
  token_hash   BYTEA NOT NULL UNIQUE,
  expires_at   TIMESTAMPTZ NOT NULL,
  ip_hash      BYTEA,
  revoked_at   TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_sessions_user ON sessions(user_id);

CREATE TABLE recovery_kits (
  user_id       UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  vk_wrap_enc   BYTEA NOT NULL,                  -- 被 Recovery Code 派生密钥封装的 Vault Key
  auth_hash     BYTEA NOT NULL,                  -- SHA-256(恢复码派生的认证值)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  used_at       TIMESTAMPTZ
);

CREATE TABLE audit_events (
  id          BIGSERIAL PRIMARY KEY,
  user_id     UUID NOT NULL,
  device_id   UUID,
  event       TEXT NOT NULL,
  ip_hash     BYTEA,
  ua_hash     BYTEA,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_user ON audit_events(user_id, id DESC);
