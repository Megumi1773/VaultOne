package app.vaultone.server.security;

import java.time.Instant;

/**
 * Redis 中保存的会话元数据：只含账户/设备关联、签发/续期/过期时间与代次；绝不含原始 Token、邮箱、密钥或密文。 键为 {@code SHA-256(token 文本 UTF-8)}
 * 的十六进制。
 *
 * @param userId 账户 ID
 * @param deviceId 设备 ID
 * @param sessionEpoch 签发时的账户会话代次（恢复后旧会话立即失效）
 * @param deviceEpoch 签发时的设备代次（撤销/重建设备后旧会话失效）
 * @param issuedAt 签发时间
 * @param lastRenewedAt 最近一次滑动续期时间（用于“每小时至多续一次”，不依赖 issuedAt 不变）
 * @param expiresAt 过期时间
 * @param deviceApproved 签发时设备是否已批准
 */
public record SessionMetadata(
    String userId,
    String deviceId,
    long sessionEpoch,
    long deviceEpoch,
    Instant issuedAt,
    Instant lastRenewedAt,
    Instant expiresAt,
    boolean deviceApproved) {

  /** 显式字段序列化，避免反射式存取导致格式漂移。 */
  @Override
  public String toString() {
    return "SessionMetadata[userId="
        + userId
        + ", deviceId="
        + deviceId
        + ", sessionEpoch="
        + sessionEpoch
        + ", deviceEpoch="
        + deviceEpoch
        + ", expiresAt="
        + expiresAt
        + ", deviceApproved="
        + deviceApproved
        + "]";
  }
}
