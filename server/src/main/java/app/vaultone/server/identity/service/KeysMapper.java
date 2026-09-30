package app.vaultone.server.identity.service;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.proto.AccountKeys;
import app.vaultone.server.proto.Bytes;
import app.vaultone.server.proto.KdfParams;
import org.springframework.stereotype.Component;
import tools.jackson.databind.ObjectMapper;

/**
 * 账户密钥材料映射：DB 行 ⇄ 线 DTO。{@code kdf} 在库中是 JSON 文本（对齐 Rust {@code serde_json}），此处用线协议 ObjectMapper
 * 严格互转，避免字段名漂移。
 */
@Component
public class KeysMapper {
  private final ObjectMapper mapper;

  public KeysMapper(ObjectMapper mapper) {
    this.mapper = mapper;
  }

  /** 用户实体 → 下发给客户端的 {@link AccountKeys}。 */
  public AccountKeys toKeys(UserEntity user) {
    return new AccountKeys(
        user.getId(),
        user.getVaultId(),
        fromKdfJson(user.getKdf()),
        Bytes.wrap(user.getVkWrap()),
        user.getVkGen(),
        Bytes.wrap(user.getRecoveryWrap()));
  }

  /** {@link KdfParams} → 库中 JSON 文本。 */
  public String toKdfJson(KdfParams kdf) {
    try {
      return mapper.writeValueAsString(kdf);
    } catch (RuntimeException ex) {
      throw ApiException.internal();
    }
  }

  /** 库中 JSON 文本 → {@link KdfParams}。 */
  public KdfParams fromKdfJson(String json) {
    try {
      return mapper.readValue(json, KdfParams.class);
    } catch (RuntimeException ex) {
      throw ApiException.internal();
    }
  }
}
