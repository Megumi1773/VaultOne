package app.vaultone.server.web;

import app.vaultone.server.crypto.ServerKeys;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.MDC;
import org.springframework.web.context.request.RequestAttributes;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

/** 请求关联 ID 与客户端 IP 摘要；不盲信外部头（server.forward-headers-strategy=none）。 */
public final class RequestIds {
  public static final String HEADER = "x-request-id";

  /** 受控请求属性：过滤器写入已校验/生成的最终 ID，业务只读该值，绝不回读原始头。 */
  public static final String ATTRIBUTE = RequestIds.class.getName() + ".requestId";

  /** 日志 MDC 键；过滤器写入并在 {@code finally} 清理。 */
  public static final String MDC_KEY = "requestId";

  private RequestIds() {}

  /**
   * 当前请求的关联 ID：优先取过滤器写入的受控请求属性，其次取 MDC；均无则 null。
   *
   * <p>不直接读取 {@code x-request-id} 头，避免绕过过滤器的长度/字符校验而回显恶意值。response/log/audit 共用同一 ID。
   */
  public static String currentRequestId() {
    RequestAttributes attributes = RequestContextHolder.getRequestAttributes();
    if (attributes instanceof ServletRequestAttributes servlet) {
      Object value = servlet.getRequest().getAttribute(ATTRIBUTE);
      if (value instanceof String id && !id.isBlank()) {
        return id;
      }
    }
    String mdc = MDC.get(MDC_KEY);
    return mdc == null || mdc.isBlank() ? null : mdc;
  }

  /** 客户端 IP 的不可逆摘要（仅用于审计/告警，不可反查）；取真实连接地址。 */
  public static byte[] clientIpHash(ServerKeys keys, HttpServletRequest request) {
    String ip = request.getRemoteAddr();
    return ip == null ? null : keys.decoy(ip, "ip-hash", 16);
  }
}
