package app.vaultone.server.config;

import app.vaultone.server.web.ErrorBody;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ReadListener;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletInputStream;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletRequestWrapper;
import jakarta.servlet.http.HttpServletResponse;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Semaphore;
import org.eclipse.jetty.server.NetworkConnectionLimit;
import org.springframework.boot.jackson.autoconfigure.JsonFactoryBuilderCustomizer;
import org.springframework.boot.jetty.servlet.JettyServletWebServerFactory;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;
import tools.jackson.core.StreamReadConstraints;
import tools.jackson.databind.ObjectMapper;

/**
 * 真实资源边界：连接数、并发执行、请求体大小与 JSON 深度。虚拟线程不等于无限并发；超限立即拒绝而非积累无界队列。
 *
 * <p>体积限制对 {@code Content-Length} 早拒绝，对 chunked/未知长度按实际读取字节计数，不提前无界 {@code readAllBytes}。
 */
@Configuration(proxyBeanMethods = false)
public class ResourceLimits {
  @Bean
  WebServerFactoryCustomizer<JettyServletWebServerFactory> jettyLimits(
      VaultOneProperties properties) {
    int maxConnections = properties.web().maxConnections();
    return factory ->
        factory.addServerCustomizers(
            server -> server.addBean(new NetworkConnectionLimit(maxConnections, server)));
  }

  /** 超过执行预算立即 429，不积累无界等待队列。 */
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> concurrentRequests(
      VaultOneProperties properties, ObjectMapper json) {
    Semaphore slots = new Semaphore(properties.web().maxConcurrentRequests());
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected void doFilterInternal(
              HttpServletRequest request, HttpServletResponse response, FilterChain chain)
              throws ServletException, IOException {
            if (!slots.tryAcquire()) {
              writeJson(json, response, 429);
              return;
            }
            try {
              chain.doFilter(request, response);
            } finally {
              slots.release();
            }
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-190);
    return registration;
  }

  /** 请求体上限：通用 1MiB，{@code /v1/sync/push} 单独预算。 */
  @Bean
  FilterRegistrationBean<OncePerRequestFilter> requestSizeLimit(
      VaultOneProperties properties, ObjectMapper json) {
    long general = properties.web().maxBodyBytes();
    long push = properties.web().maxPushBodyBytes();
    var filter =
        new OncePerRequestFilter() {
          @Override
          protected void doFilterInternal(
              HttpServletRequest request, HttpServletResponse response, FilterChain chain)
              throws ServletException, IOException {
            long limit = request.getRequestURI().startsWith("/v1/sync/push") ? push : general;
            long declared = request.getContentLengthLong();
            if (declared > limit) {
              writeJson(json, response, 413);
              return;
            }
            HttpServletRequest effective =
                declared >= 0 ? request : new LimitedRequest(request, limit);
            try {
              chain.doFilter(effective, response);
            } catch (PayloadTooLargeException ex) {
              if (!response.isCommitted()) {
                writeJson(json, response, 413);
              }
            }
          }
        };
    var registration = new FilterRegistrationBean<OncePerRequestFilter>(filter);
    registration.setOrder(-200);
    return registration;
  }

  /**
   * JSON 嵌套深度上限：在本应用 Jackson {@code JsonFactory} 构建时设置（应用级，不修改 JVM 全局静态默认）， 缓解深层结构导致的栈/CPU 放大，并避免多个
   * Spring context 相互污染。
   */
  @Bean
  JsonFactoryBuilderCustomizer jsonDepthCustomizer(VaultOneProperties properties) {
    int depth = properties.web().maxJsonDepth();
    return builder ->
        builder.streamReadConstraints(
            StreamReadConstraints.builder().maxNestingDepth(depth).build());
  }

  private static void writeJson(ObjectMapper json, HttpServletResponse response, int status)
      throws IOException {
    response.setStatus(status);
    response.setContentType("application/json");
    response.setCharacterEncoding("UTF-8");
    response.setHeader("Cache-Control", "no-store");
    json.writeValue(response.getOutputStream(), ErrorBody.forStatus(status));
  }

  /** 未知长度请求的计数包装：超过上限即抛 {@link PayloadTooLargeException}。 */
  static final class LimitedRequest extends HttpServletRequestWrapper {
    private final long limit;

    LimitedRequest(HttpServletRequest request, long limit) {
      super(request);
      this.limit = limit;
    }

    @Override
    public ServletInputStream getInputStream() throws IOException {
      return new LimitedInputStream(super.getInputStream(), limit);
    }

    @Override
    public BufferedReader getReader() throws IOException {
      Charset charset =
          getCharacterEncoding() == null
              ? StandardCharsets.UTF_8
              : Charset.forName(getCharacterEncoding());
      return new BufferedReader(new InputStreamReader(getInputStream(), charset));
    }
  }

  static final class LimitedInputStream extends ServletInputStream {
    private final ServletInputStream delegate;
    private final long limit;
    private long count;

    LimitedInputStream(ServletInputStream delegate, long limit) {
      this.delegate = delegate;
      this.limit = limit;
    }

    @Override
    public int read() throws IOException {
      int value = delegate.read();
      if (value >= 0) {
        count++;
        check();
      }
      return value;
    }

    @Override
    public int read(byte[] buffer, int offset, int length) throws IOException {
      int read = delegate.read(buffer, offset, length);
      if (read > 0) {
        count += read;
        check();
      }
      return read;
    }

    private void check() throws IOException {
      if (count > limit) {
        throw new PayloadTooLargeException();
      }
    }

    @Override
    public boolean isFinished() {
      return delegate.isFinished();
    }

    @Override
    public boolean isReady() {
      return delegate.isReady();
    }

    @Override
    public void setReadListener(ReadListener readListener) {
      delegate.setReadListener(readListener);
    }
  }

  static final class PayloadTooLargeException extends IOException {
    PayloadTooLargeException() {
      super("request body too large");
    }
  }
}
