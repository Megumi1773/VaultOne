package app.vaultone.server.identity.service;

import app.vaultone.server.audit.AuditEvents;
import app.vaultone.server.audit.AuditService;
import app.vaultone.server.common.ApiException;
import app.vaultone.server.common.InstantText;
import app.vaultone.server.common.MailSender;
import app.vaultone.server.config.VaultOneProperties;
import app.vaultone.server.crypto.ServerKeys;
import app.vaultone.server.crypto.Srp6a;
import app.vaultone.server.identity.model.UserEntity;
import app.vaultone.server.identity.repository.DeviceOtpRepository;
import app.vaultone.server.identity.repository.DeviceRepository;
import app.vaultone.server.identity.repository.HandshakeRepository;
import app.vaultone.server.identity.repository.IdentityBootstrapRepository;
import app.vaultone.server.identity.repository.OtpVerification;
import app.vaultone.server.identity.repository.SessionRevocation;
import app.vaultone.server.identity.repository.UserRepository;
import app.vaultone.server.proto.AccountKeys;
import app.vaultone.server.proto.Bytes;
import app.vaultone.server.proto.DeviceInfo;
import app.vaultone.server.proto.KdfParams;
import app.vaultone.server.proto.LoginFinishRequest;
import app.vaultone.server.proto.LoginFinishResponse;
import app.vaultone.server.proto.LoginStartRequest;
import app.vaultone.server.proto.LoginStartResponse;
import app.vaultone.server.proto.RegisterRequest;
import app.vaultone.server.proto.SessionInfo;
import app.vaultone.server.proto.VerifyDeviceRequest;
import app.vaultone.server.security.Authed;
import app.vaultone.server.security.SessionIssuer;
import app.vaultone.server.security.SessionStore;
import app.vaultone.server.validate.WireValidation;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.UUID;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import tools.jackson.databind.json.JsonMapper;

/** 注册、SRP 登录两阶段、设备验证、登出、恢复。协议语义逐项对齐 {@code routes_auth.rs}。 */
@Service
public class IdentityService {
  private static final SecureRandom RANDOM = new SecureRandom();

  private final UserRepository users;
  private final DeviceRepository devices;
  private final HandshakeRepository handshakes;
  private final DeviceOtpRepository otps;
  private final RegistrationPersistence persistence;
  private final IdentityBootstrapRepository bootstrap;
  private final AccountContext accountContext;
  private final LoginPersistence loginPersistence;
  private final OtpVerification otpVerification;
  private final SessionRevocation revocation;
  private final RecoveryPersistence recoveryPersistence;
  private final SrpConcurrency srpConcurrency;
  private final SessionIssuer sessionIssuer;
  private final SessionStore sessionStore;
  private final AuditService audit;
  private final MailSender mailer;
  private final JsonMapper json;
  private final ServerKeys keys;
  private final VaultOneProperties.Session session;
  private final boolean allowTestKdf;

  public IdentityService(
      UserRepository users,
      DeviceRepository devices,
      HandshakeRepository handshakes,
      DeviceOtpRepository otps,
      RegistrationPersistence persistence,
      IdentityBootstrapRepository bootstrap,
      AccountContext accountContext,
      LoginPersistence loginPersistence,
      OtpVerification otpVerification,
      SessionRevocation revocation,
      RecoveryPersistence recoveryPersistence,
      SrpConcurrency srpConcurrency,
      SessionIssuer sessionIssuer,
      SessionStore sessionStore,
      AuditService audit,
      MailSender mailer,
      JsonMapper json,
      ServerKeys keys,
      VaultOneProperties properties) {
    this.users = users;
    this.devices = devices;
    this.handshakes = handshakes;
    this.otps = otps;
    this.persistence = persistence;
    this.bootstrap = bootstrap;
    this.accountContext = accountContext;
    this.loginPersistence = loginPersistence;
    this.otpVerification = otpVerification;
    this.revocation = revocation;
    this.recoveryPersistence = recoveryPersistence;
    this.srpConcurrency = srpConcurrency;
    this.sessionIssuer = sessionIssuer;
    this.sessionStore = sessionStore;
    this.audit = audit;
    this.mailer = mailer;
    this.json = json;
    this.keys = keys;
    this.session = properties.session();
    this.allowTestKdf = properties.development().allowTestKdf();
  }

