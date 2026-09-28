-- VaultOne 同步服务数据库迁移 0002（SQLite 版，单机/内测）
--
-- 目的：与 Postgres 版一致——把所有时间列由 BIGINT（Unix 秒）改为 TEXT，存 ISO-8601 UTC
--   （如 2026-09-28T08:01:33Z）。
--
-- 实现方式：SQLite 不支持直接改列类型，且「重建表」方式会因 `DROP TABLE users` 触发
--   `ON DELETE CASCADE` 清空 devices/items 等（`PRAGMA foreign_keys=OFF` 在 sqlx 的事务内无效）。
--   故改用**列级迁移**（无需删表、无需关外键）：
--     1) ALTER TABLE ADD COLUMN <列>_iso TEXT；2) 用 strftime 填充；3) DROP COLUMN 旧列；
--     4) RENAME COLUMN <列>_iso TO <列>。
--   注意：列会被移到表末尾，所有查询均按列名取值，不受影响。
-- 说明：SQLite 无 COMMENT 语法，字段用途见各表列名后的注释（本迁移仅改类型，注释见 0001 与本文档）。
--   API 边界仍以 Unix 秒（i64）收发，仅在存取层转换。

PRAGMA foreign_keys = OFF;  -- 仅为稳妥；本迁移不删表，理论无需

-- ═════════════════════ users ═════════════════════

ALTER TABLE users ADD COLUMN created_at_iso TEXT;
ALTER TABLE users ADD COLUMN updated_at_iso TEXT;
UPDATE users SET
  created_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch'),
  updated_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', updated_at, 'unixepoch');
ALTER TABLE users DROP COLUMN created_at;
ALTER TABLE users DROP COLUMN updated_at;
ALTER TABLE users RENAME COLUMN created_at_iso TO created_at;
ALTER TABLE users RENAME COLUMN updated_at_iso TO updated_at;

-- ═════════════════════ devices ═════════════════════

ALTER TABLE devices ADD COLUMN approved_at_iso  TEXT;
ALTER TABLE devices ADD COLUMN last_seen_at_iso TEXT;
ALTER TABLE devices ADD COLUMN revoked_at_iso   TEXT;
ALTER TABLE devices ADD COLUMN created_at_iso   TEXT;
UPDATE devices SET
  approved_at_iso  = CASE WHEN approved_at  IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%SZ', approved_at,  'unixepoch') END,
  last_seen_at_iso = CASE WHEN last_seen_at IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%SZ', last_seen_at, 'unixepoch') END,
  revoked_at_iso   = CASE WHEN revoked_at   IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%SZ', revoked_at,   'unixepoch') END,
  created_at_iso   = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch');
ALTER TABLE devices DROP COLUMN approved_at;
ALTER TABLE devices DROP COLUMN last_seen_at;
ALTER TABLE devices DROP COLUMN revoked_at;
ALTER TABLE devices DROP COLUMN created_at;
ALTER TABLE devices RENAME COLUMN approved_at_iso  TO approved_at;
ALTER TABLE devices RENAME COLUMN last_seen_at_iso TO last_seen_at;
ALTER TABLE devices RENAME COLUMN revoked_at_iso   TO revoked_at;
ALTER TABLE devices RENAME COLUMN created_at_iso   TO created_at;

-- ═════════════════════ sessions ═════════════════════

ALTER TABLE sessions ADD COLUMN expires_at_iso TEXT;
ALTER TABLE sessions ADD COLUMN revoked_at_iso TEXT;
ALTER TABLE sessions ADD COLUMN created_at_iso TEXT;
UPDATE sessions SET
  expires_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', expires_at, 'unixepoch'),
  revoked_at_iso = CASE WHEN revoked_at IS NULL THEN NULL ELSE strftime('%Y-%m-%dT%H:%M:%SZ', revoked_at, 'unixepoch') END,
  created_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch');
ALTER TABLE sessions DROP COLUMN expires_at;
ALTER TABLE sessions DROP COLUMN revoked_at;
ALTER TABLE sessions DROP COLUMN created_at;
ALTER TABLE sessions RENAME COLUMN expires_at_iso TO expires_at;
ALTER TABLE sessions RENAME COLUMN revoked_at_iso TO revoked_at;
ALTER TABLE sessions RENAME COLUMN created_at_iso TO created_at;

-- ═════════════════════ handshakes ═════════════════════

ALTER TABLE handshakes ADD COLUMN expires_at_iso TEXT;
UPDATE handshakes SET expires_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', expires_at, 'unixepoch');
ALTER TABLE handshakes DROP COLUMN expires_at;
ALTER TABLE handshakes RENAME COLUMN expires_at_iso TO expires_at;

-- ═════════════════════ device_otps ═════════════════════

ALTER TABLE device_otps ADD COLUMN expires_at_iso TEXT;
UPDATE device_otps SET expires_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', expires_at, 'unixepoch');
ALTER TABLE device_otps DROP COLUMN expires_at;
ALTER TABLE device_otps RENAME COLUMN expires_at_iso TO expires_at;

-- ═════════════════════ items ═════════════════════

ALTER TABLE items ADD COLUMN updated_at_iso TEXT;
ALTER TABLE items ADD COLUMN created_at_iso TEXT;
UPDATE items SET
  updated_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', updated_at, 'unixepoch'),
  created_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch');
ALTER TABLE items DROP COLUMN updated_at;
ALTER TABLE items DROP COLUMN created_at;
ALTER TABLE items RENAME COLUMN updated_at_iso TO updated_at;
ALTER TABLE items RENAME COLUMN created_at_iso TO created_at;

-- ═════════════════════ item_versions ═════════════════════

ALTER TABLE item_versions ADD COLUMN created_at_iso TEXT;
UPDATE item_versions SET created_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch');
ALTER TABLE item_versions DROP COLUMN created_at;
ALTER TABLE item_versions RENAME COLUMN created_at_iso TO created_at;

-- ═════════════════════ change_log ═════════════════════

ALTER TABLE change_log ADD COLUMN created_at_iso TEXT;
UPDATE change_log SET created_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch');
ALTER TABLE change_log DROP COLUMN created_at;
ALTER TABLE change_log RENAME COLUMN created_at_iso TO created_at;

-- ═════════════════════ audit_events ═════════════════════

ALTER TABLE audit_events ADD COLUMN created_at_iso TEXT;
UPDATE audit_events SET created_at_iso = strftime('%Y-%m-%dT%H:%M:%SZ', created_at, 'unixepoch');
ALTER TABLE audit_events DROP COLUMN created_at;
ALTER TABLE audit_events RENAME COLUMN created_at_iso TO created_at;

PRAGMA foreign_keys = ON;
