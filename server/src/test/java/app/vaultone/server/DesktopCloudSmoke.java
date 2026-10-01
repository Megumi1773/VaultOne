package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.support.LocalTestServices;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;

/** 显式 -Dit.test=DesktopCloudSmoke 才运行的 Windows 跨端门禁；环境缺失即失败，不跳过。 */
class DesktopCloudSmoke {
  @Test
  void windowsClientRegistersAndUsesJavaCloud() throws Exception {
    assertThat(System.getProperty("os.name").toLowerCase()).contains("win");
    try (var services = LocalTestServices.start();
        var context = services.startServerApplication()) {
      int port = ((ServletWebServerApplicationContext) context).getWebServer().getPort();
      Path root = Path.of("").toAbsolutePath();
      while (root != null && !Files.isDirectory(root.resolve("app/integration_test")))
        root = root.getParent();
      if (root == null) throw new IllegalStateException("无法定位 Flutter 工程");
      Path output = Files.createTempFile("vaultone-desktop-cloud-", ".log");
      Process process = null;
      try {
        process =
            new ProcessBuilder(
                    "cmd.exe",
                    "/c",
                    "flutter.bat",
                    "test",
                    "--no-pub",
                    "integration_test/app_flow_test.dart",
                    "-d",
                    "windows",
                    "--dart-define=VAULTONE_SERVER=http://127.0.0.1:" + port,
                    "--dart-define=VAULTONE_JAVA_UI_TEST=true")
                .directory(root.resolve("app").toFile())
                .redirectErrorStream(true)
                .redirectOutput(output.toFile())
                .start();
        assertThat(process.waitFor(10, TimeUnit.MINUTES)).as("Windows 云账户测试超时").isTrue();
        String report = Files.readString(output, StandardCharsets.UTF_8);
        assertThat(process.exitValue()).as("Windows 云账户真实联调失败：%s", report).isZero();
        assertThat(report).contains("All tests passed");
      } finally {
        if (process != null && process.isAlive()) process.destroyForcibly();
        Files.deleteIfExists(output);
      }
    }
  }
}