  // ───────────────────────── 注册 ─────────────────────────
  public LoginFinishResponse register(RegisterRequest req, byte[] ipHash, String requestId) {
    WireValidation.email(req.email());
    AccountKeys k = req.keys();
    WireValidation.uuid(k.accountId(), "account_id");
    WireValidation.uuid(k.vaultId(), "vault_id");
    WireValidation.kdfLenient(k.kdf(), allowTestKdf);
    WireValidation.srp(req.srpSalt().toByteArray(), req.srpVerifier().toByteArray());
    WireValidation.wrappedKey(k.vkWrap().toByteArray(), "vk_wrap");
    WireValidation.wrappedKey(k.recoveryWrap().toByteArray(), "recovery_wrap");
    WireValidation.hash32(req.recoveryAuthHash().toByteArray(), "recovery_auth_hash");
    WireValidation.device(req.device());

    byte[] emailHash = keys.emailHash(req.email());
    if (bootstrap.emailExists(emailHash)) {
      throw ApiException.emailTaken();
    }
    Instant now = Instant.now();
    long vkGen = Math.max(k.vkGen(), 1);
    DeviceInfo d = req.device();
    SessionIssuer.PendingSession pending =
        sessionIssuer.prepare(k.accountId(), d.id(), 1L, true, 1L, now);
    try {
      persistence.persist(
          k.accountId(),
          emailHash,
          keys.encryptEmail(req.email()),
          jsonKdf(k.kdf()),
          req.srpSalt().toByteArray(),
          req.srpVerifier().toByteArray(),
          k.vaultId(),
          k.vkWrap().toByteArray(),
          vkGen,
          k.recoveryWrap().toByteArray(),
          req.recoveryAuthHash().toByteArray(),
          d.id(),
          ServerKeys.rustTrim(d.name()),
          d.platform().wire(),
          now,
          requestId,
          ipHash);
    } catch (RuntimeException ex) {
      sessionIssuer.abort(pending);
      if (ex instanceof DataIntegrityViolationException constraint) {
        throw classifyRegistrationConflict(constraint, emailHash, k.accountId());
      }
      throw ex;
    }

    SessionInfo sessionInfo = sessionIssuer.sessionInfo(pending, true);
    app.vaultone.server.common.AfterCommit.runSafely(
        () ->
            mailer.send(
                ServerKeys.normalizeEmail(req.email()),
                "欢迎使用 VaultOne",
                "您的 VaultOne 账户已创建，首台设备："
                    + ServerKeys.rustTrim(d.name())
                    + "。请妥善保管 Recovery Kit——我们无法为您找回主密码。"));
    AccountKeys enrolled =
        new AccountKeys(k.accountId(), k.vaultId(), k.kdf(), k.vkWrap(), vkGen, k.recoveryWrap());
    return new LoginFinishResponse(Bytes.copyOf(new byte[0]), sessionInfo, enrolled);
  }

  // ───────────────────────── 登录 start ─────────────────────────

  public LoginStartResponse loginStart(LoginStartRequest req) {
    WireValidation.email(req.email());
    byte[] emailHash = keys.emailHash(req.email());
    var accountIdFound = bootstrap.accountIdByEmailHash(emailHash);
    String accountId;
    KdfParams kdf;
    byte[] srpSalt;
    byte[] verifier;
    String userId;
    if (accountIdFound.isPresent()) {
      // 身份引导只给出账户 ID；其余列在 RLS 账户上下文内读取。
      UserEntity u = accountContext.readAccount(accountIdFound.get()).orElse(null);
      if (u != null) {
        userId = u.getId();
        accountId = u.getId();
        kdf = parseKdf(u.getKdf());
        srpSalt = u.getSrpSalt();
        verifier = u.getSrpVerifier();
      } else {
        // 账户在引导与读取之间被删除：按未知邮箱处理，不泄漏存在。
        userId = null;
        accountId = decoyAccountId(keys, req.email());
        kdf = decoyKdf(req.email());
        srpSalt = keys.decoy(req.email(), "srp-salt", 32);
        verifier = keys.decoy(req.email(), "verifier", 384);
      }
    } else {
      userId = null;
      accountId = decoyAccountId(keys, req.email());
      kdf = decoyKdf(req.email());
      srpSalt = keys.decoy(req.email(), "srp-salt", 32);
      verifier = keys.decoy(req.email(), "verifier", 384);
    }
    Srp6a.ServerStart start = srpConcurrency.run(() -> Srp6a.serverStart(verifier));
    String handshakeId = UUID.randomUUID().toString();
    byte[] bEnc = keys.sealHandshake(handshakeId, start.b());
    String expiresAt = InstantText.format(Instant.now().plusSeconds(session.handshakeTtlSeconds()));
    handshakes.insert(handshakeId, userId, bEnc, expiresAt);
    return new LoginStartResponse(
        handshakeId, accountId, kdf, Bytes.copyOf(srpSalt), Bytes.copyOf(start.bPub()));
  }

