package app.vaultone.server.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import app.vaultone.server.config.DevelopmentNetworkPolicy;
import app.vaultone.server.config.VaultOneProperties;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import tools.jackson.databind.json.JsonMapper;

class DevelopmentNetworkFilterTest {
  @Test
  void onlyPrivateIpv4AndLoopbackAreDevelopmentPeers() {
    for (String address :
        List.of("192.168.0.4", "10.0.0.2", "172.16.0.2", "172.31.255.254", "::ffff:192.168.0.5")) {
      assertThat(DevelopmentNetworkPolicy.permitsPeer(address, true)).isTrue();
      assertThat(DevelopmentNetworkPolicy.permitsPeer(address, false)).isFalse();
    }
    for (String address :
        List.of(
            "8.8.8.8",
            "0.0.0.0",
            "198.18.0.1",
            "100.64.0.1",
            "192.168.0.999",
            "010.0.0.1",
            "172.32.0.1",
            "private.example.test")) {
      assertThat(DevelopmentNetworkPolicy.permitsPeer(address, true)).isFalse();
    }
    assertThat(DevelopmentNetworkPolicy.permitsPeer("127.0.0.1", false)).isTrue();
    assertThat(DevelopmentNetworkPolicy.permitsPeer("::1", false)).isTrue();
  }

  @Test
  void forwardedHeadersCannotTurnAnExternalPeerIntoLan() throws Exception {
    var request = new MockHttpServletRequest("GET", "/healthz");
    request.setRemoteAddr("203.0.113.4");
    request.addHeader("X-Forwarded-For", "192.168.0.4");
    var response = new MockHttpServletResponse();
    var chain = new MockFilterChain();
    filter(true, true).doFilter(request, response, chain);
    assertThat(chain.getRequest()).isNull();
    assertThat(response.getStatus()).isEqualTo(403);
    assertThat(response.getContentAsString())
        .contains("development_network_denied")
        .doesNotContain("203.0.113.4");
    assertThat(response.getHeader("Cache-Control")).isEqualTo("no-store");
  }

  @Test
  void optInIsRequiredAndProductionDoesNotUseDevelopmentPeerPolicy() throws Exception {
    for (boolean allow : List.of(false, true)) {
      var request = new MockHttpServletRequest("GET", "/healthz");
      request.setRemoteAddr("192.168.0.8");
      var response = new MockHttpServletResponse();
      var chain = new MockFilterChain();
      filter(true, allow).doFilter(request, response, chain);
      assertThat(chain.getRequest() != null).isEqualTo(allow);
    }
    var request = new MockHttpServletRequest("GET", "/healthz");
    request.setRemoteAddr("203.0.113.4");
    var chain = new MockFilterChain();
    filter(false, false).doFilter(request, new MockHttpServletResponse(), chain);
    assertThat(chain.getRequest()).isNotNull();
  }

  private jakarta.servlet.Filter filter(boolean dev, boolean lan) {
    var properties = mock(VaultOneProperties.class);
    when(properties.development()).thenReturn(new VaultOneProperties.Development(dev, false, lan));
    return new DevelopmentNetworkFilter()
        .developmentNetworkFilterRegistration(properties, JsonMapper.builder().build())
        .getFilter();
  }
}
