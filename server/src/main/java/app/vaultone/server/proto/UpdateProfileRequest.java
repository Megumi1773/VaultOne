package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 更新账户资料（计划书 §8.2）。两个字段都是**全量替换**：没传的按空串处理，不保留旧值。
 *
 * <p>头像存的是地址而不是图片本身（见 {@code UserEntity#avatar}）。校验在服务层， 这里只保证字段存在且不是 null。
 */
public record UpdateProfileRequest(
    @JsonProperty(required = true) String nickname, @JsonProperty(required = true) String avatar) {
  public UpdateProfileRequest {
    Dto.requireAll(nickname, "nickname", avatar, "avatar");
  }

  @Override
  public String toString() {
    return "UpdateProfileRequest[nickname=<redacted>, avatar=<redacted>]";
  }
}
