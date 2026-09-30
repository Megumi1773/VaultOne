package app.vaultone.server.proto;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.PropertyNamingStrategies;
import tools.jackson.databind.json.JsonMapper;

/**
 * 线协议 DTO 的 JSON 边界：snake_case、STANDARD Base64、显式 null、i64 整数、严格 lowercase 枚举、 未知字段忽略、必需字段
 * null/缺失/错误类型拒绝。这些映射行为固化自 Rust {@code vault-proto} 与 {@code docs/10 §3}，不用 Java 自身 roundtrip 冒充互通。
 */
class WireJsonTest {
  /** 与 {@code WireJsonConfiguration} 等价的测试 mapper，避免依赖 Spring 上下文。 */
  private static final JsonMapper MAPPER =
      JsonMapper.builder()
          .addModule(new WireModule())
          .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
          .disable(tools.jackson.databind.DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
          .disable(tools.jackson.databind.DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY)
          .disable(tools.jackson.databind.DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT)
          .disable(tools.jackson.databind.DeserializationFeature.ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT)
          .disable(tools.jackson.databind.DeserializationFeature.ACCEPT_FLOAT_AS_INT)
          .enable(tools.jackson.databind.DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES)
          .disable(tools.jackson.databind.MapperFeature.ALLOW_COERCION_OF_SCALARS)
          .withCoercionConfig(
              tools.jackson.databind.type.LogicalType.Textual,
              config ->
                  config
                      .setCoercion(
                          tools.jackson.databind.cfg.CoercionInputShape.Integer,
                          tools.jackson.databind.cfg.CoercionAction.Fail)
                      .setCoercion(
                          tools.jackson.databind.cfg.CoercionInputShape.Float,
                          tools.jackson.databind.cfg.CoercionAction.Fail)
                      .setCoercion(
                          tools.jackson.databind.cfg.CoercionInputShape.Boolean,
                          tools.jackson.databind.cfg.CoercionAction.Fail)
                      .setCoercion(
                          tools.jackson.databind.cfg.CoercionInputShape.Array,
                          tools.jackson.databind.cfg.CoercionAction.Fail)
                      .setCoercion(
                          tools.jackson.databind.cfg.CoercionInputShape.Object,
                          tools.jackson.databind.cfg.CoercionAction.Fail))
          .build();

  // ── Bytes / Base64 ──

  @Test
  void bytesSerializeAsStandardBase64() {
    assertThat(MAPPER.writeValueAsString(Bytes.copyOf(new byte[] {0, 1, 2, (byte) 255})))
        .isEqualTo("\"AAEC/w==\"");
    assertThat(MAPPER.writeValueAsString(Bytes.copyOf(new byte[0]))).isEqualTo("\"\"");
  }

  @Test
  void bytesDeserializeStrictly() {
    assertThat(MAPPER.readValue("\"AAEC/w==\"", Bytes.class))
        .isEqualTo(Bytes.copyOf(new byte[] {0, 1, 2, (byte) 255}));
    assertThat(MAPPER.readValue("\"\"", Bytes.class)).isEqualTo(Bytes.copyOf(new byte[0]));
    // URL-safe 字符拒绝
    assertThatThrownBy(() -> MAPPER.readValue("\"AAEC_w==\"", Bytes.class))
        .isInstanceOf(RuntimeException.class);
    // 缺失 padding 拒绝
    assertThatThrownBy(() -> MAPPER.readValue("\"AAEC/w\"", Bytes.class))
        .isInstanceOf(RuntimeException.class);
    // 非规范尾部位拒绝
    assertThatThrownBy(() -> MAPPER.readValue("\"AB==\"", Bytes.class))
        .isInstanceOf(RuntimeException.class);
    // 非字符串拒绝
    assertThatThrownBy(() -> MAPPER.readValue("[0,1,2]", Bytes.class))
        .isInstanceOf(RuntimeException.class);
    // 裸 null 由 DTO 非 Option 字段的构造校验拒绝（见下）；此处仅确认 null literal 不产生伪造字节
    assertThat(MAPPER.readValue("null", Bytes.class)).isNull();
  }

  // ── 命名 / 结构 ──

  @Test
  void registerRequestUsesSnakeCaseAndRejectsBadTypes() {
    String json =
        "{\"email\":\"a@b.com\",\"keys\":{\"account_id\":\"id\",\"vault_id\":\"vid\","
            + "\"kdf\":{\"alg\":\"argon2id\",\"m\":65536,\"t\":3,\"p\":4,\"salt\":\"AA==\"},"
            + "\"vk_wrap\":\"AA==\",\"vk_gen\":1,\"recovery_wrap\":\"AA==\"},"
            + "\"srp_salt\":\"AA==\",\"srp_verifier\":\"AA==\",\"recovery_auth_hash\":\"AA==\","
            + "\"device\":{\"id\":\"d\",\"name\":\"n\",\"platform\":\"windows\"},\"future_field\":123}";
    RegisterRequest req = MAPPER.readValue(json, RegisterRequest.class);
    assertThat(req.email()).isEqualTo("a@b.com");
    assertThat(req.keys().vkGen()).isEqualTo(1);
    assertThat(req.keys().kdf().m()).isEqualTo(65536);
    assertThat(req.device().platform()).isEqualTo(Platform.WINDOWS);

    // 必需字段缺失拒绝
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"email\":\"a@b.com\",\"keys\":{\"account_id\":\"id\",\"vault_id\":\"v\","
                        + "\"kdf\":{\"alg\":\"a\",\"m\":1,\"t\":1,\"p\":1,\"salt\":\"AA==\"},"
                        + "\"vk_wrap\":\"AA==\",\"vk_gen\":1,\"recovery_wrap\":\"AA==\"},"
                        + "\"srp_salt\":\"AA==\",\"srp_verifier\":\"AA==\","
                        + "\"recovery_auth_hash\":\"AA==\"}",
                    RegisterRequest.class))
        .isInstanceOf(RuntimeException.class);

