-- VaultOne 同步服务数据库迁移 0002（PostgreSQL 16 版）
--
-- 目的：
--   1) 将所有时间列由 BIGINT（Unix 秒时间戳）改为 TEXT，统一存放 ISO-8601 UTC 字符串
--      （形如 2026-09-28T08:01:33Z），便于直接用 psql 阅读与跨库一致（SQLite 同一套写法）。
--   2) 为全部表、全部字段补齐 COMMENT，说明用途与用法。
--
-- 说明：本项目使用 sqlx Any 驱动，同一套代码同时支持 SQLite / PostgreSQL，
--   而 Any 驱动不支持任何原生时间类型，故用 ISO-8601 UTC 文本（字典序 = 时间序，可直接比较/排序）。
--   API 边界仍以 Unix 秒（i64）收发，仅在存取层做转换。

-- ───────────────────────── users ─────────────────────────

ALTER TABLE users
  ALTER COLUMN created_at TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN updated_at TYPE TEXT USING to_char(to_timestamp(updated_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  users                     IS '账户主表：一行一个账户。服务端零知识，只保存公开参数与客户端密封盒密文。';
COMMENT ON COLUMN users.id                  IS '账户 ID（UUID 文本），主键；所有其他表以 user_id 关联。';
COMMENT ON COLUMN users.email_hash           IS '邮箱的 HMAC-SHA256 索引（服务器主密钥派生），用于唯一性与登录查找；不可逆，无法反推邮箱。';
COMMENT ON COLUMN users.email_enc            IS '邮箱的 AES-256-GCM 密文（服务器主密钥加密），仅用于向用户展示与发送邮件。';
COMMENT ON COLUMN users.kdf                  IS '客户端 KDF 参数（JSON：算法/内存/迭代/并行度），登录时下发给客户端复算派生密钥。';
COMMENT ON COLUMN users.srp_salt             IS 'SRP-6a 盐值（随机字节），登录握手用。';
COMMENT ON COLUMN users.srp_verifier         IS 'SRP-6a 验证子 v = g^x mod N（由 256-bit AuthKey 计算）；服务器仅凭它验证主密码，不可离线爆破。';
COMMENT ON COLUMN users.vault_id             IS '保险库 ID（UUID 文本），多账户下区分保险库数据空间。';
COMMENT ON COLUMN users.vk_wrap              IS 'Vault Key 被 WrapKey 封装后的密封盒密文；服务器无法解密。';
COMMENT ON COLUMN users.vk_gen               IS 'Vault Key 封装代次：每次改主密码或恢复即 +1，客户端据此判断封装是否过期。';
COMMENT ON COLUMN users.recovery_wrap        IS 'Vault Key 被 Recovery Code 派生密钥封装后的密封盒密文，用于全设备丢失时恢复。';
COMMENT ON COLUMN users.recovery_auth_hash   IS 'SHA-256(RecoveryCode 派生的 auth token)，恢复流程的凭据校验；不可逆。';
COMMENT ON COLUMN users.created_at           IS '账户创建时间，ISO-8601 UTC 文本（如 2026-09-28T08:01:33Z）。';
COMMENT ON COLUMN users.updated_at           IS '账户最近更新时间（改密/恢复等），ISO-8601 UTC 文本。';

-- ───────────────────────── devices ─────────────────────────

ALTER TABLE devices
  ALTER COLUMN approved_at  TYPE TEXT USING to_char(to_timestamp(approved_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN last_seen_at TYPE TEXT USING to_char(to_timestamp(last_seen_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN revoked_at   TYPE TEXT USING to_char(to_timestamp(revoked_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN created_at   TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  devices                    IS '设备表：记录每台登录过的设备及其批准/撤销状态；复合主键 (user_id, id)。';
COMMENT ON COLUMN devices.user_id            IS '所属账户 ID，外键 users(id) ON DELETE CASCADE。';
COMMENT ON COLUMN devices.id                 IS '设备 ID（UUID 文本），客户端生成，与 user_id 组成主键。';
COMMENT ON COLUMN devices.name               IS '设备名称（用户可见，如「我的手机」），可被设备重命名。';
COMMENT ON COLUMN devices.platform           IS '平台标识（android/ios/windows/macos/linux/extension），用于展示与策略。';
COMMENT ON COLUMN devices.approved_at        IS '设备被批准的时间（ISO-8601 UTC）；NULL 表示尚未批准，只能轮询等待。';
COMMENT ON COLUMN devices.approved_by        IS '批准该设备的设备 ID；空表示由邮件验证码批准。';
COMMENT ON COLUMN devices.last_seen_at       IS '最近活跃时间（ISO-8601 UTC），由认证中间件每小时最多更新一次。';
COMMENT ON COLUMN devices.revoked_at         IS '设备被撤销的时间（ISO-8601 UTC）；非空即拒绝其所有会话。';
COMMENT ON COLUMN devices.created_at         IS '设备首次登记时间（ISO-8601 UTC）。';

-- ───────────────────────── sessions ─────────────────────────

ALTER TABLE sessions
  ALTER COLUMN expires_at TYPE TEXT USING to_char(to_timestamp(expires_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN revoked_at TYPE TEXT USING to_char(to_timestamp(revoked_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN created_at TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  sessions                   IS '会话表：Bearer token 只存 SHA-256 哈希；支持滑动续期与撤销。';
COMMENT ON COLUMN sessions.token_hash        IS 'token 的 SHA-256 哈希（主键）；服务端不保存明文 token。';
COMMENT ON COLUMN sessions.user_id           IS '所属账户 ID，外键 users(id) ON DELETE CASCADE。';
COMMENT ON COLUMN sessions.device_id         IS '签发该会话的设备 ID，与 devices(user_id, id) 对应。';
COMMENT ON COLUMN sessions.expires_at        IS '会话过期时间（ISO-8601 UTC）；每次请求接近过期时滑动续期。';
COMMENT ON COLUMN sessions.revoked_at        IS '会话被撤销时间（ISO-8601 UTC）；登出或改密时写入。';
COMMENT ON COLUMN sessions.created_at        IS '会话创建时间（ISO-8601 UTC）。';

-- ───────────────────────── handshakes ─────────────────────────

ALTER TABLE handshakes
  ALTER COLUMN expires_at TYPE TEXT USING to_char(to_timestamp(expires_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  handshakes                 IS 'SRP-6a 登录握手临时状态：服务端临时保存加密的 b（含实际 b 与派生材料），握手完成或过期即删。';
COMMENT ON COLUMN handshakes.id              IS '握手 ID（UUID 文本），登录 start 下发、finish 回传，主键。';
COMMENT ON COLUMN handshakes.user_id         IS '目标账户 ID；登录 start 时已知，注册类握手可为空。';
COMMENT ON COLUMN handshakes.b_enc           IS '服务端临时私钥 b 的 AES-256-GCM 密文（服务器主密钥加密），防明文落库。';
COMMENT ON COLUMN handshakes.expires_at      IS '握手过期时间（ISO-8601 UTC）；过期由 GC 清理，登录时也会校验。';

-- ───────────────────────── device_otps ─────────────────────────

ALTER TABLE device_otps
  ALTER COLUMN expires_at TYPE TEXT USING to_char(to_timestamp(expires_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  device_otps                IS '新设备验证码：邮件下发的一次性码，只存哈希与尝试次数；复合主键 (user_id, device_id)。';
COMMENT ON COLUMN device_otps.user_id        IS '所属账户 ID。';
COMMENT ON COLUMN device_otps.device_id      IS '待验证的设备 ID。';
COMMENT ON COLUMN device_otps.code_hash      IS '验证码的哈希（不可逆）；校验时比对，不存明文。';
COMMENT ON COLUMN device_otps.expires_at     IS '验证码过期时间（ISO-8601 UTC）。';
COMMENT ON COLUMN device_otps.attempts       IS '已尝试次数；超过上限即作废，防暴力猜码。';

-- ───────────────────────── items ─────────────────────────

ALTER TABLE items
  ALTER COLUMN updated_at TYPE TEXT USING to_char(to_timestamp(updated_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  ALTER COLUMN created_at TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  items                      IS '条目表（保险库条目）：一行一个条目的最新版本；blob 为客户端密封盒密文，服务器只做冲突检测与存储。';
COMMENT ON COLUMN items.user_id              IS '所属账户 ID，外键 users(id) ON DELETE CASCADE。';
COMMENT ON COLUMN items.id                   IS '条目 ID（UUID 文本），客户端生成，与 user_id 组成主键。';
COMMENT ON COLUMN items.kind                 IS '条目类型（login/card/note/identity），非敏感，供客户端过滤；不泄露内容。';
COMMENT ON COLUMN items.blob                 IS '条目内容的客户端 AES-256-GCM 密封盒密文（含版本号作为 AAD）。';
COMMENT ON COLUMN items.blob_hash            IS 'blob 的 SHA-256，用于快速判等与完整性校验。';
COMMENT ON COLUMN items.revision             IS '服务端版本号（每次成功写入递增），用于乐观锁与冲突检测。';
COMMENT ON COLUMN items.deleted              IS '软删除标记（0 正常 / 1 已删除），删除也参与同步以免复活。';
COMMENT ON COLUMN items.updated_at           IS '条目最后更新时间（ISO-8601 UTC），客户端据此做三方合并。';
COMMENT ON COLUMN items.device_id            IS '最后写入该条目的设备 ID，用于冲突提示与审计。';
COMMENT ON COLUMN items.created_at           IS '条目首次创建时间（ISO-8601 UTC）。';

-- ───────────────────────── item_versions ─────────────────────────

ALTER TABLE item_versions
  ALTER COLUMN created_at TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  item_versions              IS '条目历史版本：每次写入保留一份旧 blob，按保留期（version_retention_days）GC。';
COMMENT ON COLUMN item_versions.id           IS '自增主键，仅用于排序与 GC。';
COMMENT ON COLUMN item_versions.user_id      IS '所属账户 ID，外键 users(id) ON DELETE CASCADE。';
COMMENT ON COLUMN item_versions.item_id      IS '对应的条目 ID（关联 items.id）。';
COMMENT ON COLUMN item_versions.revision     IS '该历史版本对应的 revision 号。';
COMMENT ON COLUMN item_versions.blob         IS '该历史版本的条目密封盒密文。';
COMMENT ON COLUMN item_versions.device_id    IS '写入该版本的设备 ID。';
COMMENT ON COLUMN item_versions.created_at   IS '该版本写入时间（ISO-8601 UTC），GC 依据此字段。';

-- ───────────────────────── change_log ─────────────────────────

ALTER TABLE change_log
  ALTER COLUMN created_at TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  change_log                 IS '增量变更日志：每次条目写入追加一条，客户端按 seq 游标增量拉取。';
COMMENT ON COLUMN change_log.seq             IS '全局自增序号，即同步游标（cursor）。';
COMMENT ON COLUMN change_log.user_id         IS '所属账户 ID（用于按账户过滤）。';
COMMENT ON COLUMN change_log.item_id         IS '发生变更的条目 ID。';
COMMENT ON COLUMN change_log.revision        IS '变更后的版本号。';
COMMENT ON COLUMN change_log.created_at      IS '变更时间（ISO-8601 UTC）。';

-- ───────────────────────── audit_events ─────────────────────────

ALTER TABLE audit_events
  ALTER COLUMN created_at TYPE TEXT USING to_char(to_timestamp(created_at), 'YYYY-MM-DD"T"HH24:MI:SS"Z"');

COMMENT ON TABLE  audit_events               IS '安全审计事件：登录、审批、撤销、改密等，供安全日志页展示与异常告警统计。';
COMMENT ON COLUMN audit_events.id            IS '自增主键，仅用于倒序分页。';
COMMENT ON COLUMN audit_events.user_id       IS '所属账户 ID。';
COMMENT ON COLUMN audit_events.device_id     IS '事件来源设备 ID；系统级事件可为空。';
COMMENT ON COLUMN audit_events.event         IS '事件类型标识（如 login、device_approved、password_changed）。';
COMMENT ON COLUMN audit_events.ip_hash       IS '客户端 IP 的不可逆 HMAC（不可反查），用于异常登录统计。';
COMMENT ON COLUMN audit_events.created_at    IS '事件时间（ISO-8601 UTC）。';
