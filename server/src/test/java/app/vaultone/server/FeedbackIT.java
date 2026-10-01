package app.vaultone.server;

import static org.assertj.core.api.Assertions.*;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import app.vaultone.server.feedback.ops.FeedbackConsole;
import app.vaultone.server.feedback.service.FeedbackOperationsService;
import app.vaultone.server.identity.service.IdentityService;
import app.vaultone.server.proto.*;
import app.vaultone.server.support.LocalTestServices;
import java.net.URI;
import java.net.http.*;
import java.sql.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.*;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.redisson.api.RedissonClient;
import org.springframework.boot.web.server.servlet.context.ServletWebServerApplicationContext;
import org.springframework.context.ConfigurableApplicationContext;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class FeedbackIT {
  private LocalTestServices services;
  private ConfigurableApplicationContext web;
  private ConfigurableApplicationContext console;
  private ObjectMapper json;
  private FeedbackOperationsService ops;
  private String base;
  private String[] consoleOptions;
  private final HttpClient http =
      HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();

  private record User(String id, String device, String token) {
    @Override
    public String toString() {
      return "TestUser[redacted]";
    }
  }

  @BeforeAll
  void start() {
    services = LocalTestServices.start();
    web = services.startServerApplication();
    base =
        "http://127.0.0.1:" + ((ServletWebServerApplicationContext) web).getWebServer().getPort();
    json = web.getBean(ObjectMapper.class);
    consoleOptions =
        new String[] {
          "--spring.profiles.active=dev",
          "--spring.datasource.url=" + services.runtime().jdbcUrl(),
          "--spring.datasource.username=" + services.runtime().user(),
          "--spring.datasource.password=" + services.runtime().password(),
          "--spring.flyway.user=" + services.migrator().user(),
          "--spring.flyway.placeholders.runtime_role=" + services.runtime().user(),
          "--spring.flyway.placeholders.migrator_role=" + services.migrator().user(),
          "--vaultone.server-secret=" + services.serverSecret(),
          "--vaultone.redis.address=" + services.redis().address()
        };
    console = FeedbackConsole.open(consoleOptions);
    ops = console.getBean(FeedbackOperationsService.class);
  }

  @AfterAll
  void stop() throws Exception {
    try {
      if (console != null) console.close();
    } finally {
      try {
        if (web != null) web.close();
      } finally {
        if (services != null) services.close();
      }
    }
  }

  @Test
  void createReplayAndReplyAreARealClosedLoop() throws Exception {
    User user = user();
    var input = input("仅用于测试的反馈正文");
    var first = request(user, "POST", "/v1/feedback", input);
    assertThat(first.statusCode()).isEqualTo(201);
    assertThat(first.headers().firstValue("cache-control").orElse("")).contains("no-store");
    assertThat(node(first).get("status").asText()).isEqualTo("open");
    assertThat(node(first).get("contact").isNull()).isTrue();
    var replay = request(user, "POST", "/v1/feedback", input);
    assertThat(replay.statusCode()).isEqualTo(200);
    var changed = new FeedbackDtos.Create(input.id(), "bug", "different", null, true);
    assertThat(request(user, "POST", "/v1/feedback", changed).statusCode()).isEqualTo(409);
    assertThat(count(user, "select count(*) from feedback where user_id=?")).isEqualTo(1);
    assertThat(
            count(
                user,
                "select count(*) from audit_events where user_id=? and event='feedback_created'"))
        .isEqualTo(1);

    var handled =
        ops.handle(
            user.id(),
            input.id(),
            "support-a",
            new FeedbackDtos.Handle(1, "resolved", "已核实并修复"),
            "ops-test");
    assertThat(handled.version()).isEqualTo(2);
    assertThat(
            ops.handle(
                    user.id(),
                    input.id(),
                    "support-a",
                    new FeedbackDtos.Handle(1, "resolved", "已核实并修复"),
                    "retry")
                .version())
        .isEqualTo(2);
    assertThat(
            count(
                user,
                "select count(*) from audit_events where user_id=? and event='feedback_handled' and operator_id='support-a' and device_id is null"))
        .isEqualTo(1);
    var detail = node(request(user, "GET", "/v1/feedback/" + input.id(), null));
    assertThat(detail.get("reply").asText()).isEqualTo("已核实并修复");
    assertThat(detail.get("status").asText()).isEqualTo("resolved");
    assertThat(ops.list(user.id(), null, 20).items()).hasSize(1);
    assertThat(ops.get(user.id(), input.id()).reply()).isEqualTo("已核实并修复");
  }

  @Test
  void consoleParsesStdinRespondsAndPersistsFailedCasAudit() throws Exception {
    User user = user();
    var input = input("console-loop");
    assertThat(request(user, "POST", "/v1/feedback", input).statusCode()).isEqualTo(201);
    var command =
        new FeedbackConsole.Command(
            "respond",
            user.id(),
            "support-console",
            input.id(),
            null,
            null,
            new FeedbackDtos.Handle(1, "resolved", "控制台处理回复"));
    var output = new java.io.ByteArrayOutputStream();
    int code =
        FeedbackConsole.run(
            consoleOptions,
            new java.io.ByteArrayInputStream(json.writeValueAsBytes(command)),
            new java.io.PrintStream(output));
    assertThat(code).isZero();
    assertThat(
            json.readTree(output.toString(java.nio.charset.StandardCharsets.UTF_8))
                .get("reply")
                .asText())
        .isEqualTo("控制台处理回复");
    assertThat(
            node(request(user, "GET", "/v1/feedback/" + input.id(), null)).get("version").asLong())
        .isEqualTo(2);
    var stale =
        new FeedbackConsole.Command(
            "respond",
            user.id(),
            "support-console",
            input.id(),
            null,
            null,
            new FeedbackDtos.Handle(1, "resolved", "不能覆盖的新回复"));
    output.reset();
    assertThat(
            FeedbackConsole.run(
                consoleOptions,
                new java.io.ByteArrayInputStream(json.writeValueAsBytes(stale)),
                new java.io.PrintStream(output)))
        .isEqualTo(2);
    assertThat(output.toString(java.nio.charset.StandardCharsets.UTF_8))
        .contains("conflict")
        .doesNotContain("不能覆盖");
    assertThat(
            count(
                user,
                "select count(*) from audit_events where user_id=? and event='feedback_handled' and outcome='failure'"))
        .isEqualTo(1);
  }

  @Test
  void authenticationApprovalRevocationAndOwnershipCannotBeBypassed() throws Exception {
    User a = user();
    User b = user();
    var input = input("账户隔离测试");
    assertThat(request(a, "POST", "/v1/feedback", input).statusCode()).isEqualTo(201);
    assertThat(request(null, "GET", "/v1/feedback", null).statusCode()).isEqualTo(401);
    assertThat(request(b, "GET", "/v1/feedback/" + input.id(), null).statusCode()).isEqualTo(404);
    assertThat(node(request(b, "GET", "/v1/feedback", null)).get("items").size()).isZero();
    assertThatThrownBy(() -> ops.get(b.id(), input.id())).isInstanceOf(ApiException.class);
    update(a, "update devices set approved_at=null where user_id=?");
    assertThat(request(a, "POST", "/v1/feedback", input("unapproved")).statusCode()).isEqualTo(403);
    update(a, "update users set session_epoch=session_epoch+1 where id=?");
    assertThat(request(a, "GET", "/v1/feedback", null).statusCode()).isEqualTo(401);
  }

  @Test
  void strictInputAndAccountSubmissionBudget() throws Exception {
    User user = user();
    for (Object bad :
        List.of(
            new FeedbackDtos.Create(UUID.randomUUID().toString(), "bug", "x", null, false),
            new FeedbackDtos.Create(UUID.randomUUID().toString(), "unknown", "x", null, true),
            new FeedbackDtos.Create("../account", "bug", "x", null, true),
            new FeedbackDtos.Create(
                UUID.randomUUID().toString(), "bug", "x".repeat(4001), null, true))) {
      assertThat(request(user, "POST", "/v1/feedback", bad).statusCode()).isEqualTo(400);
    }
    var unknownField =
        request(
            user,
            "POST",
            "/v1/feedback",
            Map.of(
                "id",
                UUID.randomUUID().toString(),
                "category",
                "bug",
                "content",
                "x",
                "consent",
                true,
                "user_id",
                user.id()));
    assertThat(unknownField.statusCode()).isEqualTo(422);
    assertThat(node(unknownField).get("code").asText()).isEqualTo("unprocessable_entity");
    assertThat(request(user, "GET", "/v1/feedback?limit=51", null).statusCode()).isEqualTo(400);
    assertThat(request(user, "GET", "/v1/feedback?before=0", null).statusCode()).isEqualTo(400);
    var first = input("first");
    assertThat(request(user, "POST", "/v1/feedback", first).statusCode()).isEqualTo(201);
    for (int i = 1; i < 10; i++)
      assertThat(request(user, "POST", "/v1/feedback", input("item" + i)).statusCode())
          .isEqualTo(201);
    assertThat(request(user, "POST", "/v1/feedback", input("over quota")).statusCode())
        .isEqualTo(429);
    assertThat(request(user, "POST", "/v1/feedback", first).statusCode()).isEqualTo(200);
  }

  @Test
  void paginationDoesNotExposeContentOrReorderHandledRecords() throws Exception {
    User user = user();
    List<String> ids = new ArrayList<>();
    for (int i = 0; i < 3; i++) {
      var input = input("private-content-" + i);
      ids.add(input.id());
      assertThat(request(user, "POST", "/v1/feedback", input).statusCode()).isEqualTo(201);
    }
    var page = node(request(user, "GET", "/v1/feedback?limit=2", null));
    assertThat(page.get("items").size()).isEqualTo(2);
    assertThat(page.toString()).doesNotContain("private-content", "contact", "reply");
    long cursor = page.get("next_before").asLong();
    ops.handle(
        user.id(),
        ids.getFirst(),
        "support",
        new FeedbackDtos.Handle(1, "in_progress", "正在核查"),
        "page-test");
    var last = node(request(user, "GET", "/v1/feedback?limit=2&before=" + cursor, null));
    assertThat(last.get("items").size()).isEqualTo(1);
    assertThat(last.get("items").get(0).get("id").asText()).isEqualTo(ids.getFirst());
    assertThat(last.get("next_before").isNull()).isTrue();
  }

  @Test
  void concurrentCreationAndOperatorsHaveOneWinner() throws Exception {
    User user = user();
    var input = input("concurrent");
    try (var executor = Executors.newFixedThreadPool(2)) {
      var gate = new CyclicBarrier(2);
      List<Future<Integer>> results = new ArrayList<>();
      for (int i = 0; i < 2; i++)
        results.add(
            executor.submit(
                () -> {
                  gate.await();
                  return request(user, "POST", "/v1/feedback", input).statusCode();
                }));
      assertThat(
              List.of(
                  results.get(0).get(30, TimeUnit.SECONDS),
                  results.get(1).get(30, TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder(201, 200);
      var operatorGate = new CyclicBarrier(2);
      List<Future<Boolean>> writes = new ArrayList<>();
      for (int i = 0; i < 2; i++) {
        int n = i;
        writes.add(
            executor.submit(
                () -> {
                  operatorGate.await();
                  try {
                    ops.handle(
                        user.id(),
                        input.id(),
                        "operator-" + n,
                        new FeedbackDtos.Handle(1, "resolved", "reply" + n),
                        "race");
                    return true;
                  } catch (ApiException ex) {
                    assertThat(ex.code()).isEqualTo("conflict");
                    return false;
                  }
                }));
      }
      assertThat(
              List.of(
                  writes.get(0).get(30, TimeUnit.SECONDS), writes.get(1).get(30, TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder(true, false);
    }
  }

  @Test
  void consoleHasNoWebRedisSchedulerOrMigrationAndIsAbsentFromWebContext() {
    assertThat(console).isNotInstanceOf(ServletWebServerApplicationContext.class);
    assertThat(console.getBeansOfType(RedissonClient.class)).isEmpty();
    assertThat(console.getBeansOfType(Flyway.class)).isEmpty();
    assertThat(console.getBeansOfType(app.vaultone.server.common.MaintenanceScheduler.class))
        .isEmpty();
    assertThat(web.getBeansOfType(FeedbackOperationsService.class)).isEmpty();
  }

  @Test
  void rlsFailsClosedAndExpiryCleanupIsBoundedByDatabaseTime() throws Exception {
    User a = user();
    User b = user();
    var expired = input("to expire");
    request(a, "POST", "/v1/feedback", expired);
    request(b, "POST", "/v1/feedback", input("keep"));
    var runtime = services.runtime();
    try (var connection =
            DriverManager.getConnection(runtime.jdbcUrl(), runtime.user(), runtime.password());
        var s = connection.createStatement()) {
      try (var rows = s.executeQuery("select count(*) from feedback")) {
        rows.next();
        assertThat(rows.getInt(1)).isZero();
      }
      connection.setAutoCommit(false);
      try (var bind =
          connection.prepareStatement("select set_config('vaultone.account_id', ?, true)")) {
        bind.setString(1, a.id());
        bind.execute();
      }
      try (var rows = s.executeQuery("select count(*) from feedback")) {
        rows.next();
        assertThat(rows.getInt(1)).isEqualTo(1);
      }
      connection.commit();
      try (var rows = s.executeQuery("select count(*) from feedback")) {
        rows.next();
        assertThat(rows.getInt(1)).isZero();
      }
    }
    update(a, "update feedback set created_at=1, expires_at=2 where user_id=?");
    assertThat(request(a, "GET", "/v1/feedback/" + expired.id(), null).statusCode()).isEqualTo(404);
    assertThatThrownBy(() -> ops.get(a.id(), expired.id())).isInstanceOf(ApiException.class);
    try (var connection =
            DriverManager.getConnection(runtime.jdbcUrl(), runtime.user(), runtime.password());
        var s = connection.createStatement();
        var rows = s.executeQuery("select public.vaultone_purge_expired_feedback()")) {
      rows.next();
      assertThat(rows.getInt(1)).isBetween(0, 500);
    }
    assertThat(count(a, "select count(*) from feedback where user_id=?")).isZero();
    assertThat(count(b, "select count(*) from feedback where user_id=?")).isEqualTo(1);
    update(b, "delete from users where id=?");
    assertThat(count(b, "select count(*) from feedback where user_id=?")).isZero();
  }

  @Test
  void bodyContactAndReplyAreAbsentFromLogsAndAuditSnapshots() throws Exception {
    var root =
        (ch.qos.logback.classic.Logger)
            org.slf4j.LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
    var capture =
        new ch.qos.logback.core.read.ListAppender<ch.qos.logback.classic.spi.ILoggingEvent>();
    capture.start();
    root.addAppender(capture);
    User user = user();
    String marker = "private-feedback-" + UUID.randomUUID();
    var input =
        new FeedbackDtos.Create(
            UUID.randomUUID().toString(), "other", marker, marker + "@example.test", true);
    try {
      assertThat(request(user, "POST", "/v1/feedback", input).statusCode()).isEqualTo(201);
      ops.handle(
          user.id(),
          input.id(),
          "support",
          new FeedbackDtos.Handle(1, "resolved", marker + "-reply"),
          "privacy-test");
      request(user, "GET", "/v1/feedback/" + input.id(), null);
      String logs =
          capture.list.stream()
              .map(ch.qos.logback.classic.spi.ILoggingEvent::getFormattedMessage)
              .collect(java.util.stream.Collectors.joining("\n"));
      assertThat(logs).doesNotContain(marker, user.token());
      try (var c = admin();
          var s =
              c.prepareStatement(
                  "select row_to_json(a)::text from audit_events a where user_id=?")) {
        scope(c, user);
        s.setString(1, user.id());
        try (var rows = s.executeQuery()) {
          while (rows.next()) assertThat(rows.getString(1)).doesNotContain(marker);
        }
      }
      try (var c = admin();
          var s = c.createStatement();
          var rows =
              s.executeQuery(
                  "select count(*) from information_schema.tables where table_schema='public' and table_name='feedback_aud'")) {
        rows.next();
        assertThat(rows.getInt(1)).isZero();
      }
    } finally {
      root.detachAppender(capture);
      capture.stop();
    }
  }

  @Test
  void auditFailureRollsBackFeedbackAndContainsNoBody() throws Exception {
    User user = user();
    try (var c = admin();
        var s = c.createStatement()) {
      s.execute(
          "CREATE FUNCTION feedback_test_reject() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.event='feedback_created' THEN RAISE EXCEPTION 'audit rejection'; END IF; RETURN NEW; END $$");
      s.execute(
          "CREATE TRIGGER feedback_test_reject BEFORE INSERT ON audit_events FOR EACH ROW EXECUTE FUNCTION feedback_test_reject()");
      try {
        var response = request(user, "POST", "/v1/feedback", input("do-not-log-body"));
        assertThat(response.statusCode()).isEqualTo(500);
        assertThat(response.body())
            .doesNotContain("do-not-log-body", "audit rejection", "Exception", "SQL");
        assertThat(count(user, "select count(*) from feedback where user_id=?")).isZero();
      } finally {
        s.execute("DROP TRIGGER feedback_test_reject ON audit_events");
        s.execute("DROP FUNCTION feedback_test_reject()");
      }
    }
  }

  private FeedbackDtos.Create input(String content) {
    return new FeedbackDtos.Create(UUID.randomUUID().toString(), "bug", content, null, true);
  }

  private User user() {
    String id = UUID.randomUUID().toString();
    String device = UUID.randomUUID().toString();
    var kdf = new KdfParams("argon2id", 8, 1, 1, Base64.getEncoder().encodeToString(new byte[16]));
    byte[] wrap = new byte[94];
    wrap[0] = 1;
    wrap[1] = 1;
    var keys =
        new AccountKeys(
            id, UUID.randomUUID().toString(), kdf, Bytes.copyOf(wrap), 1, Bytes.copyOf(wrap));
    var registered =
        web.getBean(IdentityService.class)
            .register(
                new RegisterRequest(
                    id + "@example.test",
                    keys,
                    Bytes.copyOf(new byte[16]),
                    Bytes.copyOf(new byte[] {1}),
                    Bytes.copyOf(new byte[32]),
                    new DeviceInfo(device, "feedback-test", Platform.LINUX)),
                null,
                "test-registration");
    return new User(id, device, registered.session().token());
  }

  private HttpResponse<String> request(User user, String method, String path, Object body)
      throws Exception {
    var builder = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(15));
    if (user != null) builder.header("Authorization", "Bearer " + user.token());
    builder.header("Content-Type", "application/json");
    builder.method(
        method,
        body == null
            ? HttpRequest.BodyPublishers.noBody()
            : HttpRequest.BodyPublishers.ofString(json.writeValueAsString(body)));
    return http.send(builder.build(), HttpResponse.BodyHandlers.ofString());
  }

  private JsonNode node(HttpResponse<String> response) {
    return json.readTree(response.body());
  }

  private Connection admin() throws Exception {
    var a = services.migrator();
    return DriverManager.getConnection(a.jdbcUrl(), a.user(), a.password());
  }

  private void scope(Connection c, User user) throws Exception {
    c.setAutoCommit(false);
    try (var s = c.prepareStatement("select set_config('vaultone.account_id', ?, true)")) {
      s.setString(1, user.id());
      s.execute();
    }
  }

  private long count(User user, String sql) throws Exception {
    try (var c = admin();
        var s = c.prepareStatement(sql)) {
      scope(c, user);
      s.setString(1, user.id());
      try (var r = s.executeQuery()) {
        r.next();
        return r.getLong(1);
      }
    }
  }

  private void update(User user, String sql) throws Exception {
    try (var c = admin();
        var s = c.prepareStatement(sql)) {
      scope(c, user);
      s.setString(1, user.id());
      s.executeUpdate();
      c.commit();
    }
  }
}
