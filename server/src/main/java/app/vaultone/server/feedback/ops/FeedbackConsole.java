package app.vaultone.server.feedback.ops;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.feedback.dto.FeedbackDtos;
import app.vaultone.server.feedback.service.FeedbackOperationsService;
import app.vaultone.server.feedback.service.FeedbackRules;
import java.io.InputStream;
import java.io.PrintStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.UUID;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.PropertyNamingStrategies;
import tools.jackson.databind.json.JsonMapper;

/** 单次命令从 stdin 接收有界 JSON，防止文本出现在命令行参数和 shell 历史。 */
public final class FeedbackConsole {
  private static final int MAX_INPUT_BYTES = 32768;

  private FeedbackConsole() {}

  public record Command(
      String action,
      String accountId,
      String operatorId,
      String id,
      Long before,
      Integer limit,
      FeedbackDtos.Handle update) {
    @Override
    public String toString() {
      return "FeedbackCommand[redacted]";
    }
  }

  public static ConfigurableApplicationContext open(String[] options) {
    var args = new ArrayList<>(Arrays.asList(options));
    args.add("--spring.main.web-application-type=none");
    args.add("--spring.flyway.enabled=false");
    args.add("--spring.main.keep-alive=false");
    args.add("--spring.main.banner-mode=off");
    args.add("--management.endpoint.health.group.readiness.include=db");
    var context =
        new SpringApplicationBuilder(FeedbackOpsApplication.class)
            .web(WebApplicationType.NONE)
            .run(args.toArray(String[]::new));
    try {
      verifyRuntimeRole(context);
      return context;
    } catch (RuntimeException failure) {
      context.close();
      throw failure;
    }
  }

  private static void verifyRuntimeRole(ConfigurableApplicationContext context) {
    try (var connection = context.getBean(javax.sql.DataSource.class).getConnection();
        var query = connection.createStatement()) {
      query.setQueryTimeout(5);
      try (var rows =
          query.executeQuery(
              "select r.rolsuper or r.rolbypassrls or r.rolcreatedb or r.rolcreaterole "
                  + "or pg_has_role(current_user, c.relowner, 'MEMBER') "
                  + "from pg_roles r cross join pg_class c join pg_namespace n on n.oid=c.relnamespace "
                  + "where r.rolname=current_user and n.nspname='public' and c.relname='feedback'")) {
        if (!rows.next() || rows.getBoolean(1))
          throw new IllegalStateException("反馈运维必须使用非owner受限运行角色");
      }
    } catch (java.sql.SQLException failure) {
      throw new IllegalStateException("无法确认反馈运维数据库角色");
    }
  }

  public static int run(String[] options, InputStream input, PrintStream output) {
    var json =
        JsonMapper.builder()
            .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
            .enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
            .enable(DeserializationFeature.FAIL_ON_NULL_FOR_PRIMITIVES)
            .disable(DeserializationFeature.ACCEPT_FLOAT_AS_INT)
            .disable(tools.jackson.databind.MapperFeature.ALLOW_COERCION_OF_SCALARS)
            .build();
    try {
      byte[] bytes = input.readNBytes(MAX_INPUT_BYTES + 1);
      if (bytes.length > MAX_INPUT_BYTES) throw ApiException.badRequest("运维输入过长");
      Command command;
      try {
        command = json.readValue(bytes, Command.class);
      } catch (RuntimeException invalid) {
        throw ApiException.badRequest("运维输入格式不正确");
      }
      validate(command);
      try (var context = open(options)) {
        var service = context.getBean(FeedbackOperationsService.class);
        String requestId = "ops-" + UUID.randomUUID();
        Object result;
        try {
          result =
              switch (command.action()) {
                case "list" ->
                    service.list(
                        command.accountId(),
                        command.before(),
                        command.limit() == null ? 20 : command.limit());
                case "show" -> service.get(command.accountId(), command.id());
                case "respond" ->
                    service.handle(
                        command.accountId(),
                        command.id(),
                        command.operatorId(),
                        command.update(),
                        requestId);
                default -> throw ApiException.badRequest("不支持的运维操作");
              };
        } catch (ApiException failure) {
          if ("respond".equals(command.action()) && failure.status() != 404) {
            service.recordFailure(
                command.accountId(), command.id(), command.operatorId(), requestId);
          }
          throw failure;
        }
        output.println(json.writeValueAsString(result));
      }
      return 0;
    } catch (ApiException failure) {
      output.println(
          json.writeValueAsString(
              new app.vaultone.server.proto.ErrorBody(failure.code(), failure.getMessage())));
      return 2;
    } catch (Exception failure) {
      output.println("{\"code\":\"service_unavailable\",\"message\":\"运维操作失败，请检查受控服务日志后重试\"}");
      return 2;
    }
  }

  private static void validate(Command c) {
    if (c == null || c.action() == null) throw ApiException.badRequest("缺少运维操作");
    FeedbackRules.id(c.accountId());
    FeedbackRules.operator(c.operatorId());
    switch (c.action()) {
      case "list" -> FeedbackRules.page(c.before(), c.limit() == null ? 20 : c.limit());
      case "show" -> FeedbackRules.id(c.id());
      case "respond" -> {
        FeedbackRules.id(c.id());
        if (c.update() == null) throw ApiException.badRequest("缺少处理结果");
        FeedbackRules.handle(c.update());
      }
      default -> throw ApiException.badRequest("不支持的运维操作");
    }
  }
}
