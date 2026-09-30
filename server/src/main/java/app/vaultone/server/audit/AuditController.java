package app.vaultone.server.audit;

import app.vaultone.server.proto.AuditEventOut;
import app.vaultone.server.security.Approved;
import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** 审计路由：{@code GET /v1/audit} 返回最新 100 条（id 倒序）。 */
@RestController
@RequestMapping("/v1/audit")
public class AuditController {
  private final AuditService audit;

  public AuditController(AuditService audit) {
    this.audit = audit;
  }

  @GetMapping
  public List<AuditEventOut> list(Approved approved) {
    return audit.list(approved);
  }
}
