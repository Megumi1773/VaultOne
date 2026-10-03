package app.vaultone.server.notify.controller;

import app.vaultone.server.notify.service.NotificationService;
import app.vaultone.server.proto.NotificationDtos;
import app.vaultone.server.security.Approved;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** 通知中心（计划书 §6.1 / §6.2）。只读 + 标记已读；发布走运维 SQL。 */
@RestController
@RequestMapping("/v1/notifications")
public class NotificationController {
  private final NotificationService service;

  public NotificationController(NotificationService service) {
    this.service = service;
  }

  @GetMapping
  public NotificationDtos.Page list(
      Approved approved,
      @RequestParam(required = false) String cursor,
      @RequestParam(defaultValue = "20") int limit) {
    if (limit < 1 || limit > NotificationService.MAX_LIMIT) {
      throw app.vaultone.server.common.ApiException.badRequest(
          "limit 需在 1.." + NotificationService.MAX_LIMIT + " 之间");
    }
    return service.list(approved, cursor, limit);
  }

  /** 进入详情即标记已读（计划书 §6.1）。返回最新的未读统计，客户端不必再拉一次列表。 */
  @PostMapping("/{id}/read")
  public NotificationDtos.Unread markRead(Approved approved, @PathVariable String id) {
    return service.markRead(approved, id);
  }
}
