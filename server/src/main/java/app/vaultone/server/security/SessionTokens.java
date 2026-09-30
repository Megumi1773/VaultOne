package app.vaultone.server.security;

import app.vaultone.server.crypto.ServerKeys;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Base64;
import java.util.HexFormat;

/**
 * Bearer Token 的生成与摘要：32 字节 CSPRNG，URL_SAFE_NO_PAD 编码形成 token 文本；库/Redis 索引为 {@code SHA-256(token
 * 文本 UTF-8)} 的十六进制，绝不解码回原始 32 字节再哈希（对齐 Rust）。
 */
public final class SessionTokens {
  private static final SecureRandom RANDOM = new SecureRandom();

  private SessionTokens() {}

  /** 生成新的 token 文本（32B URL_SAFE_NO_PAD）。 */
  public static String newToken() {
    byte[] raw = new byte[32];
    RANDOM.nextBytes(raw);
    return Base64.getUrlEncoder().withoutPadding().encodeToString(raw);
  }

  /** {@code SHA-256(token 文本 UTF-8)} 的十六进制（会话索引/日志安全键）。 */
  public static String hashHex(String token) {
    return HexFormat.of().formatHex(ServerKeys.sha256(token.getBytes(StandardCharsets.UTF_8)));
  }
}
