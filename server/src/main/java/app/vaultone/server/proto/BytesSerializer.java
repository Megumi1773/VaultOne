package app.vaultone.server.proto;

import tools.jackson.core.JsonGenerator;
import tools.jackson.databind.SerializationContext;
import tools.jackson.databind.ser.std.StdSerializer;

/** 将 {@link Bytes} 序列化为 STANDARD Base64 JSON 字符串。 */
public final class BytesSerializer extends StdSerializer<Bytes> {
  public BytesSerializer() {
    super(Bytes.class);
  }

  @Override
  public void serialize(Bytes value, JsonGenerator gen, SerializationContext ctxt) {
    gen.writeString(value.toBase64());
  }
}
