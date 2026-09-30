-- Java 服务端安全加固：行级安全（RLS）与最小权限引导函数。
--
-- 目的：用户数据表按账户隔离，运行角色非 owner/superuser/BYPASSRLS；未设置账户上下文默认拒绝。
-- 无身份入口（邮箱查找/注册/握手原子领取/恢复）通过 SECURITY DEFINER 函数以最小字段返回，
-- 不整体放开表；函数固定 search_path、只授予运行角色 EXECUTE、禁止任意 SQL。
--
-- 事务内使用：SELECT set_config('vaultone.account_id', $1, true)（第三个参数 true = 事务级，结束即清）。
--
-- 角色：迁移/definer owner 为 ${migrator_role}（非 superuser、非 BYPASSRLS 的库 owner，由部署/测试创建），
-- 业务运行角色为 ${runtime_role}（非 owner、非 superuser、非 BYPASSRLS）。两者均不在此迁移中创建；
-- Flyway placeholder 只引用其已存在名称，且名称经 DeploymentGuard 严格校验。
--
-- search_path 安全：SECURITY DEFINER 函数一律 SET search_path = pg_catalog, pg_temp（pg_temp 置末），
-- 并把所有关系显式限定为 public.*，避免临时关系/可写 schema 抢先解析特权操作。

-- ───────────────────────── 账户上下文读取函数（SECURITY INVOKER）─────────────────────────
-- 只读事务级 GUC；本身不触碰任何表，故无需 DEFINER。策略表达式在创建时即绑定本函数 OID。
CREATE OR REPLACE FUNCTION vaultone_current_account() RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT NULLIF(current_setting('vaultone.account_id', true), '')
$$;

-- ───────────────────────── 启用 RLS（含 FORCE，连表 owner 也受限）─────────────────────────
ALTER TABLE users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE users               FORCE  ROW LEVEL SECURITY;
ALTER TABLE devices             ENABLE ROW LEVEL SECURITY;
ALTER TABLE devices             FORCE  ROW LEVEL SECURITY;
ALTER TABLE items               ENABLE ROW LEVEL SECURITY;
ALTER TABLE items               FORCE  ROW LEVEL SECURITY;
ALTER TABLE item_versions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE item_versions       FORCE  ROW LEVEL SECURITY;
ALTER TABLE change_log          ENABLE ROW LEVEL SECURITY;
ALTER TABLE change_log          FORCE  ROW LEVEL SECURITY;
ALTER TABLE device_otps         ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_otps         FORCE  ROW LEVEL SECURITY;
ALTER TABLE audit_events        ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events        FORCE  ROW LEVEL SECURITY;
ALTER TABLE handshakes          ENABLE ROW LEVEL SECURITY;
ALTER TABLE handshakes          FORCE  ROW LEVEL SECURITY;
ALTER TABLE session_revocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_revocations FORCE  ROW LEVEL SECURITY;

-- 账户范围策略：user_id 必须等于事务级账户上下文；无上下文时所有行都不满足（默认拒绝）。
CREATE POLICY users_account_isolation ON public.users
  USING (id = vaultone_current_account())
  WITH CHECK (id = vaultone_current_account());

CREATE POLICY devices_account_isolation ON public.devices
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

CREATE POLICY items_account_isolation ON public.items
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

CREATE POLICY item_versions_account_isolation ON public.item_versions
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

CREATE POLICY change_log_account_isolation ON public.change_log
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

CREATE POLICY device_otps_account_isolation ON public.device_otps
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

CREATE POLICY audit_events_account_isolation ON public.audit_events
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

CREATE POLICY session_revocations_account_isolation ON public.session_revocations
  USING (user_id = vaultone_current_account())
  WITH CHECK (user_id = vaultone_current_account());

-- ───────────────────────── 迁移/definer owner 角色专属策略（基于角色，非可 SET 的 GUC）─────────────────────────
-- SECURITY DEFINER 函数的 owner 是 migrator；FORCE RLS 对 owner 同样生效，故显式放行该角色本身。
-- 运行角色不在此列：它没有这些策略，故无上下文时仍被默认拒绝。
CREATE POLICY users_definer_owner ON public.users
  TO "${migrator_role}" USING (true) WITH CHECK (true);

CREATE POLICY devices_definer_owner ON public.devices
  TO "${migrator_role}" USING (true) WITH CHECK (true);

