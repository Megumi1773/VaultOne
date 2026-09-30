package app.vaultone.server.proto;

import com.fasterxml.jackson.annotation.JsonProperty;

/** 设备信息；{@code platform} 为严格 lowercase 枚举。 */
public record DeviceInfo(
    @JsonProperty(required = true) String id,
    @JsonProperty(required = true) String name,
    @JsonProperty(required = true) Platform platform) {
  public DeviceInfo {
    Dto.requireAll(id, "id", name, "name", platform, "platform");
  }
}
