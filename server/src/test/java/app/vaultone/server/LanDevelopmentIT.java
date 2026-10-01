package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.config.DevelopmentNetworkPolicy;
import app.vaultone.server.support.LocalTestServices;
import java.net.Inet4Address;
import java.net.NetworkInterface;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;

/** 真实网卡访问：仅隔离 fixture，测试不改防火墙，也不使用用户的开发业务库。 */
class LanDevelopmentIT {
  @Test
  void privateInterfaceReachesJettyWithNormalKdfAndAuthenticationStillRequired() throws Exception {
    String address =
        NetworkInterface.networkInterfaces()
            .flatMap(NetworkInterface::inetAddresses)
            .filter(
                ip ->
                    ip instanceof Inet4Address
                        && DevelopmentNetworkPolicy.isPrivateIpv4(ip.getHostAddress()))
            .map(java.net.InetAddress::getHostAddress)
            .findFirst()
            .orElseThrow(() -> new IllegalStateException("LAN 验收需要可用的 RFC1918 IPv4 网卡"));
    try (var services = LocalTestServices.start();
        var context = services.startServerApplication(true)) {
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
      String base = "http://" + address + ":" + port;
      var health =
          client.send(
              HttpRequest.newBuilder(URI.create(base + "/healthz"))
                  .timeout(Duration.ofSeconds(5))
                  .GET()
                  .build(),
              HttpResponse.BodyHandlers.ofString());
      assertThat(health.statusCode()).isEqualTo(200);
      assertThat(health.body()).contains("ok");
      var account =
          client.send(
              HttpRequest.newBuilder(URI.create(base + "/v1/account"))
                  .timeout(Duration.ofSeconds(5))
                  .GET()
                  .build(),
              HttpResponse.BodyHandlers.ofString());
      assertThat(account.statusCode()).isEqualTo(401);
      assertThat(context.getEnvironment().getProperty("vaultone.development.allow-test-kdf"))
          .isEqualTo("false");
    }
  }
}
