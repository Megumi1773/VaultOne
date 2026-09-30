package app.vaultone.server.proto;

/** 错误响应体；字段名保持 snake_case，未知字段忽略。 */
public record ErrorBody(String code, String message) {}
