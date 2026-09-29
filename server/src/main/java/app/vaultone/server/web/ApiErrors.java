package app.vaultone.server.web;

import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.boot.webmvc.error.ErrorController;
import org.springframework.http.ResponseEntity;
import org.springframework.web.ErrorResponse;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/** 不输出Spring默认ProblemDetail、异常消息或堆栈。 */
@RestController
@RestControllerAdvice
public class ApiErrors implements ErrorController {
  @RequestMapping("/error")
  public ResponseEntity<ErrorBody> error(HttpServletRequest request) {
    Object value = request.getAttribute(RequestDispatcher.ERROR_STATUS_CODE);
    int status = value instanceof Integer code ? code : 500;
    return ResponseEntity.status(status).body(ErrorBody.forStatus(status));
  }

  @ExceptionHandler(Exception.class)
  public ResponseEntity<ErrorBody> exception(Exception exception) {
    int status = exception instanceof ErrorResponse error ? error.getStatusCode().value() : 500;
    return ResponseEntity.status(status).body(ErrorBody.forStatus(status));
  }
}
