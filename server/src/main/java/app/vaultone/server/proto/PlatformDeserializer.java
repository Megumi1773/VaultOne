package app.vaultone.server.proto;

import tools.jackson.core.JsonParser;
import tools.jackson.core.JsonToken;
import tools.jackson.databind.DeserializationContext;
import tools.jackson.databind.deser.std.StdDeserializer;

/** 严格解析 {@link Platform}：只接受精确 lowercase wire 值，未知/大小写不同拒绝。 */
public final class PlatformDeserializer extends StdDeserializer<Platform> {
  public PlatformDeserializer() {
    super(Platform.class);
  }

  @Override
  public Platform deserialize(JsonParser parser, DeserializationContext ctxt) {
    if (parser.currentToken() != JsonToken.VALUE_STRING) {
      return ctxt.reportInputMismatch(Platform.class, "platform 必须是字符串");
    }
    Platform platform = Platform.fromWire(parser.getString());
    if (platform == null) {
      return ctxt.reportInputMismatch(Platform.class, "未知 platform");
    }
    return platform;
  }
}
