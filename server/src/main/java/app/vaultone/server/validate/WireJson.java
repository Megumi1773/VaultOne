package app.vaultone.server.validate;

import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.json.JsonMapper;

/**
 * 内部 JSON 工具：用于解析客户端不透明条目信封（{@code item_blob}）。
 *
 * <p>此处使用<b>独立</b>的 mapper，与线协议 mapper 解耦：信封解析只需要通用的 JSON 语义（键集合、 版本号、alg 字符串、Base64 字段），字段名是
 * camelCase 且与 DTO 命名策略无关，不能复用 SNAKE_CASE。
 *
 * <p>与线协议 mapper 一样启用 {@code FAIL_ON_TRAILING_TOKENS}：信封后附多余 token 视为格式非法。
 */
final class WireJson {
  static final JsonMapper MAPPER =
      JsonMapper.builder().enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS).build();

  private WireJson() {}
}
