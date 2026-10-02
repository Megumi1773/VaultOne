package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 补填邀请人邀请码（计划书 §9）。
 *
 * <p>方向不能混用：这是**别人给我的邀请码**，与我自己的邀请码（`invite_code`）是两回事。 一次性绑定，绑定后不可更改。
 */
public record BindInviteRequest(@JsonProperty(required = true) String code) {
  public BindInviteRequest {
    Dto.requireAll(code, "code");
  }

  @Override
  public String toString() {
    // 邀请码不进日志：拿到它就能把邀请关系挂到别人名下。
    return "BindInviteRequest[code=<redacted>]";
  }
}
