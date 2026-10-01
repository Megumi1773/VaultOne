package app.vaultone.server.config;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.time.Duration;
import java.util.List;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.ConstructorBinding;
import org.springframework.validation.annotation.Validated;

/** vaultone 命名空间的强类型配置；敏感字段不参与 toString 输出。 */
@Validated
@ConfigurationProperties(prefix = "vaultone")
public record VaultOneProperties(
    @NotBlank String environment,
    @NotBlank String serverSecret,
    @NotNull @Valid Redis redis,
    @NotNull @Valid Development development,
    @NotNull @Valid Session session,
    @NotNull @Valid Mail mail,
    @NotNull @Valid Ops ops,
    @NotNull @Valid Web web) {

  /** 显式标注 canonical 构造，避免兼容构造导致 Spring 无法判定绑定构造。 */
  @ConstructorBinding
  public VaultOneProperties {}

  /** 兼容旧构造（无 {@link Web}）：默认请求限制。仅用于避免既有调用点无法编译，新代码应显式配置。 */
  public VaultOneProperties(
      String environment,
      String serverSecret,
      Redis redis,
      Development development,
      Session session,
      Mail mail,
      Ops ops) {
    this(environment, serverSecret, redis, development, session, mail, ops, Web.defaults());
  }

  /** Redis 连接与键命名空间；口令由独立 secret 注入，不写入配置库。 */
  public record Redis(@NotBlank String address, String password, @NotBlank String namespace) {
    @ConstructorBinding
    public Redis {}

    /** 兼容旧构造（无 namespace）：使用默认安全命名空间。仅单测便利，生产必须显式配置环境前缀。 */
    public Redis(String address, String password) {
      this(address, password, "vaultone");
    }

    @Override
    public String toString() {
      return "Redis[address=" + address + ", namespace=" + namespace + ", password=<redacted>]";
    }
  }

  /** 本地开发开关；生产环境必须为 false。{@code allowTestKdf} 只允许显式 dev 且不得等同 enabled。 */
  public record Development(boolean enabled, boolean allowTestKdf, boolean allowLan) {
    @ConstructorBinding
    public Development {}

    public Development(boolean enabled, boolean allowTestKdf) {
      this(enabled, allowTestKdf, false);
    }

    /** 兼容旧构造（仅 enabled）：默认不放开低成本 KDF 或局域网。 */
    public Development(boolean enabled) {
      this(enabled, false, false);
    }
  }

  /** 会话与限流参数；单位与上界见 @Min/@Max。 */
  public record Session(
      @Min(1) @Max(365) long ttlDays,
      @Min(0) @Max(3600) long renewThresholdSeconds,
      @Min(1) @Max(86400) long handshakeTtlSeconds,
      @Min(1) @Max(86400) long otpTtlSeconds,
      @Min(1) @Max(100) int otpMaxAttempts,
      @Min(1) @Max(1000000) long authRateMillis,
      @Min(1) @Max(1000000) int authBurst,
      @Min(1) @Max(1000000) long apiRateMillis,
      @Min(1) @Max(1000000) int apiBurst,
      @Min(1) @Max(100000) int srpMaxConcurrent) {}

  /** 邮件；dev 用 log（仅日志，不投递），prod 用 smtp。TLS/超时有安全默认与上界。 */
  public record Mail(
      @NotBlank String mode,
      @NotBlank String from,
      String smtpHost,
      @Min(1) @Max(65535) int smtpPort,
      String smtpUsername,
      String smtpPassword,
      boolean startTlsRequired,
      boolean sslEnabled,
      @Min(1) @Max(120000) int connectionTimeoutMillis,
      @Min(1) @Max(120000) int readTimeoutMillis,
      @Min(1) @Max(120000) int writeTimeoutMillis) {

    @ConstructorBinding
    public Mail {}

    /** 兼容旧构造：STARTTLS 必需、SSL 关闭、10s 超时。 */
    public Mail(
        String mode,
        String from,
        String smtpHost,
        int smtpPort,
        String smtpUsername,
        String smtpPassword) {
      this(
          mode,
          from,
          smtpHost,
          smtpPort,
          smtpUsername,
          smtpPassword,
          true,
          false,
          10000,
          10000,
          10000);
    }

    public boolean isLog() {
      return "log".equals(mode);
    }

    @Override
    public String toString() {
      return "Mail[mode="
          + mode
          + ", from="
          + from
          + ", smtpHost="
          + smtpHost
          + ", startTlsRequired="
          + startTlsRequired
          + ", sslEnabled="
          + sslEnabled
          + ", password=<redacted>]";
    }
  }

  /** 运行运维参数：日志保留、请求 ID、条目历史保留。 */
  public record Ops(
      @Min(1) @Max(3650) long versionRetentionDays,
      @NotNull Duration logMaxHistory,
      @NotBlank String logMaxFileSize,
      @NotBlank String logTotalSizeCap,
      @NotBlank String logDirectory,
      @Min(8) @Max(128) int requestIdMaxLength) {}

  /** Web 边界：请求体上限、并发、JSON 深度与 CORS 白名单（默认不开放跨域）。 */
  public record Web(
      @Min(1024) @Max(1073741824L) long maxBodyBytes,
      @Min(1024) @Max(1073741824L) long maxPushBodyBytes,
      @Min(1) @Max(100000) int maxConcurrentRequests,
      @Min(16) @Max(1000) int maxJsonDepth,
      @Min(1) @Max(1000000) int maxConnections,
      @NotNull List<@NotBlank String> allowedOrigins) {

    public Web {
      allowedOrigins = allowedOrigins == null ? List.of() : List.copyOf(allowedOrigins);
    }

    static Web defaults() {
      return new Web(1048576L, 67108864L, 128, 100, 256, List.of());
    }
  }

  @Override
  public String toString() {
    return "VaultOneProperties[environment="
        + environment
        + ", serverSecret=<redacted>, redis="
        + redis
        + ", development="
        + development
        + ", session="
        + session
        + ", mail="
        + mail
        + ", ops="
        + ops
        + ", web="
        + web
        + "]";
  }
}
