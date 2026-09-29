package app.vaultone.server;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

@AnalyzeClasses(
    packages = "app.vaultone.server",
    importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureTest {
  @ArchTest
  static final ArchRule webDoesNotTouchPersistence =
      noClasses()
          .that()
          .resideInAPackage("..web..")
          .should()
          .dependOnClassesThat()
          .resideInAnyPackage(
              "jakarta.persistence..", "org.hibernate..", "org.redisson..", "java.sql..");

  @ArchTest
  static final ArchRule securityDoesNotOwnDatabase =
      noClasses()
          .that()
          .resideInAPackage("..security..")
          .should()
          .dependOnClassesThat()
          .resideInAnyPackage(
              "jakarta.persistence..", "org.hibernate..", "org.redisson..", "java.sql..");

  @ArchTest
  static final ArchRule clientsAreWiredOnlyInConfiguration =
      noClasses()
          .that()
          .resideOutsideOfPackage("..config..")
          .should()
          .dependOnClassesThat()
          .resideInAPackage("org.redisson..");

  @ArchTest
  static final ArchRule noLegacyRedisOrServletContainer =
      noClasses()
          .should()
          .dependOnClassesThat()
          .resideInAnyPackage("redis.clients.jedis..", "io.lettuce..", "org.apache.catalina..");
}
