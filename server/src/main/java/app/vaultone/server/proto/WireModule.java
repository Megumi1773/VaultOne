package app.vaultone.server.proto;

import tools.jackson.databind.module.SimpleModule;

/**
 * 线协议 Jackson 模块：注册 {@link Bytes} 与线枚举的显式序列化/反序列化器，保证线格式为 STANDARD Base64 与严格 lowercase
 * 枚举，而不依赖注解的“子类型细化”语义（对 final 类型不适用）。
 */
public final class WireModule extends SimpleModule {
  public WireModule() {
    super("vaultone-wire");
    addSerializer(Bytes.class, new BytesSerializer());
    addDeserializer(Bytes.class, new BytesDeserializer());
    addSerializer(Platform.class, new PlatformSerializer());
    addDeserializer(Platform.class, new PlatformDeserializer());
    addSerializer(PushStatus.class, new PushStatusSerializer());
    addDeserializer(PushStatus.class, new PushStatusDeserializer());
  }
}
