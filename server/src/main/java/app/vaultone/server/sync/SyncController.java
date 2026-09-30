package app.vaultone.server.sync;

import app.vaultone.server.proto.PullResponse;
import app.vaultone.server.proto.PushRequest;
import app.vaultone.server.proto.PushResponse;
import app.vaultone.server.security.Approved;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 同步路由：{@code GET /v1/sync/pull} 与 {@code POST /v1/sync/push}。
 *
 * <p>直接返回线 DTO（不套响应外壳）。认证主体由 {@link Approved} 处理方法参数解析器提供（已认证且设备已批准）。
 */
@RestController
@RequestMapping("/v1/sync")
public class SyncController {
  private final SyncService syncService;

  public SyncController(SyncService syncService) {
    this.syncService = syncService;
  }

  @GetMapping("/pull")
  public PullResponse pull(
      Approved approved,
      @RequestParam(name = "cursor", defaultValue = "0") long cursor,
      @RequestParam(name = "limit", required = false) Long limit) {
    return syncService.pull(approved, cursor, limit);
  }

  @PostMapping("/push")
  public PushResponse push(Approved approved, @RequestBody PushRequest req) {
    return syncService.push(approved, req);
  }
}
