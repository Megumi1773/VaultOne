package app.vaultone.server.security;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.config.VaultOneProperties;
import jakarta.servlet.http.HttpServletRequest;
import java.time.Instant;
import java.util.Optional;
import org.springframework.core.MethodParameter;
import org.springframework.stereotype.Component;
import org.springframework.web.bind.support.WebDataBinderFactory;
import org.springframework.web.context.request.NativeWebRequest;
import org.springframework.web.method.support.HandlerMethodArgumentResolver;
import org.springframework.web.method.support.ModelAndViewContainer;

/**
 * 将 {@link Authed} / {@link Approved} 解析为处理方法参数：Bearer → SHA-256(token) 索引 Redis，再经 {@link
 * AccountGuard#readOnly} 做 PG 门禁（session_epoch/设备批准与撤销/devices.epoch/logout 标记）。
 *
 * <p>这是**门禁**，不替代业务用例事务内的授权：写用例必须持 principal 在自身事务内再次经 {@link AccountGuard#lock} 校验。滑动续期按 {@code
 * lastRenewedAt} 节流（每小时至多一次）。
 */
@Component
public class AuthArgumentResolver implements HandlerMethodArgumentResolver {
  private final SessionStore sessions;
  private final AccountGuard guard;
  private final long ttlSeconds;

  public AuthArgumentResolver(
      SessionStore sessions, AccountGuard guard, VaultOneProperties properties) {
    this.sessions = sessions;
    this.guard = guard;
    this.ttlSeconds = properties.session().ttlDays() * 86400L;
  }

  @Override
  public boolean supportsParameter(MethodParameter parameter) {
    Class<?> type = parameter.getParameterType();
    return type == Authed.class || type == Approved.class;
  }

  @Override
  public Object resolveArgument(
      MethodParameter parameter,
      ModelAndViewContainer mavContainer,
      NativeWebRequest webRequest,
      WebDataBinderFactory binderFactory) {
    HttpServletRequest request = webRequest.getNativeRequest(HttpServletRequest.class);
    Authed authed = resolve(request);
    // 供事务审计上下文（Envers 修订 actor）读取可信 account/device；由 RequestIdFilter 在 finally 清理。
    PrincipalHolder.set(authed);
    if (parameter.getParameterType() == Approved.class) {
      if (!authed.approved()) {
        throw ApiException.deviceNotApproved();
      }
      return new Approved(authed);
    }
    return authed;
  }

  private Authed resolve(HttpServletRequest request) {
    String header = request.getHeader("Authorization");
    if (header == null || !header.startsWith("Bearer ")) {
      throw ApiException.unauthorized();
    }
    String token = header.substring("Bearer ".length()).trim();
    if (token.isEmpty()) {
      throw ApiException.unauthorized();
    }
    String hashHex = SessionTokens.hashHex(token);
    SessionMetadata metadata = sessions.get(hashHex).orElseThrow(ApiException::unauthorized);
    Instant now = Instant.now();
    if (!metadata.expiresAt().isAfter(now)) {
      sessions.delete(hashHex);
      throw ApiException.unauthorized();
    }
    AccountGuard.Principal principal;
    try {
      principal =
          guard.readOnly(
              new AccountGuard.PrincipalRef(
                  metadata.userId(),
                  metadata.deviceId(),
                  metadata.sessionEpoch(),
                  metadata.deviceEpoch(),
                  hashHex));
    } catch (ApiException ex) {
      // PG 权威状态不符：清理 Redis 索引后拒绝。
      sessions.delete(hashHex);
      throw ApiException.unauthorized();
    }
    renewIfDue(hashHex, metadata, principal, now);
    return new Authed(
        metadata.userId(),
        metadata.deviceId(),
        principal.approved(),
        principal.sessionEpoch(),
        metadata.deviceEpoch(),
        hashHex);
  }

  /** 按 lastRenewedAt 节流：距上次续期不足 1 小时不续；接近过期才续，且仅更新存在键。 */
  private void renewIfDue(
      String hashHex, SessionMetadata metadata, AccountGuard.Principal principal, Instant now) {
    boolean dueForRenew = metadata.lastRenewedAt().plusSeconds(3600).isBefore(now);
    long remaining = metadata.expiresAt().getEpochSecond() - now.getEpochSecond();
    if (dueForRenew && remaining < ttlSeconds - 3600) {
      Instant newExpiry = now.plusSeconds(ttlSeconds);
      try {
        sessions.renewIfPresent(hashHex, metadata, new SessionStore.Renewal(newExpiry, now));
      } catch (SessionStoreUnavailableException ex) {
        // 续期失败不影响本次已通过授权的请求；下次请求再试。
      }
    }
  }

  /** 供测试断言：解析出的可选主体。 */
  Optional<Authed> tryResolve(HttpServletRequest request) {
    try {
      return Optional.of(resolve(request));
    } catch (ApiException ex) {
      return Optional.empty();
    }
  }
}
