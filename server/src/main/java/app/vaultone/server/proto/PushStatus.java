package app.vaultone.server.proto;

import java.util.Locale;

/** 推送单条结果状态；lowercase 线枚举，未知输入拒绝。 */
public enum PushStatus {
  APPLIED,
  CONFLICT;

  public String wire() {
    return name().toLowerCase(Locale.ROOT);
  }

  /** 严格 wire 值解析；未知返回 {@code null}。 */
  public static PushStatus fromWire(String value) {
    for (PushStatus status : values()) {
      if (status.wire().equals(value)) {
        return status;
      }
    }
    return null;
  }
}
