package app.vaultone.server.proto;

import tools.jackson.core.JsonGenerator;
import tools.jackson.databind.SerializationContext;
import tools.jackson.databind.ser.std.StdSerializer;

/** 将 {@link PushStatus} 序列化为严格 lowercase wire 值。 */
public final class PushStatusSerializer extends StdSerializer<PushStatus> {
  public PushStatusSerializer() {
    super(PushStatus.class);
  }

  @Override
  public void serialize(PushStatus value, JsonGenerator gen, SerializationContext ctxt) {
    gen.writeString(value.wire());
  }
}
