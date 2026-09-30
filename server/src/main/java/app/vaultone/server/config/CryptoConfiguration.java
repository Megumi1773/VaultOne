package app.vaultone.server.config;

import app.vaultone.server.crypto.ServerKeys;
import java.util.HexFormat;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** 由已校验的 server_secret 构造服务端密钥；只创建一次，供各业务域注入。 */
@Configuration(proxyBeanMethods = false)
public class CryptoConfiguration {
  @Bean
  ServerKeys serverKeys(VaultOneProperties properties) {
    byte[] secret = HexFormat.of().parseHex(properties.serverSecret());
    try {
      return new ServerKeys(secret);
    } finally {
      java.util.Arrays.fill(secret, (byte) 0);
    }
  }
}
