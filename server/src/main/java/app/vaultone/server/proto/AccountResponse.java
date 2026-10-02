package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 账户信息（计划书 §8.1）。
 *
 * <p>资料字段（nickname / avatar / createdAt）是**追加**的：既有客户端只读 email/keys， 未知字段一律忽略，因此不构成破坏性契约。
 *
 * <p>但恢复流程（`/v1/recovery/fetch`）复用本类型且只需要密钥材料，所以这些字段在那里 取空值/0。用 {@link #keysOnly}
 * 显式表达这一点，而不是让调用方手写空串——手写的地方迟早会漏一个。
 *
 * <p>{@code createdAt} 用 **Unix 秒**（与 {@code AuditEventOut} 同一约定），不是 ISO 字符串：
 * 线协议上所有时间都是整数秒，混用两种表示迟早会让某个客户端解析错。
 */
public record AccountResponse(
    @JsonProperty(required = true) String email,
    @JsonProperty(required = true) AccountKeys keys,
    @JsonProperty(required = true) String nickname,
    @JsonProperty(required = true) String avatar,
    @JsonProperty(required = true) long createdAt,
    @JsonProperty(required = true) String inviteCode) {
  public AccountResponse {
    Dto.requireAll(
        email,
        "email",
        keys,
        "keys",
        nickname,
        "nickname",
        avatar,
        "avatar",
        inviteCode,
        "invite_code");
  }

  /** 只带密钥材料的响应（恢复流程用；资料与邀请码留空）。 */
  public static AccountResponse keysOnly(String email, AccountKeys keys) {
    return new AccountResponse(email, keys, "", "", 0L, "");
  }

  @Override
  public String toString() {
    // 昵称与头像地址不属于机密，但仍不随日志整行输出，避免资料被顺手带进日志。
    // 邀请码**是**要当心的一项：拿到它就能把邀请关系挂到别人名下，因此同样不进日志。
    return "AccountResponse[email=<redacted>, keys="
        + (keys == null ? "null" : "<redacted>")
        + ", nickname=<redacted>, avatar=<redacted>, createdAt="
        + createdAt
        + ", inviteCode=<redacted>]";
  }
}
