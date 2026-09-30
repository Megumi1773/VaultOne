-- Java 服务端业务 schema（Flyway 独立历史 vaultone_java_schema_history）。
--
-- 对齐 20f4f3d 后 Rust schema（crates/vault-server/migrations/postgres）：TEXT ID、TEXT 时间（ISO-8601 UTC，
-- 字典序即时间序）、BYTEA 原字节、BIGINT 整型字段。Java 侧额外引入独立会话失效代次 users.session_epoch
-- 与 devices.epoch（不复用 vk_gen，普通改密不强制退出）。
--
-- 零知识：服务端只保存公开参数与客户端密封盒密文，绝不见明文/主密钥/Secret Key。

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
  session_epoch       BIGINT NOT NULL DEFAULT 1,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL
);

CREATE TABLE devices (
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id            TEXT NOT NULL,
  name          TEXT NOT NULL,
  platform      TEXT NOT NULL,
  approved_at   TEXT,
  approved_by   TEXT,
  last_seen_at  TEXT,
  revoked_at    TEXT,
  epoch         BIGINT NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL,
  PRIMARY KEY (user_id, id)
);
CREATE INDEX idx_devices_user ON devices(user_id);

CREATE TABLE handshakes (
  id          TEXT PRIMARY KEY,
  -- 可空：未注册邮箱的 decoy 握手 user_id 为 NULL（FK 允许 NULL）；已注册账户的握手随账户删除级联清理。
  user_id     TEXT REFERENCES users(id) ON DELETE CASCADE,
  b_enc       BYTEA NOT NULL,
  expires_at  TEXT NOT NULL
);
CREATE INDEX idx_handshakes_expires ON handshakes(expires_at);
CREATE INDEX idx_handshakes_user ON handshakes(user_id);

CREATE TABLE device_otps (
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id   TEXT NOT NULL,
  code_hash   BYTEA NOT NULL,
  expires_at  TEXT NOT NULL,
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
  updated_at  TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  PRIMARY KEY (user_id, id)
);

CREATE TABLE item_versions (
  id          BIGSERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  item_id     TEXT NOT NULL,
  revision    BIGINT NOT NULL,
  blob        BYTEA NOT NULL,
  device_id   TEXT NOT NULL,
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_versions_item ON item_versions(user_id, item_id);

CREATE TABLE change_log (
  seq         BIGSERIAL PRIMARY KEY,
  user_id     TEXT NOT NULL,
  item_id     TEXT NOT NULL,
  revision    BIGINT NOT NULL,
  created_at  TEXT NOT NULL
);
CREATE INDEX idx_changelog_user_seq ON change_log(user_id, seq);
CREATE INDEX idx_changelog_item ON change_log(user_id, item_id);

CREATE TABLE audit_events (
  id             BIGSERIAL PRIMARY KEY,
  user_id        TEXT NOT NULL,
  device_id      TEXT,
  event          TEXT NOT NULL,
  severity       TEXT NOT NULL,
  outcome        TEXT NOT NULL,
  request_id     TEXT,
  ip_hash        BYTEA,
  created_at     TEXT NOT NULL
);
CREATE INDEX idx_audit_user ON audit_events(user_id, id DESC);

-- 会话撤销标记（共享接口）：logout 只删除 Redis 键不足以抵御旧 Redis 快照复活，
-- 故持久化 token 摘要；授权时与 Redis 元数据一并校验。只存摘要文本，不存 token 原文。
CREATE TABLE session_revocations (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  PRIMARY KEY (user_id, token_hash)
);
CREATE INDEX idx_session_revocations_expires ON session_revocations(expires_at);
