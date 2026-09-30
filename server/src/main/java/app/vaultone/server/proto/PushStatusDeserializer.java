package app.vaultone.server.proto;

import tools.jackson.core.JsonParser;
import tools.jackson.core.JsonToken;
import tools.jackson.databind.DeserializationContext;
import tools.jackson.databind.deser.std.StdDeserializer;

/** 严格解析 {@link PushStatus}：只接受精确 lowercase wire 值。 */
public final class PushStatusDeserializer extends StdDeserializer<PushStatus> {
  public PushStatusDeserializer() {
    super(PushStatus.class);
  }

  @Override
  public PushStatus deserialize(JsonParser parser, DeserializationContext ctxt) {
    if (parser.currentToken() != JsonToken.VALUE_STRING) {
      return ctxt.reportInputMismatch(PushStatus.class, "status 必须是字符串");
    }
    PushStatus status = PushStatus.fromWire(parser.getString());
    if (status == null) {
      return ctxt.reportInputMismatch(PushStatus.class, "未知 status");
    }
    return status;
  }
}
