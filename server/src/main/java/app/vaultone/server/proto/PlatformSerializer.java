package app.vaultone.server.proto;

import tools.jackson.core.JsonGenerator;
import tools.jackson.databind.SerializationContext;
import tools.jackson.databind.ser.std.StdSerializer;

/** 将 {@link Platform} 序列化为严格 lowercase wire 值。 */
public final class PlatformSerializer extends StdSerializer<Platform> {
  public PlatformSerializer() {
    super(Platform.class);
  }

  @Override
  public void serialize(Platform value, JsonGenerator gen, SerializationContext ctxt) {
    gen.writeString(value.wire());
  }
}
