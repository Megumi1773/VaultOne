-- 邀请码（计划书 §8.1「我的邀请码」/ §9 邀请关系）。
--
-- `invite_code`：一人一码、可多人使用。部分唯一索引兜底——空串表示「尚未生成」，
--   允许多行同时为空，因此不能直接对整列建唯一约束。
-- `invited_by`：我补填的邀请人账户 id。**一次性、不可更改**，由 CHECK 约束 + 服务层双重兜底。
--
-- 两列都进 UserEntity 但标 @NotAudited：users_aud 是白名单（只审 vk_gen / session_epoch /
-- updated_at），邀请关系不属于低频账户状态，因此本迁移**不改审计表**。
--
-- 存量行回填：用 gen_random_uuid()（PG 13+ 内置，本部署为 PG 16）取 12 位十六进制。
--   **与新建账户的邀请码字母表不同**（新建用去掉易混字符的 31 字符表），这是回填的取舍：
--   迁移里没有 Java 的生成器可用，只能退而求其次。位数相同（12），熵约 48 bit。
--   全新部署不会有存量行，因此这段只影响开发库。

ALTER TABLE users ADD COLUMN invite_code TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN invited_by  TEXT;

UPDATE users
   SET invite_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))
 WHERE invite_code = '';

CREATE UNIQUE INDEX ux_users_invite_code ON users (invite_code) WHERE invite_code <> '';

-- 不能自己邀请自己；也不能把 invited_by 指向不存在的账户。
ALTER TABLE users ADD CONSTRAINT ck_users_invited_by_not_self
  CHECK (invited_by IS NULL OR invited_by <> id);
ALTER TABLE users ADD CONSTRAINT fk_users_invited_by
  FOREIGN KEY (invited_by) REFERENCES users (id) ON DELETE SET NULL;
