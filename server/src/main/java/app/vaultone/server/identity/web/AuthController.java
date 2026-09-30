package app.vaultone.server.identity.web;

import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.service.IdentityService;
import app.vaultone.server.proto.LoginFinishRequest;
import app.vaultone.server.proto.LoginFinishResponse;
import app.vaultone.server.proto.LoginStartRequest;
import app.vaultone.server.proto.LoginStartResponse;
import app.vaultone.server.proto.RegisterRequest;
import app.vaultone.server.security.Authed;
import app.vaultone.server.web.OkResponse;
import app.vaultone.server.web.RequestIds;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 认证路由：注册、SRP 登录、登出。逐条对齐 {@code crates/vault-server/src/routes_auth.rs}。
 *
 * <p>只做参数搬运与 DTO 映射，业务委托 {@link IdentityService}。认证主体由主会话的处理方法参数解析器提供。
 */
@RestController
@RequestMapping("/v1/auth")
public class AuthController {
  private final IdentityService identity;
  private final ServerKeys keys;

  public AuthController(IdentityService identity, ServerKeys keys) {
    this.identity = identity;
    this.keys = keys;
  }

  /** 注册成功返回 201。 */
  @PostMapping("/register")
  public ResponseEntity<LoginFinishResponse> register(
      @RequestBody RegisterRequest req, HttpServletRequest request) {
    LoginFinishResponse response =
        identity.register(
            req, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
    return ResponseEntity.status(HttpStatus.CREATED).body(response);
  }

  @PostMapping("/login/start")
  public LoginStartResponse loginStart(@RequestBody LoginStartRequest req) {
    return identity.loginStart(req);
  }

  @PostMapping("/login/finish")
  public LoginFinishResponse loginFinish(
      @RequestBody LoginFinishRequest req, HttpServletRequest request) {
    return identity.loginFinish(
        req, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
  }

  @PostMapping("/logout")
  public OkResponse logout(Authed authed, HttpServletRequest request) {
    identity.logout(authed, RequestIds.clientIpHash(keys, request), RequestIds.currentRequestId());
    return new OkResponse(true);
  }
}