  private KdfParams decoyKdf(String email) {
    return new KdfParams(
        "argon2id",
        65536,
        3,
        4,
        java.util.Base64.getEncoder().encodeToString(keys.decoy(email, "kdf-salt", 32)));
  }

  // ───────────────────────── 登录 finish ─────────────────────────

  public LoginFinishResponse loginFinish(LoginFinishRequest req, byte[] ipHash, String requestId) {
    WireValidation.device(req.device());
    Instant now = Instant.now();
    HandshakeRepository.HandshakeRow hs =
        handshakes.claim(req.handshakeId()).orElseThrow(ApiException::authFailed);
    // 领取即删除；过期或未知邮箱的 decoy 握手一律 auth_failed（不区分，防枚举）。
    if (hs.userId() == null || InstantText.toEpochSecond(hs.expiresAt()) < now.getEpochSecond()) {
      throw ApiException.authFailed();
    }
    // 账户快照在 RLS 上下文内读取；SRP 校验用其 verifier。
    LoginPersistence.AccountSnapshot snapshot = loginPersistence.readAccount(hs.userId());
    byte[] b;
    try {
      b = keys.openHandshake(req.handshakeId(), hs.bEnc());
    } catch (RuntimeException ex) {
      throw ApiException.authFailed();
    }
    byte[] m2;
    try {
      m2 =
          srpConcurrency.run(
              () ->
                  Srp6a.serverFinish(
                      b, snapshot.srpVerifier(), req.aPub().toByteArray(), req.m1().toByteArray()));
    } catch (Srp6a.SrpException ex) {
      audit.recordFailure(
          snapshot.userId(),
          req.device().id(),
          AuditEvents.LOGIN_FAIL,
          AuditService.FAILURE,
          requestId,
          ipHash);
      throw ApiException.authFailed();
    }

    // SRP 通过后才登记/更新设备。
    String name = LoginPersistence.canonicalName(req.device().name());
    LoginPersistence.DeviceState device =
        loginPersistence.applyDevice(
            snapshot.userId(), req.device().id(), name, req.device().platform().wire());
    if (device.revoked()) {
      throw new ApiException(
          403, app.vaultone.server.common.ErrorCatalog.AUTH_FAILED, "该设备已被撤销，无法登录");
    }
    if (device.newDevice()) {
      audit.record(
          snapshot.userId(),
          req.device().id(),
          AuditEvents.DEVICE_ADDED,
          "success",
          requestId,
          ipHash);
    }
    boolean approved = device.approved();
    String email = keys.decryptEmail(snapshot.emailEnc());
    if (!approved) {
      sendDeviceOtp(snapshot.userId(), req.device().id(), email, name);
    } else {
      app.vaultone.server.common.AfterCommit.runSafely(
          () ->
              mailer.send(
                  email, "VaultOne 登录提醒", "您的账户刚刚在设备「" + name + "」上登录。如非本人操作，请立即修改主密码并撤销该设备。"));
    }
    SessionIssuer.PendingSession pending =
        sessionIssuer.prepare(
            snapshot.userId(),
            req.device().id(),
            device.deviceEpoch(),
            approved,
            snapshot.sessionEpoch(),
            now);
    SessionInfo sessionInfo = sessionIssuer.sessionInfo(pending, approved);
    audit.record(
        snapshot.userId(), req.device().id(), AuditEvents.LOGIN_OK, "success", requestId, ipHash);
    return new LoginFinishResponse(
        Bytes.copyOf(m2), sessionInfo, approved ? accountKeys(snapshot) : null);
  }

  private AccountKeys accountKeys(LoginPersistence.AccountSnapshot s) {
    return new AccountKeys(
        s.userId(),
        s.vaultId(),
        parseKdf(s.kdf()),
        Bytes.copyOf(s.vkWrap()),
        s.vkGen(),
        Bytes.copyOf(s.recoveryWrap()));
  }

