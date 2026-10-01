-- 反馈是用户主动提交、客服可读的独立业务数据；不得复制到保险库同步或审计快照。
CREATE TABLE feedback (
  seq BIGSERIAL PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN ('bug', 'suggestion', 'other')),
  content TEXT NOT NULL CHECK (length(content) BETWEEN 1 AND 4000),
  contact TEXT CHECK (length(contact) BETWEEN 1 AND 200),
  status TEXT NOT NULL CHECK (status IN ('open', 'in_progress', 'resolved')),
  reply TEXT CHECK (length(reply) BETWEEN 1 AND 4000),
  version BIGINT NOT NULL CHECK (version > 0),
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL CHECK (expires_at > created_at),
  UNIQUE (user_id, id),
  CHECK (status <> 'resolved' OR reply IS NOT NULL)
);
CREATE INDEX feedback_account_page ON feedback(user_id, seq DESC);
CREATE INDEX feedback_account_created ON feedback(user_id, created_at);
CREATE INDEX feedback_expiry ON feedback(expires_at);
ALTER TABLE feedback ENABLE ROW LEVEL SECURITY;
ALTER TABLE feedback FORCE ROW LEVEL SECURITY;
CREATE POLICY feedback_account ON feedback
  USING (user_id = public.vaultone_current_account())
  WITH CHECK (user_id = public.vaultone_current_account());
CREATE POLICY feedback_maintenance_owner ON feedback
  TO "${migrator_role}" USING (true) WITH CHECK (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON feedback TO "${runtime_role}";
GRANT USAGE, SELECT ON SEQUENCE feedback_seq_seq TO "${runtime_role}";

-- 运行身份只能清理数据库当前时间之前已过期的最多 500 行，不能传入未来截止时间。
CREATE FUNCTION vaultone_purge_expired_feedback() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE removed integer;
BEGIN
  WITH victims AS (
    SELECT seq FROM public.feedback
    WHERE expires_at <= floor(extract(epoch FROM now()))
    ORDER BY expires_at LIMIT 500 FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.feedback f USING victims v WHERE f.seq = v.seq;
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN removed;
END $$;
REVOKE ALL ON FUNCTION vaultone_purge_expired_feedback() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION vaultone_purge_expired_feedback() TO "${runtime_role}";

-- 客服操作者不是用户设备；只增加最小归因元数据，不记录文本。
ALTER TABLE audit_events ADD COLUMN operator_id TEXT;
ALTER TABLE audit_events ADD COLUMN target_id TEXT;
