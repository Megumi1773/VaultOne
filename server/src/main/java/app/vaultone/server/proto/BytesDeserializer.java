package app.vaultone.server.proto;

import app.vaultone.server.crypto.WireFormat;
import tools.jackson.core.JsonParser;
import tools.jackson.core.JsonToken;
import tools.jackson.databind.DeserializationContext;
import tools.jackson.databind.deser.std.StdDeserializer;

/**
 * 从 JSON 严格解码 {@link Bytes}：只接受 <b>字符串</b> token，且必须是规范 STANDARD Base64； 非字符串、缺少 padding、URL-safe
 * 字符、空白、非规范尾部位一律拒绝。
 */
public final class BytesDeserializer extends StdDeserializer<Bytes> {
  public BytesDeserializer() {
    super(Bytes.class);
  }

  @Override
  public Bytes deserialize(JsonParser parser, DeserializationContext ctxt) {
    JsonToken token = parser.currentToken();
    if (token != JsonToken.VALUE_STRING) {
      return ctxt.reportInputMismatch(Bytes.class, "字节字段必须是字符串");
    }
    String text = parser.getString();
    try {
      return Bytes.wrap(WireFormat.base64Decode(text));
    } catch (IllegalArgumentException ex) {
      return ctxt.reportInputMismatch(Bytes.class, "非法的 STANDARD Base64 字节文本");
    }
  }
}
