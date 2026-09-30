package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.support.LocalTestServices;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;

/**
 * 真实 Rust 生产客户端互通：用 {@code crates/vault-core} 的公开 {@code Vault}/同步客户端驱动真实 Jetty 上的 Java 后端。
 *
 * <p>不手写“测试版客户端”，也不走 Java 自测代替。通过 {@link ProcessBuilder} 在仓库根运行既有 Rust integration test（{@code
 * --ignored}，由本类注入 URL）。
 *
 * <p>Rust 工具链/网络环境缺失时本测试失败（不是 skip）：它证明协议互通，不能用 Java 单测替代。
 */
class BackendContractIT {
  private static final String JAVA_TEST_ALLOW = "VAULTONE_JAVA_TEST_ALLOW";

  @Test
  void rustProductionClientInteroperatesWithJavaBackend() throws Exception {
    try (LocalTestServices services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      assertThat(((ServletWebServerApplicationContext) context).getWebServer().getClass().getName())
          .contains("Jetty");
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      String url = "http://127.0.0.1:" + port;

      Path repoRoot = repoRoot();
      ProcessBuilder builder = new ProcessBuilder();
      builder.directory(repoRoot.toFile());
      builder.command(
          cargoCommand(),
          "test",
          "--locked",
          "-p",
          "vault-core",
          "--test",
          "java_backend",
          "--",
          "--ignored",
          "--nocapture",
          "--test-threads=1");
      builder.environment().put("VAULTONE_JAVA_TEST_URL", url);
      builder.environment().put(JAVA_TEST_ALLOW, "1");
      builder.redirectErrorStream(true);
      Process process = builder.start();
      String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
      boolean finished = process.waitFor(10, TimeUnit.MINUTES);
      if (!finished) {
        process.destroyForcibly();
        throw new AssertionError("Rust 互通测试超时；输出末尾:\n" + tail(output));
      }
      assertThat(process.exitValue()).as("Rust 生产客户端对 Java 后端互通失败；输出:\n%s", output).isEqualTo(0);
      // 至少确认测试确实运行（而不是 0 个用例被静默忽略）。
      assertThat(output).contains("test result");
    }
  }

  private static String cargoCommand() {
    // Windows 下 cargo 为 cargo.exe；用系统 PATH 解析，避免硬编码用户目录。
    String os = System.getProperty("os.name").toLowerCase();
    return os.contains("win") ? "cargo.exe" : "cargo";
  }

  private static String tail(String text) {
    List<String> lines = text.lines().toList();
    int from = Math.max(0, lines.size() - 40);
    return String.join("\n", lines.subList(from, lines.size()));
  }

  /** 定位仓库根（包含 Cargo.toml 与 crates/ 的目录）。 */
  private static Path repoRoot() {
    Path dir = Path.of("").toAbsolutePath();
    while (dir != null) {
      if (Files.exists(dir.resolve("Cargo.toml"))
          && Files.exists(dir.resolve("crates/vault-core"))) {
        return dir;
      }
      dir = dir.getParent();
    }
    throw new IllegalStateException("无法定位仓库根（需含 Cargo.toml 与 crates/）");
  }
}
