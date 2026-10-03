-- 通知（计划书 §6）。
--
-- 两张表分开的理由：已读是**每账户**的状态，通知本身是**全局**内容。
-- 把已读塞进 notifications 会导致「一条公告 N 个账户就要 N 行」，改一次文案要改 N 行。
--
-- 时间列统一 BIGINT Unix 秒，与 `audit_events` / `AccountResponse.created_at` 同一约定：
-- 线协议上混用 ISO 字符串与整数秒迟早会让某个客户端解析错（V6 那次已经踩过一次）。
--
-- 不做 Envers、不做二级缓存：通知是内容数据，不是账户状态，没有做修订历史的理由；
-- 而且二级缓存会把同一条广播复制到每个账户的缓存里，纯属浪费。
--
-- **发布路径是运维 SQL**：本迁移只建表，没有后台管理界面，也不加 admin 接口——
-- 在已经跑着用户流量的服务上加一个未鉴权的写入接口是安全风险，加一个带密钥的又要多一份
-- 配置与轮换责任，而通知发布本身是低频人工操作，直接 INSERT 更简单也更可控。

CREATE TABLE notifications (
  id                TEXT PRIMARY KEY,
  -- 广播范围：all = 所有人；account = 仅 account_id 指定的账户。
  audience          TEXT NOT NULL,
  account_id        TEXT,
  -- 类型：announcement / popup / personal / security（对应客户端 NotificationType）。
  kind              TEXT NOT NULL,
  -- 级别：info / important / critical（对应客户端 NotificationLevel）。
  level             TEXT NOT NULL,
  title             TEXT NOT NULL,
  -- 纯文本正文，客户端**不渲染 HTML**，因此这里不做任何转义，原样存原样发。
  body              TEXT NOT NULL,
  action_kind       TEXT NOT NULL DEFAULT 'none',
  action_value      TEXT NOT NULL DEFAULT '',
  action_label      TEXT NOT NULL DEFAULT '',
  -- 弹窗位：startup / home / membership；kind = popup 时有意义。
  popup_slot        TEXT,
  -- 弹窗频率控制（秒）：同一弹窗两次展示的最小间隔；NULL 表示不限制。
  frequency_seconds INTEGER,
  -- 强制确认：true 时弹窗不可直接关闭（客户端读作 mustAck）。
  must_ack          BOOLEAN NOT NULL DEFAULT FALSE,
  published_at      BIGINT NOT NULL,
  -- 过期时间；NULL 表示永不过期。列表与未读统计都按「未过期」过滤。
  expires_at        BIGINT
);

-- 列表查询是 (audience 命中) AND (未过期) ORDER BY published_at DESC, id DESC，
-- 因此索引按同样的列序建，游标翻页才能走到索引而不是全表排序。
CREATE INDEX ix_notifications_published ON notifications (published_at DESC, id DESC);
CREATE INDEX ix_notifications_account ON notifications (account_id, published_at DESC);

CREATE TABLE notification_reads (
  account_id      TEXT NOT NULL,
  notification_id TEXT NOT NULL,
  read_at         BIGINT NOT NULL,
  -- 复合主键：重复标记天然幂等，不需要「先查再写」那一步，也就不存在查写之间的竞态。
  PRIMARY KEY (account_id, notification_id)
);

-- 未读统计要按账户反查，主键前缀已经是 account_id，这个索引只为删除账户时的级联清理服务。
CREATE INDEX ix_notification_reads_notification ON notification_reads (notification_id);
