package app.vaultone.server.web;

import app.vaultone.server.common.ApiException;
import app.vaultone.server.common.ErrorCatalog;
import app.vaultone.server.common.RateLimitUnavailableException;
import app.vaultone.server.common.SafeDiagnostics;
import app.vaultone.server.security.SessionStoreUnavailableException;
import app.vaultone.server.validate.WireValidation;
import jakarta.servlet.RequestDispatcher;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.ConstraintViolationException;
import java.util.stream.Collectors;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.validation.FieldError;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.HttpRequestMethodNotSupportedException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

/**
 * 统一错误转换：所有响应为 {@code {code,message}}，不输出异常类名/堆栈/SQL/配置。
 *
 * <p>分类明确：语法错误 400、未认证 401、未授权 403、不存在 404、方法不支持 405、冲突 409、体积 413、媒体类型 415、 结构校验 422、限流 429、依赖不可用
 * 503、内部 500。不把全部异常都当成 bad_request，也不把方法不支持说成“接口不存在”。
 *
 * <p>所有错误出口都带 {@code no-store} 与安全头；系统错误只记录一份安全诊断（见 {@link SafeDiagnostics}）。
 */
@RestController
@RestControllerAdvice
public class ApiErrors {

  /** 业务异常。 */
  @ExceptionHandler(ApiException.class)
  public ResponseEntity<ErrorBody> api(ApiException ex) {
    return response(ex.status(), ex.code(), ex.getMessage());
  }

  /** 结构校验（信封/KDF/SRP/设备名/kind 等）：语义为可理解的请求错误，返回 400。 */
  @ExceptionHandler(WireValidation.ValidationException.class)
  public ResponseEntity<ErrorBody> validation(WireValidation.ValidationException ex) {
    return response(400, ErrorCatalog.BAD_REQUEST, ex.getMessage());
  }

  /** 请求体 JSON 语法错误 → 400；结构不符（字段类型/缺失）→ 422。 */
  @ExceptionHandler(HttpMessageNotReadableException.class)
  public ResponseEntity<ErrorBody> unreadable(HttpMessageNotReadableException ex) {
    if (isJsonSyntaxError(ex)) {
      return response(400, ErrorCatalog.BAD_REQUEST, "请求体不是合法的 JSON");
    }
    return response(422, ErrorCatalog.UNPROCESSABLE, "请求体结构与线协议不符");
  }

  /** Bean 校验：可给安全字段路径，但不回显字段值。 */
  @ExceptionHandler(MethodArgumentNotValidException.class)
  public ResponseEntity<ErrorBody> beanValidation(MethodArgumentNotValidException ex) {
    String fields =
        ex.getBindingResult().getFieldErrors().stream()
            .map(FieldError::getField)
            .distinct()
            .limit(5)
            .collect(Collectors.joining(", "));
    String message = fields.isEmpty() ? "请求参数不合法" : "请求参数不合法: " + fields;
    return response(400, ErrorCatalog.BAD_REQUEST, message);
  }

  @ExceptionHandler(ConstraintViolationException.class)
  public ResponseEntity<ErrorBody> constraintViolation(ConstraintViolationException ex) {
    String fields =
        ex.getConstraintViolations().stream()
            .map(v -> v.getPropertyPath().toString())
            .distinct()
            .limit(5)
            .collect(Collectors.joining(", "));
    String message = fields.isEmpty() ? "请求参数不合法" : "请求参数不合法: " + fields;
    return response(400, ErrorCatalog.BAD_REQUEST, message);
  }

  @ExceptionHandler(MethodArgumentTypeMismatchException.class)
  public ResponseEntity<ErrorBody> typeMismatch(MethodArgumentTypeMismatchException ex) {
    return response(400, ErrorCatalog.BAD_REQUEST, "请求参数类型不正确");
  }

  @ExceptionHandler(MissingServletRequestParameterException.class)
  public ResponseEntity<ErrorBody> missingParam(MissingServletRequestParameterException ex) {
    return response(400, ErrorCatalog.BAD_REQUEST, "缺少必需参数");
  }

  @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
  public ResponseEntity<ErrorBody> mediaType(HttpMediaTypeNotSupportedException ex) {
    return response(415, ErrorCatalog.UNSUPPORTED_MEDIA_TYPE, "不支持的媒体类型");
  }

  @ExceptionHandler(HttpRequestMethodNotSupportedException.class)
  public ResponseEntity<ErrorBody> method(HttpRequestMethodNotSupportedException ex) {
    return response(405, ErrorCatalog.METHOD_NOT_ALLOWED, "请求方法不被支持");
  }

  @ExceptionHandler(MaxUploadSizeExceededException.class)
  public ResponseEntity<ErrorBody> tooLarge(MaxUploadSizeExceededException ex) {
    return response(413, ErrorCatalog.PAYLOAD_TOO_LARGE, "请求体过大");
  }

  @ExceptionHandler(NoResourceFoundException.class)
  public ResponseEntity<ErrorBody> notFound(NoResourceFoundException ex) {
    return response(404, ErrorCatalog.NOT_FOUND, "接口不存在");
  }

  /** Redis 会话/限流后端不可用：受保护入口安全拒绝 503，不回退 PG 或冒充密码错误。 */
  @ExceptionHandler({SessionStoreUnavailableException.class, RateLimitUnavailableException.class})
  public ResponseEntity<ErrorBody> dependencyUnavailable(RuntimeException ex) {
    return response(503, ErrorCatalog.SERVICE_UNAVAILABLE, "服务暂时不可用，请稍后再试");
  }

  /** 兜底：内部故障记一份安全诊断，响应只给安全提示。 */
  @ExceptionHandler(Exception.class)
  public ResponseEntity<ErrorBody> internal(Exception ex) {
    SafeDiagnostics.logUnhandled(ex);
    return response(500, ErrorCatalog.INTERNAL, "服务暂时不可用");
  }

  /** 容器转发到 /error 的请求（如 404）：按状态码映射。 */
  @RequestMapping("/error")
  public ResponseEntity<ErrorBody> error(HttpServletRequest request) {
    Object value = request.getAttribute(RequestDispatcher.ERROR_STATUS_CODE);
    int status = value instanceof Integer code ? code : 500;
    return response(
        status, ErrorBody.forStatus(status).code(), ErrorBody.forStatus(status).message());
  }

  private static ResponseEntity<ErrorBody> response(int status, String code, String message) {
    return ResponseEntity.status(status)
        .header(HttpHeaders.CACHE_CONTROL, "no-store")
        .header("X-Content-Type-Options", "nosniff")
        .header("Referrer-Policy", "no-referrer")
        .header("X-Frame-Options", "DENY")
        .body(new ErrorBody(code, message));
  }

  /** 仅按异常类名/包判定 JSON 语法或读取错误，避免依赖具体 Jackson 异常包名。 */
  private static boolean isJsonSyntaxError(Throwable ex) {
    Throwable t = ex;
    int depth = 0;
    while (t != null && depth++ < 10) {
      String name = t.getClass().getName();
      if (name.startsWith("tools.jackson.core.exc.")
          || name.contains("JsonParseException")
          || name.contains("StreamReadException")
          || name.contains("UnexpectedEndOfInput")) {
        return true;
      }
      t = t.getCause();
    }
    return false;
  }
}
