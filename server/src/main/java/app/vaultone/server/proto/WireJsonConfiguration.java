package app.vaultone.server.proto;

import org.springframework.boot.jackson.autoconfigure.JsonMapperBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import tools.jackson.core.json.JsonReadFeature;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.MapperFeature;
import tools.jackson.databind.PropertyNamingStrategies;
import tools.jackson.databind.cfg.CoercionAction;
import tools.jackson.databind.cfg.CoercionInputShape;
import tools.jackson.databind.type.LogicalType;

/**
 * 线协议 JSON 绑定：对齐 Rust serde 的严格语义，不复用 Jackson 宽松默认。
 *
 * <ul>
 *   <li>snake_case 字段名；i64 用 long；未知字段忽略（Rust 普通 DTO 无 {@code deny_unknown_fields}）。
 *   <li>拒绝单值当数组、空串/空数组当 null、浮点当整数、null 赋给原始类型。
 *   <li>{@code Textual} 目标（String）拒绝由 number/boolean/array/object 强制转换，不能只靠 {@code
 *       ALLOW_COERCION_OF_SCALARS}。
 *   <li>字节字段与枚举由 {@link WireModule} 显式处理，不受这些默认影响。
 * </ul>
 */
@Configuration(proxyBeanMethods = false)
public class WireJsonConfiguration {
  @Bean
  JsonMapperBuilderCustomizer wireJsonCustomizer() {
    return builder ->
        builder
            .addModule(new WireModule())
            .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
            .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .disable(DeserializationFeature.ACCEPT_SINGLE_VALUE_AS_ARRAY)
            .disable(DeserializationFeature.ACCEPT_EMPTY_STRING_AS_NULL_OBJECT)
            .disable(DeserializationFeature.ACCEPT_EMPTY_ARRAY_AS_NULL_OBJECT)
            .disable(DeserializationFeature.ACCEPT_FLOAT_AS_INT)
            .enable(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES)
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
            .disable(MapperFeature.ALLOW_COERCION_OF_SCALARS)
            .withCoercionConfig(
                LogicalType.Textual,
                config ->
                    config
                        .setCoercion(CoercionInputShape.Integer, CoercionAction.Fail)
                        .setCoercion(CoercionInputShape.Float, CoercionAction.Fail)
                        .setCoercion(CoercionInputShape.Boolean, CoercionAction.Fail)
                        .setCoercion(CoercionInputShape.Array, CoercionAction.Fail)
                        .setCoercion(CoercionInputShape.Object, CoercionAction.Fail))
            .disable(JsonReadFeature.ALLOW_JAVA_COMMENTS)
            .disable(JsonReadFeature.ALLOW_TRAILING_COMMA)
            .disable(JsonReadFeature.ALLOW_SINGLE_QUOTES)
            .disable(JsonReadFeature.ALLOW_UNQUOTED_PROPERTY_NAMES);
  }
}
