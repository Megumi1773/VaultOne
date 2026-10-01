package app.vaultone.server;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.webmvc.autoconfigure.error.ErrorMvcAutoConfiguration;

/**
 * VaultOne Java 服务端。排除 Spring 默认错误 MVC 自动配置，统一错误外形由 {@link app.vaultone.server.web.ApiErrors} 提供（避免
 * {@code /error} 映射冲突与 ProblemDetail）。
 */
@SpringBootApplication(exclude = ErrorMvcAutoConfiguration.class)
public class VaultOneServerApplication {

  public static void main(String[] args) {
    if (args.length > 0 && "feedback-ops".equals(args[0])) {
      System.exit(
          app.vaultone.server.feedback.ops.FeedbackConsole.run(
              java.util.Arrays.copyOfRange(args, 1, args.length),
              System.in,
              new java.io.PrintStream(System.out, true, java.nio.charset.StandardCharsets.UTF_8)));
      return;
    }
    SpringApplication.run(VaultOneServerApplication.class, args);
  }
}