    // 必需字段 null 拒绝
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"email\":null,\"keys\":null,\"srp_salt\":null,\"srp_verifier\":null,\"recovery_auth_hash\":null,\"device\":null}",
                    RegisterRequest.class))
        .isInstanceOf(RuntimeException.class);
  }

  @Test
  void platformIsStrictLowercase() {
    assertThat(MAPPER.writeValueAsString(Platform.MACOS)).isEqualTo("\"macos\"");
    assertThat(MAPPER.readValue("\"windows\"", Platform.class)).isEqualTo(Platform.WINDOWS);
    // 大小写不同拒绝
    assertThatThrownBy(() -> MAPPER.readValue("\"Windows\"", Platform.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(() -> MAPPER.readValue("\"toaster\"", Platform.class))
        .isInstanceOf(RuntimeException.class);
  }

  @Test
  void pushStatusIsStrictLowercase() {
    assertThat(MAPPER.writeValueAsString(PushStatus.APPLIED)).isEqualTo("\"applied\"");
    assertThat(MAPPER.readValue("\"conflict\"", PushStatus.class)).isEqualTo(PushStatus.CONFLICT);
    assertThatThrownBy(() -> MAPPER.readValue("\"APPLIED\"", PushStatus.class))
        .isInstanceOf(RuntimeException.class);
  }

  @Test
  void optionalsSerializeExplicitNull() {
    PushResponse response = new PushResponse(List.of(new PushResult("i", PushStatus.APPLIED, 3L)));
    assertThat(MAPPER.writeValueAsString(response))
        .isEqualTo("{\"results\":[{\"id\":\"i\",\"status\":\"applied\",\"revision\":3}]}");

    // LoginFinishResponse.keys 为 Optional：null 必须显式输出
    LoginFinishResponse finish =
        new LoginFinishResponse(
            Bytes.copyOf(new byte[0]), new SessionInfo("t", 1L, "d", false), null);
    String out = MAPPER.writeValueAsString(finish);
    assertThat(out).contains("\"keys\":null");

    // PullResponse.vk_gen 缺省（在 Rust 有 serde default）允许缺失
    PullResponse pull =
        MAPPER.readValue("{\"items\":[],\"cursor\":0,\"has_more\":false}", PullResponse.class);
    assertThat(pull.vkGen()).isNull();
    PullResponse pull2 =
        MAPPER.readValue(
            "{\"items\":[],\"cursor\":0,\"has_more\":false,\"vk_gen\":null}", PullResponse.class);
    assertThat(pull2.vkGen()).isNull();
  }

  @Test
  void optionalsMissingIsAllowed() {
    // ChangeCredentials 的两个可选恢复字段明确有 serde default，缺失即 None
    String json =
        "{\"kdf\":{\"alg\":\"argon2id\",\"m\":65536,\"t\":3,\"p\":4,\"salt\":\"AA==\"},"
            + "\"srp_salt\":\"AA==\",\"srp_verifier\":\"AA==\",\"vk_wrap\":\"AA==\",\"expected_vk_gen\":2}";
    ChangeCredentialsRequest req = MAPPER.readValue(json, ChangeCredentialsRequest.class);
    assertThat(req.recoveryWrap()).isNull();
    assertThat(req.recoveryAuthHash()).isNull();
    assertThat(req.expectedVkGen()).isEqualTo(2);
  }

  @Test
  void i64IntegersDoNotLosePrecision() {
    long big = 9_007_199_254_740_993L; // 2^53 + 1
    DeviceOut out = new DeviceOut("id", "n", Platform.OTHER, true, false, big, big, null);
    String json = MAPPER.writeValueAsString(out);
    assertThat(json).contains("\"created_at\":" + big);
    DeviceOut back = MAPPER.readValue(json, DeviceOut.class);
    assertThat(back.createdAt()).isEqualTo(big);
    assertThat(back.lastSeenAt()).isEqualTo(big);
    assertThat(back.revokedAt()).isNull();
    // 浮点不得被当作整数接受
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"event\":\"e\",\"device_id\":null,\"created_at\":1.5}", AuditEventOut.class))
        .isInstanceOf(RuntimeException.class);
  }

  @Test
  void emptyArraysAreValid() {
    PushRequest push = MAPPER.readValue("{\"items\":[]}", PushRequest.class);
    assertThat(push.items()).isEmpty();
    PushResponse results = MAPPER.readValue("{\"results\":[]}", PushResponse.class);
    assertThat(results.results()).isEmpty();
  }

  @Test
  void unknownFieldsIgnored() {
    LoginStartRequest req =
        MAPPER.readValue(
            "{\"email\":\"a@b.c\",\"extra\":{\"nested\":true}}", LoginStartRequest.class);
    assertThat(req.email()).isEqualTo("a@b.c");
  }

  @Test
  void sensitiveBytesToStringDoesNotLeakContent() {
    Bytes secret = Bytes.copyOf(new byte[] {1, 2, 3, 4, 5});
    assertThat(secret.toString()).isEqualTo("Bytes(5 B)");
    assertThat(secret.toString()).doesNotContain("AQID");
  }

  // ── 原始类型/文本强制转换/null（phase1-review 7）──

  @Test
  void nullForPrimitiveRejected() {
    // required=true 不能拒绝已出现的 null primitive，靠 FAIL_ON_NULL_FOR_PRIMITIVES。
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"id\":\"i\",\"name\":\"n\",\"platform\":\"windows\",\"approved\":null,"
                        + "\"current\":false,\"created_at\":1}",
                    DeviceOut.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"id\":\"i\",\"kind\":\"login\",\"blob\":\"\",\"base_revision\":0,"
                        + "\"revision\":null,\"deleted\":false,\"updated_at\":1}",
                    PushItem.class))
        .isInstanceOf(RuntimeException.class);
  }

  @Test
  void textualFieldRejectsNumberAndBooleanCoercion() {
    // String 目标不得被 number/boolean/array/object 强制转换
    assertThatThrownBy(() -> MAPPER.readValue("{\"email\":123}", LoginStartRequest.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(() -> MAPPER.readValue("{\"email\":true}", LoginStartRequest.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(() -> MAPPER.readValue("{\"email\":[1]}", LoginStartRequest.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(() -> MAPPER.readValue("{\"email\":{\"a\":1}}", LoginStartRequest.class))
        .isInstanceOf(RuntimeException.class);
  }

  // ── KdfParams u32 边界（phase1-review 8）──

  @Test
  void kdfParamsRejectsOutOfU32Range() {
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"alg\":\"argon2id\",\"m\":-1,\"t\":1,\"p\":1,\"salt\":\"AA==\"}",
                    KdfParams.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(
            () ->
                MAPPER.readValue(
                    "{\"alg\":\"argon2id\",\"m\":4294967296,\"t\":1,\"p\":1,\"salt\":\"AA==\"}",
                    KdfParams.class))
        .isInstanceOf(RuntimeException.class);
    KdfParams ok =
        MAPPER.readValue(
            "{\"alg\":\"argon2id\",\"m\":4294967295,\"t\":1,\"p\":1,\"salt\":\"AA==\"}",
            KdfParams.class);
    assertThat(ok.m()).isEqualTo(4294967295L);
  }

  @Test
  void platformStandaloneTypeSerializesLowercase() {
    assertThat(MAPPER.writeValueAsString(Platform.EXTENSION)).isEqualTo("\"extension\"");
    DeviceInfo info =
        MAPPER.readValue(
            "{\"id\":\"d\",\"name\":\"n\",\"platform\":\"android\"}", DeviceInfo.class);
    assertThat(info.platform()).isEqualTo(Platform.ANDROID);
  }

  @Test
  void bytesDefensivelyCopies() {
    byte[] source = new byte[] {9, 8, 7};
    Bytes bytes = Bytes.wrap(source);
    source[0] = 0; // 修改源数组不得影响实例
    assertThat(bytes.toByteArray()).isEqualTo(new byte[] {9, 8, 7});
    byte[] copy = bytes.toByteArray();
    copy[0] = 0; // 修改返回值不得影响实例
    assertThat(bytes.toByteArray()).isEqualTo(new byte[] {9, 8, 7});
  }

  @Test
  void sensitiveDtosRedactToString() {
    SessionInfo session = new SessionInfo("super-secret-token", 123L, "dev-1", true);
    assertThat(session.toString()).doesNotContain("super-secret-token").contains("<redacted>");
    AccountKeys keys =
        new AccountKeys(
            "acct",
            "vault",
            new KdfParams("argon2id", 65536, 3, 4, "c2FsdA=="),
            Bytes.copyOf(new byte[] {1, 2, 3}),
            7L,
            Bytes.copyOf(new byte[] {4, 5}));
    assertThat(keys.toString()).doesNotContain("AQID").contains("<redacted>");
    RegisterRequest req =
        new RegisterRequest(
            "a@b.c",
            keys,
            Bytes.copyOf(new byte[] {9}),
            Bytes.copyOf(new byte[] {8}),
            Bytes.copyOf(new byte[] {7}),
            new DeviceInfo("d", "n", Platform.WINDOWS));
    assertThat(req.toString()).doesNotContain("a@b.c").doesNotContain("CQ==");
  }

  @Test
  void trailingTokensRejected() {
    assertThatThrownBy(() -> MAPPER.readValue("{\"email\":\"a@b.c\"} {}", LoginStartRequest.class))
        .isInstanceOf(RuntimeException.class);
    assertThatThrownBy(
            () -> MAPPER.readValue("{\"email\":\"a@b.c\"} trailing", LoginStartRequest.class))
        .isInstanceOf(RuntimeException.class);
  }
}
