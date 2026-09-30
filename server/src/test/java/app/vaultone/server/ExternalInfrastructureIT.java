package app.vaultone.server;

import static org.assertj.core.api.Assertions.assertThat;

import app.vaultone.server.support.LocalTestServices;
import org.junit.jupiter.api.Test;

/**
 * 外部本机模式集成测试：显式要求 {@code VAULTONE_IT_MODE=external} 并校验严格环境输入，然后复用与默认模式相同的真实断言。
 *
 * <p>本类不实例化 Testcontainers；未设置 external 时直接失败，提示所需变量，绝不 skip、绝不误起 Docker。
 *
 * <p>真实断言由 {@link InfrastructureIT} 承担；这里额外固定“外部模式选择与严格 URI 校验”的证据，避免外部变量被静默忽略。
 */
class ExternalInfrastructureIT {

  @Test
  void externalModeIsExplicitAndStrict() {
    assertThat(LocalTestServices.externalMode())
        .as("需要 VAULTONE_IT_MODE=external 才能运行外部本机模式；本测试不自动改用容器")
        .isTrue();
    // 严格解析并构造资源（回环/无 userinfo/显式端口），再由 InfrastructureIT 复用同一套断言。
    try (LocalTestServices services = LocalTestServices.start()) {
      assertThat(services.runtime().user()).startsWith("vaultone_it_runtime");
      assertThat(services.migrator().user()).startsWith("vaultone_it_migrator");
      assertThat(services.runtime().host()).isEqualTo("127.0.0.1");
      assertThat(services.currentSchemaVersion()).isEqualTo("4");
      if (services.backend() instanceof app.vaultone.server.support.ExternalBackend external) {
        external.assertRuntimeRoleRestricted();
        external.assertMigratorRoleRestricted();
      }
    }
  }
}
