package app.vaultone.server.feedback.controller;

import app.vaultone.server.feedback.dto.FeedbackDtos;
import app.vaultone.server.feedback.service.FeedbackService;
import app.vaultone.server.security.Approved;
import org.slf4j.MDC;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/v1/feedback")
public class FeedbackController {
  private final FeedbackService service;

  public FeedbackController(FeedbackService service) {
    this.service = service;
  }

  @PostMapping
  public ResponseEntity<FeedbackDtos.Detail> create(
      Approved approved, @RequestBody FeedbackDtos.Create request) {
    var result = service.create(approved, request, MDC.get("requestId"));
    return ResponseEntity.status(result.fresh() ? 201 : 200).body(result.detail());
  }

  @GetMapping
  public FeedbackDtos.Page list(
      Approved approved,
      @RequestParam(required = false) Long before,
      @RequestParam(defaultValue = "20") int limit) {
    return service.list(approved, before, limit);
  }

  @GetMapping("/{id}")
  public FeedbackDtos.Detail get(Approved approved, @PathVariable String id) {
    return service.get(approved, id);
  }
}