-- handshakes 仅在无身份阶段经 SECURITY DEFINER 函数访问；运行角色不授予直接表权限，
-- 因此这里只给 definer owner 策略，不给任何公开/账户策略，避免无上下文读取 decoy 行。
CREATE POLICY handshakes_definer_owner ON public.handshakes
  TO "${migrator_role}" USING (true) WITH CHECK (true);

-- ───────────────────────── 无身份引导函数（SECURITY DEFINER，最小返回字段）─────────────────────────

-- 邮箱 HMAC 是否已注册。
CREATE OR REPLACE FUNCTION vaultone_email_exists(p_email_hash bytea)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE email_hash = p_email_hash)
$$;

-- 按邮箱 HMAC 取账户 ID（登录/恢复引导）。
CREATE OR REPLACE FUNCTION vaultone_lookup_account_id(p_email_hash bytea)
RETURNS text
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT id FROM public.users WHERE email_hash = p_email_hash LIMIT 1
$$;

-- 注册：账户 + 首台已批准设备原子插入（仅 INSERT，不 UPDATE/MERGE，不复活撤销状态）。
CREATE OR REPLACE FUNCTION vaultone_register_account(
  p_id text, p_email_hash bytea, p_email_enc bytea, p_kdf text,
  p_srp_salt bytea, p_srp_verifier bytea, p_vault_id text,
  p_vk_wrap bytea, p_vk_gen bigint, p_recovery_wrap bytea, p_recovery_auth_hash bytea,
  p_device_id text, p_device_name text, p_device_platform text, p_now text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  INSERT INTO public.users(id, email_hash, email_enc, kdf, srp_salt, srp_verifier, vault_id,
                           vk_wrap, vk_gen, recovery_wrap, recovery_auth_hash, session_epoch,
                           created_at, updated_at)
  VALUES (p_id, p_email_hash, p_email_enc, p_kdf, p_srp_salt, p_srp_verifier, p_vault_id,
          p_vk_wrap, GREATEST(p_vk_gen, 1), p_recovery_wrap, p_recovery_auth_hash, 1, p_now, p_now);
  INSERT INTO public.devices(user_id, id, name, platform, approved_at, approved_by, last_seen_at,
                             revoked_at, epoch, created_at)
  VALUES (p_id, p_device_id, p_device_name, p_device_platform, p_now, 'registration', p_now,
          NULL, 1, p_now);
END $$;

-- 握手写入（user_id 可为 null，表示未注册邮箱的 decoy 握手）。
CREATE OR REPLACE FUNCTION vaultone_insert_handshake(p_id text, p_user_id text, p_b_enc bytea, p_expires_at text)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  INSERT INTO public.handshakes(id, user_id, b_enc, expires_at)
  VALUES (p_id, p_user_id, p_b_enc, p_expires_at)
$$;

-- 握手原子领取：DELETE ... RETURNING，一条语句完成读取与删除，错误 proof 不会复活握手。
CREATE OR REPLACE FUNCTION vaultone_claim_handshake(p_id text)
RETURNS TABLE(user_id text, b_enc bytea, expires_at text)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  DELETE FROM public.handshakes WHERE id = p_id
  RETURNING user_id, b_enc, expires_at
$$;

-- 清理过期握手（维护路径，无账户上下文）：有界批量 + 服务端当前 UTC 上界。
-- - p_now 若晚于数据库当前 UTC，则以数据库时间为上界，避免传入未来阈值删除有效挑战；
-- - 单次最多删除 500 行并用 SKIP LOCKED，避免全表长事务/与并发领取互锁。
CREATE OR REPLACE FUNCTION vaultone_purge_expired_handshakes(p_now text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  cutoff text;
  deleted integer;
BEGIN
  cutoff := LEAST(p_now, to_char((now() AT TIME ZONE 'UTC'), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  WITH victims AS (
    SELECT id FROM public.handshakes
    WHERE expires_at < cutoff
    ORDER BY expires_at
    LIMIT 500
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.handshakes h USING victims v WHERE h.id = v.id;
  GET DIAGNOSTICS deleted = ROW_COUNT;
  RETURN deleted;
END $$;

-- 恢复引导：按邮箱取账户 ID 与恢复校验哈希（仅恢复流程使用）。
CREATE OR REPLACE FUNCTION vaultone_recovery_lookup(p_email_hash bytea)
RETURNS TABLE(id text, recovery_auth_hash bytea)
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
  SELECT u.id, u.recovery_auth_hash FROM public.users u WHERE u.email_hash = p_email_hash LIMIT 1
$$;

-- 恢复完成：锁账户 + 重验旧恢复凭据快照 + 轮换材料 + 重建当前设备；仅唯一胜者返回 true。
-- 旧恢复凭据以 SHA-256(provided) 与库中 recovery_auth_hash 常量比较（服务端不存原文）。
CREATE OR REPLACE FUNCTION vaultone_recovery_complete(
  p_id text, p_expect_recovery_auth_hash bytea, p_expect_session_epoch bigint, p_expect_vk_gen bigint,
  p_kdf text, p_srp_salt bytea, p_srp_verifier bytea, p_vk_wrap bytea,
  p_recovery_wrap bytea, p_recovery_auth_hash bytea,
  p_device_id text, p_device_name text, p_device_platform text, p_now text)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  updated int;
BEGIN
  -- 账户行锁：并发恢复串行化，只有第一个匹配旧快照的事务能 CAS 成功。
  PERFORM 1 FROM public.users WHERE id = p_id FOR UPDATE;
  UPDATE public.users SET
    kdf = p_kdf,
    srp_salt = p_srp_salt,
    srp_verifier = p_srp_verifier,
    vk_wrap = p_vk_wrap,
    vk_gen = p_expect_vk_gen + 1,
    recovery_wrap = p_recovery_wrap,
    recovery_auth_hash = p_recovery_auth_hash,
    session_epoch = p_expect_session_epoch + 1,
    updated_at = p_now
  WHERE id = p_id
    AND recovery_auth_hash = p_expect_recovery_auth_hash
    AND session_epoch = p_expect_session_epoch
    AND vk_gen = p_expect_vk_gen;
  GET DIAGNOSTICS updated = ROW_COUNT;
  IF updated <> 1 THEN
    RETURN false;
  END IF;

  -- 当前设备重建为已批准（保留其他设备记录，交由 session_epoch 失效旧会话）。
  DELETE FROM public.devices WHERE user_id = p_id AND id = p_device_id;
  INSERT INTO public.devices(user_id, id, name, platform, approved_at, approved_by, last_seen_at,
                             revoked_at, epoch, created_at)
  VALUES (p_id, p_device_id, p_device_name, p_device_platform, p_now, 'recovery-kit', p_now,
          NULL, 1, p_now);
  RETURN true;
END $$;

-- ───────────────────────── 最小权限授予 ─────────────────────────
-- 运行角色：只能 CRUD 受 RLS 约束的业务表，并调用上述引导函数；不得执行任意 DDL。
-- handshakes 不在其列：运行角色对握手表无直接权限，访问一律经窄函数。
GRANT USAGE ON SCHEMA public TO "${runtime_role}";
GRANT SELECT, INSERT, UPDATE, DELETE ON
  users, devices, items, item_versions, change_log, device_otps, audit_events,
  session_revocations
  TO "${runtime_role}";
GRANT USAGE, SELECT ON SEQUENCE
  item_versions_id_seq, change_log_seq_seq, audit_events_id_seq
  TO "${runtime_role}";

REVOKE ALL ON FUNCTION vaultone_email_exists(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_lookup_account_id(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_register_account(text,bytea,bytea,text,bytea,bytea,text,bytea,bigint,bytea,bytea,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_insert_handshake(text,text,bytea,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_claim_handshake(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_purge_expired_handshakes(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_recovery_lookup(bytea) FROM PUBLIC;
REVOKE ALL ON FUNCTION vaultone_recovery_complete(text,bytea,bigint,bigint,text,bytea,bytea,bytea,bytea,bytea,text,text,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION vaultone_email_exists(bytea) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_lookup_account_id(bytea) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_register_account(text,bytea,bytea,text,bytea,bytea,text,bytea,bigint,bytea,bytea,text,text,text,text) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_insert_handshake(text,text,bytea,text) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_claim_handshake(text) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_purge_expired_handshakes(text) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_recovery_lookup(bytea) TO "${runtime_role}";
GRANT EXECUTE ON FUNCTION vaultone_recovery_complete(text,bytea,bigint,bigint,text,bytea,bytea,bytea,bytea,bytea,text,text,text,text) TO "${runtime_role}";
