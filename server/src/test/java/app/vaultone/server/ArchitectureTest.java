package app.vaultone.server;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

/**
 * 架构边界（S2 更新）。
 *
 * <p>Controller 不写 SQL/密码/事务、不直接依赖持久化与 Redis；安全层允许依赖受限仓储与 Redis 会话存储， 但不得反向依赖 web 层；Redisson
 * 单客户端的构造仍只在 config 与 security 两个明确边界内。
 */
@AnalyzeClasses(
    packages = "app.vaultone.server",
    importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureTest {
  @ArchTest
  static final ArchRule webDoesNotTouchPersistence =
      noClasses()
          .that()
          .resideInAPackage("app.vaultone.server.web..")
          .should()
          .dependOnClassesThat()
          .resideInAnyPackage(
              "jakarta.persistence..", "org.hibernate..", "org.redisson..", "java.sql..");

  @ArchTest
  static final ArchRule securityDoesNotDependOnWeb =
      noClasses()
          .that()
          .resideInAPackage("app.vaultone.server.security..")
          .should()
          .dependOnClassesThat()
          .resideInAPackage("app.vaultone.server.web..");

  @ArchTest
  static final ArchRule redisClientOnlyInDedicatedComponents =
      noClasses()
          .that()
          .resideOutsideOfPackages(
              "app.vaultone.server.config..",
              "app.vaultone.server.security..",
              "app.vaultone.server.common..")
          .and()
          .haveSimpleNameNotEndingWith("Cache")
          .and()
          .haveSimpleNameNotEndingWith("Lock")
          .and()
          .haveSimpleNameNotEndingWith("Store")
          .should()
          .dependOnClassesThat()
          .resideInAPackage("org.redisson..");

  @ArchTest
  static final ArchRule noLegacyRedisOrServletContainer =
      noClasses()
          .should()
          .dependOnClassesThat()
          .resideInAnyPackage("redis.clients.jedis..", "io.lettuce..", "org.apache.catalina..");

  @ArchTest
  static final ArchRule entitiesNotSerializedToHttp =
      noClasses()
          .that()
          .resideInAPackage("app.vaultone.server.web..")
          .should()
          .dependOnClassesThat()
          .resideInAnyPackage("..model..");
}