  private void sendDeviceOtp(String userId, String deviceId, String email, String deviceName) {
    String code = String.format("%06d", RANDOM.nextInt(1_000_000));
    byte[] hash = keys.otpHash(userId, deviceId, code);
    otps.replace(
        userId,
        deviceId,
        hash,
        InstantText.format(Instant.now().plusSeconds(session.otpTtlSeconds())));
    mailer.send(
        email,
        "VaultOne 新设备验证码",
        "有新设备「"
            + deviceName
            + "」正在登录您的 VaultOne 账户。\n验证码："
            + code
            + "（10 分钟内有效）\n如非本人操作，请忽略本邮件并尽快修改主密码。");
  }

  // ───────────────────────── 设备验证 ─────────────────────────

  /**
   * OTP 设备验证。**本方法不开启事务**：`OtpVerification.verify` 在自身事务内提交失败计数/成功消费， 外层仅把非成功结果转成 400，避免业务异常回滚已提交的
   * attempts（此前的确定性缺陷）。
   */
  public void verifyDevice(
      Authed authed, VerifyDeviceRequest req, byte[] ipHash, String requestId) {
    if (authed.approved()) {
      return;
    }
    String code = ServerKeys.rustTrim(req.code());
    byte[] expected = keys.otpHash(authed.userId(), authed.deviceId(), code);
    OtpVerification.Result result =
        otpVerification.verify(
            authed, expected, (int) session.otpMaxAttempts(), "email-otp", ipHash, requestId);
    switch (result) {
      case SUCCESS, ALREADY_APPROVED -> {
        // 成功审计已在 OtpVerification 的事务内提交。
      }
      case MISMATCH -> throw ApiException.badRequest("验证码不正确");
      case EXPIRED_OR_EXHAUSTED -> throw expiredOtp();
    }
  }

  private ApiException expiredOtp() {
    return ApiException.badRequest("验证码已失效，请重新登录以获取新验证码");
  }

  // ───────────────────────── 登出 ─────────────────────────

  public void logout(Authed authed, byte[] ipHash, String requestId) {
    // 持久化单 session 撤销标记（不依赖 Redis 快照），再清理 Redis 索引。
    revocation.revoke(
        authed.userId(),
        authed.tokenHashHex(),
        InstantText.format(Instant.now().plusSeconds(session.ttlDays() * 86400L)));
    sessionStore.delete(authed.tokenHashHex());
    audit.record(
        authed.userId(), authed.deviceId(), AuditEvents.LOGOUT, "success", requestId, null);
  }

  // ───────────────────────── 恢复 ─────────────────────────

  public app.vaultone.server.proto.RecoveryStartResponse recoveryStart(
      app.vaultone.server.proto.RecoveryStartRequest req) {
    WireValidation.email(req.email());
    String accountId =
        bootstrap
            .accountIdByEmailHash(keys.emailHash(req.email()))
            .orElseGet(() -> decoyAccountId(keys, req.email()));
    return new app.vaultone.server.proto.RecoveryStartResponse(accountId);
  }

  public app.vaultone.server.proto.AccountResponse recoveryFetch(
      app.vaultone.server.proto.RecoveryFetchRequest req, byte[] ipHash) {
    RecoveryPersistence.RecoverySnapshot snapshot =
        recoveryPersistence.verify(req.email(), req.recoveryAuth().toByteArray(), keys, ipHash);
    return app.vaultone.server.proto.AccountResponse.keysOnly(
        ServerKeys.normalizeEmail(req.email()), snapshot.keys());
  }

  /** 无请求关联 ID 的重载（公开恢复入口不强制要求 x-request-id）。 */
  public app.vaultone.server.proto.RecoveryCompleteResponse recoveryComplete(
      app.vaultone.server.proto.RecoveryCompleteRequest req, byte[] ipHash) {
    return recoveryComplete(req, ipHash, app.vaultone.server.web.RequestIds.currentRequestId());
  }

