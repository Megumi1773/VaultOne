package app.vaultone.server.config;

/** 开发联调只接受数值私网 IPv4；不解析 DNS，不信任转发头，也不把任意网卡当可信内网。 */
public final class DevelopmentNetworkPolicy {
  private DevelopmentNetworkPolicy() {}

  public static boolean isLoopback(String address) {
    return "localhost".equals(address)
        || "127.0.0.1".equals(address)
        || "::1".equals(address)
        || "[::1]".equals(address)
        || "0:0:0:0:0:0:0:1".equals(address)
        || "::ffff:127.0.0.1".equals(address);
  }

  public static boolean isPrivateIpv4(String address) {
    if (address == null) return false;
    if (address.startsWith("::ffff:")) address = address.substring(7);
    String[] parts = address.split("\\.", -1);
    if (parts.length != 4) return false;
    int[] octets = new int[4];
    for (int i = 0; i < 4; i++) {
      if (!parts[i].matches("0|[1-9][0-9]{0,2}")) return false;
      octets[i] = Integer.parseInt(parts[i]);
      if (octets[i] > 255) return false;
    }
    return octets[0] == 10
        || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
        || (octets[0] == 192 && octets[1] == 168);
  }

  public static boolean permitsPeer(String address, boolean allowLan) {
    return isLoopback(address) || (allowLan && isPrivateIpv4(address));
  }
}
