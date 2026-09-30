package app.vaultone.server.proto;

import java.util.Locale;

/** 设备平台线枚举：严格 lowercase wire 值，未知/大小写不同拒绝。 */
public enum Platform {
  WINDOWS,
  MACOS,
  LINUX,
  IOS,
  ANDROID,
  EXTENSION,
  OTHER;

  public String wire() {
    return name().toLowerCase(Locale.ROOT);
  }

  /** 严格 wire 值解析；未知返回 {@code null}（由反序列化器拒绝）。 */
  public static Platform fromWire(String value) {
    for (Platform platform : values()) {
      if (platform.wire().equals(value)) {
        return platform;
      }
    }
    return null;
  }
}