  public app.vaultone.server.proto.RecoveryCompleteResponse recoveryComplete(
      app.vaultone.server.proto.RecoveryCompleteRequest req, byte[] ipHash, String requestId) {
    WireValidation.kdfLenient(req.kdf(), allowTestKdf);
    WireValidation.srp(req.srpSalt().toByteArray(), req.srpVerifier().toByteArray());
    WireValidation.wrappedKey(req.vkWrap().toByteArray(), "vk_wrap");
    WireValidation.wrappedKey(req.recoveryWrap().toByteArray(), "recovery_wrap");
    WireValidation.hash32(req.recoveryAuthHash().toByteArray(), "recovery_auth_hash");
    WireValidation.device(req.device());
    // 读取当前快照（无上下文，走引导函数），记录旧 epoch/vk_gen/旧恢复哈希用于 CAS。
    RecoveryPersistence.PreState pre =
        recoveryPersistence.preState(req.email(), req.recoveryAuth().toByteArray(), keys, ipHash);
    Instant now = Instant.now();
    // 跨存储签发：先生成候选 token 并把元数据写 Redis（预测恢复后的 session_epoch = 旧值+1）；
    // Redis 失败即中止，绝不消耗恢复凭据。PG CAS 成功后才交付；失败则清理候选键。
    SessionIssuer.PendingSession pending =
        sessionIssuer.prepare(
            pre.userId(), req.device().id(), 1L, true, pre.sessionEpoch() + 1, now);
    RecoveryPersistence.Result result;
    try {
      // 事务内锁账户 + 重验旧凭据 + CAS，仅一胜。
      result = recoveryPersistence.complete(req, pre, jsonKdf(req.kdf()), requestId, ipHash);
    } catch (RuntimeException ex) {
      sessionIssuer.abort(pending);
      throw ex;
    }
    if (!result.ok()) {
      // 并发仅一胜：另一个恢复已完成，候选 token 的 epoch 不匹配，PG 授权必然拒绝；清理候选键。
      sessionIssuer.abort(pending);
      throw ApiException.authFailed();
    }
    SessionInfo sessionInfo = sessionIssuer.sessionInfo(pending, true);
    app.vaultone.server.common.AfterCommit.runSafely(
        () ->
            mailer.send(
                ServerKeys.normalizeEmail(req.email()),
                "VaultOne 账户已通过 Recovery Kit 恢复",
                "您的账户刚刚使用 Recovery Kit 重设了主密码，所有其他设备已被登出。如非本人操作，请立即联系我们。"));
    return new app.vaultone.server.proto.RecoveryCompleteResponse(sessionInfo, result.keys());
  }

  // ───────────────────────── 辅助 ─────────────────────────

  /**
   * 分类注册时的完整性约束冲突：仅当冲突确为邮箱唯一约束或账户 ID 主键时才映射，避免把任意数据库错误 一律当成 409 email_taken。判定依据约束名/列名（PG
   * 错误文本含约束标识），其余按内部错误处理。
   */
  private ApiException classifyRegistrationConflict(
      DataIntegrityViolationException ex, byte[] emailHash, String accountId) {
    String detail = rootMessage(ex).toLowerCase(java.util.Locale.ROOT);
    if (detail.contains("users_email_hash_key") || detail.contains("email_hash")) {
      return ApiException.emailTaken();
    }
    if (detail.contains("users_pkey")
        || (detail.contains("duplicate key") && detail.contains("users"))) {
      // 账户 ID 冲突（同 id 已存在）：不覆盖，按冲突回报。
      return ApiException.conflict("账户 ID 已存在");
    }
    // 未知完整性错误：不伪装成 email_taken。
    return ApiException.internal();
  }

  private static String rootMessage(Throwable t) {
    Throwable cur = t;
    while (cur.getCause() != null && cur.getCause() != cur) {
      cur = cur.getCause();
    }
    return cur.getMessage() == null ? "" : cur.getMessage();
  }

  AccountKeys keysOf(UserEntity u) {
    return new AccountKeys(
        u.getId(),
        u.getVaultId(),
        parseKdf(u.getKdf()),
        Bytes.copyOf(u.getVkWrap()),
        u.getVkGen(),
        Bytes.copyOf(u.getRecoveryWrap()));
  }

  KdfParams parseKdf(String json) {
    try {
      return this.json.readValue(json, KdfParams.class);
    } catch (RuntimeException ex) {
      throw ApiException.internal();
    }
  }

  String jsonKdf(KdfParams kdf) {
    try {
      return this.json.writeValueAsString(kdf);
    } catch (RuntimeException ex) {
      throw ApiException.internal();
    }
  }

  /** 未注册邮箱的确定性伪造 account_id：取 decoy 16B 并设置 UUID v4/variant 位。 */
  static String decoyAccountId(ServerKeys keys, String email) {
    byte[] raw = keys.decoy(email, "account-id", 16);
    raw[6] = (byte) ((raw[6] & 0x0F) | 0x40);
    raw[8] = (byte) ((raw[8] & 0x3F) | 0x80);
    java.nio.ByteBuffer buffer = java.nio.ByteBuffer.wrap(raw);
    return new UUID(buffer.getLong(), buffer.getLong()).toString();
  }
}
