package app.vaultone.server.identity.web;

import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.identity.service.IdentityService;
import app.vaultone.server.proto.AccountResponse;
import app.vaultone.server.proto.RecoveryCompleteRequest;
import app.vaultone.server.proto.RecoveryCompleteResponse;
import app.vaultone.server.proto.RecoveryFetchRequest;
import app.vaultone.server.proto.RecoveryStartRequest;
import app.vaultone.server.proto.RecoveryStartResponse;
import app.vaultone.server.web.RequestIds;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 恢复路由（F-08）：start / fetch / complete，公开访问。逐条对齐 Rust {@code routes_auth.rs}。 */
@RestController
@RequestMapping("/v1/recovery")
public class RecoveryController {
  private final IdentityService identity;
  private final ServerKeys keys;

  public RecoveryController(IdentityService identity, ServerKeys keys) {
    this.identity = identity;
    this.keys = keys;
  }

  @PostMapping("/start")
  public RecoveryStartResponse start(@RequestBody RecoveryStartRequest req) {
    return identity.recoveryStart(req);
  }

  @PostMapping("/fetch")
  public AccountResponse fetch(@RequestBody RecoveryFetchRequest req, HttpServletRequest request) {
    return identity.recoveryFetch(req, RequestIds.clientIpHash(keys, request));
  }

  @PostMapping("/complete")
  public RecoveryCompleteResponse complete(
      @RequestBody RecoveryCompleteRequest req, HttpServletRequest request) {
    return identity.recoveryComplete(req, RequestIds.clientIpHash(keys, request));
  }
}
