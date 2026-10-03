package app.vaultone.server.notify.model;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.Instant;

/**
 * 一条通知（计划书 §6.1）。不启用 Envers 或二级缓存。
 *
 * <p>已读状态不在这里——那是每账户各自的，见 {@link NotificationReadEntity}。把已读塞进本表会让 一条广播在 N 个账户下变成 N 行。
 *
 * <p>发布路径是运维 SQL，因此本实体没有给运行时用的写入口：服务端自己从不写这张表。 见 {@link #publish} 的注释。
 */
@Entity
@Table(name = "notifications")
public class NotificationEntity {
  @Id private String id;

  /** 广播范围：`all` = 所有人；`account` = 仅 {@link #accountId} 指定的账户。 */
  @Column(nullable = false)
  private String audience;

  @Column(name = "account_id")
  private String accountId;

  /** 类型：announcement / popup / personal / security。 */
  @Column(nullable = false)
  private String kind;

  /** 级别：info / important / critical。 */
  @Column(nullable = false)
  private String level;

  @Column(nullable = false)
  private String title;

  /** 纯文本正文，客户端不渲染 HTML。 */
  @Column(nullable = false)
  private String body;

  @Column(name = "action_kind", nullable = false)
  private String actionKind;

  @Column(name = "action_value", nullable = false)
  private String actionValue;

  @Column(name = "action_label", nullable = false)
  private String actionLabel;

  /** 弹窗位：startup / home / membership；`kind = popup` 时有意义。 */
  @Column(name = "popup_slot")
  private String popupSlot;

  /** 弹窗频率控制（秒）；null 表示不限制。 */
  @Column(name = "frequency_seconds")
  private Integer frequencySeconds;

  @Column(name = "must_ack", nullable = false)
  private boolean mustAck;

  @Column(name = "published_at", nullable = false)
  private long publishedAt;

  /** 过期时间；null 表示永不过期。 */
  @Column(name = "expires_at")
  private Long expiresAt;

  protected NotificationEntity() {}

  public String getId() {
    return id;
  }

  public String getAudience() {
    return audience;
  }

  public String getAccountId() {
    return accountId;
  }

  public String getKind() {
    return kind;
  }

  public String getLevel() {
    return level;
  }

  public String getTitle() {
    return title;
  }

  public String getBody() {
    return body;
  }

  public String getActionKind() {
    return actionKind;
  }

  public String getActionValue() {
    return actionValue;
  }

  public String getActionLabel() {
    return actionLabel;
  }

  public String getPopupSlot() {
    return popupSlot;
  }

  public Integer getFrequencySeconds() {
    return frequencySeconds;
  }

  public boolean isMustAck() {
    return mustAck;
  }

  public long getPublishedAt() {
    return publishedAt;
  }

  public Long getExpiresAt() {
    return expiresAt;
  }

  /** 在 `now` 时刻是否已过期。无过期时间即永不过期。 */
  public boolean isExpiredAt(long now) {
    return expiresAt != null && expiresAt <= now;
  }

  /** 当前是否对该账户可见。 */
  public boolean isVisibleTo(String viewerId) {
    return "all".equals(audience) || (accountId != null && accountId.equals(viewerId));
  }

  /**
   * 派生的稳定排序键，用于游标翻页。
   *
   * <p>只按 `published_at` 排序会在同一秒内产生并列，翻页时可能漏掉或重复；带上 id 就变成全序。
   */
  public String sortKey() {
    return publishedAt + "|" + id;
  }

  @Override
  public String toString() {
    // 不输出标题与正文：通知内容可能带运营文案，整行进日志没有收益。
    return "NotificationEntity[id=" + id + ", kind=" + kind + ", level=" + level + "]";
  }

  /**
   * 构造一条通知。**服务端运行时不调用它**——发布路径是运维 SQL，见迁移头注释。
   *
   * <p>留着它是因为测试必须能造数据，而把测试用的构造逻辑写在测试里，就等于测试自己定义了 「一条合法通知长什么样」，那和实现走偏时没人能发现。让实现提供唯一的构造入口更好。
   *
   * <p>参数与表列一一对应，因此很长——这是「表行长这样」的直接表达，拆成 builder 只是把同一份 信息换个地方写，还会让「哪个参数对应哪列」变得不明显。
   */
  public static NotificationEntity publish(
      String id,
      String audience,
      String accountId,
      String kind,
      String level,
      String title,
      String body,
      String actionKind,
      String actionValue,
      String actionLabel,
      String popupSlot,
      Integer frequencySeconds,
      boolean mustAck,
      Instant publishedAt,
      Long expiresAt) {
    NotificationEntity n = new NotificationEntity();
    n.id = id;
    n.audience = audience;
    n.accountId = accountId;
    n.kind = kind;
    n.level = level;
    n.title = title;
    n.body = body;
    // 三个动作列在表里是 NOT NULL：缺省填空值，而不是留 null 让读取方到处判空。
    n.actionKind = actionKind == null ? "none" : actionKind;
    n.actionValue = actionValue == null ? "" : actionValue;
    n.actionLabel = actionLabel == null ? "" : actionLabel;
    n.popupSlot = popupSlot;
    n.frequencySeconds = frequencySeconds;
    n.mustAck = mustAck;
    n.publishedAt = publishedAt.getEpochSecond();
    n.expiresAt = expiresAt;
    return n;
  }
}
