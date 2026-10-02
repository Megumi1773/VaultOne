import 'dart:convert';
import 'dart:typed_data';

import '../rust/api/browser.dart' as rbrowser;
import '../rust/api/clipboard.dart' as rclip;
import '../rust/api/cloud_account.dart' as rcloud;
import '../rust/api/conflicts.dart' as rconflicts;
import '../rust/api/feedback.dart' as rfeedback;
import '../rust/api/logging.dart' as rlog;
import '../rust/api/screenshot.dart' as rscreenshot;
import '../rust/api/sync.dart' as rsync;
import '../rust/api/tools.dart' as rtools;
import '../rust/api/vault.dart' as rvault;
import 'conflict_models.dart';
import 'config.dart';
import 'feedback_models.dart';
import 'ffi.dart';
import 'health_models.dart';
import 'import_models.dart';
import 'models.dart';

export '../rust/api/sync.dart' show DeviceDto, AuditEventDto, RemoteStatusDto, SyncReportDto;

/// Rust 内核（vault-core，经 flutter_rust_bridge）的强类型门面。
///
/// UI 只依赖本类；所有 [BridgeError] 在此统一转换为 [CoreException]。
abstract final class VaultApi {
  static const privacyVersion = '2026-09';

  /// 锁定使所有未完成的敏感读取失效；旧结果不得交给页面或回填状态。
  static int sessionEpoch = 0;
  static void invalidateSession() => sessionEpoch++;

  static Future<T> _session<T>(Future<T> Function() call) async {
    final epoch = sessionEpoch;
    final result = await guard(call);
    if (epoch != sessionEpoch) {
      throw CoreException('session_expired', '保险库已锁定，请重新解锁后操作');
    }
    return result;
  }

  /// 所有远程入口共用持久化同意门禁，包括页面直调和独立自动填充引擎。
  /// 默认拒绝；读取失败也不会发起网络请求。
  static Future<T> _network<T>(Future<T> Function() call, {bool boundAccount = true}) => _session(() async {
        final epoch = sessionEpoch;
        if (await getSetting('privacy_consent') != privacyVersion) {
          throw CoreException('privacy_required', '请先阅读并同意隐私政策与用户协议');
        }
        if (epoch != sessionEpoch) {
          throw CoreException('session_expired', '保险库已锁定，请重新解锁后操作');
        }
        final selected = AppConfig.serverUrl(await getSetting('server_url') ?? AppConfig.defaultServerUrl);
        await rsync.configureDevelopmentHttp(serverUrl: AppConfig.developmentHttpServer(selected));
        if (boundAccount) {
          final remote = await rsync.remoteStatus();
          if (remote != null && remote.serverUrl.replaceFirst(RegExp(r'/+$'), '') != selected) {
            throw CoreException('server_mismatch', '本机账户绑定的服务器与 Java 配置不同，请先重新验证并确认连接');
          }
        }
        if (epoch != sessionEpoch) {
          throw CoreException('session_expired', '保险库已锁定，请重新解锁后操作');
        }
        return call();
      });

  static List<VaultItem> _items(String json) =>
      [for (final i in jsonDecode(json) as List) VaultItem.fromJson((i as Map).cast<String, dynamic>())];

  static VaultItem _item(String json) => VaultItem.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());

  static Enrollment _enrollment(rvault.EnrollmentDto e) =>
      Enrollment(accountId: e.accountId, email: e.email, secretKey: e.secretKey, recoveryCode: e.recoveryCode);

  // ---------- 生命周期 ----------

  static Future<void> initLogging(String dir, {bool verbose = false}) =>
      guard(() => rlog.initLogging(logDir: dir, verbose: verbose));

  /// 写一条日志。
  ///
  /// **日志失败一律吞掉**：调用点经常在 `catch` 里，如果写日志自己再抛异常，原始错误会被
  /// 后一个异常盖掉，排查时看到的就是一个完全无关的报错。日志是诊断手段，不是业务逻辑。
  static void log(String message, {String level = 'info'}) {
    try {
      rlog.logEvent(level: level, message: message);
    } catch (_) {
      // 桥未初始化或日志系统不可用时无路可写，只能放弃这条日志。
    }
  }

  static Future<void> open(String path) => guard(() => rvault.openVault(path: path));

  static Future<rvault.VaultStatus> status() => guard(rvault.status);

  static Future<Enrollment> prepareCloudRegistration(String server, String email, String password, String device) =>
      _network(() async => _enrollment(await rcloud.prepareRegistration(serverUrl: server, email: email, password: password, deviceName: device)), boundAccount: false);

  static Future<Enrollment?> completeCloudRegistration(String server, String password, String secretKey, String device) =>
      _network(() async {
        final value = await rcloud.completeRegistration(serverUrl: server, password: password, secretKey: secretKey, deviceName: device);
        return value == null ? null : _enrollment(value);
      }, boundAccount: false);

  static Future<Enrollment?> pendingCloudEnrollment() => _session(() async {
    final value = await rcloud.pendingEnrollment();
    return value == null ? null : _enrollment(value);
  });
  static Future<String?> pendingCloudOperation() => _session(rcloud.pendingOperation);
  static Future<void> confirmCloudEnrollment() => _session(rcloud.confirmEnrollment);

  static Future<void> logoutCloud() => _network(rcloud.logout);

  static Future<void> reconnectCloud(String server, String password, String secretKey) =>
      _network(() => rcloud.reconnect(serverUrl: server, password: password, secretKey: secretKey), boundAccount: false);

  static Future<void> unlock(String password, String secretKey) =>
      guard(() => rvault.unlock(password: password, secretKey: secretKey));

  static Future<void> unlockWithQuickKey(List<int> key) => guard(() => rvault.unlockWithQuickKey(key: key));

  static Future<List<int>> enableQuickUnlock() => _session(rvault.enableQuickUnlock);

  static Future<void> disableQuickUnlock() => guard(rvault.disableQuickUnlock);

  static Future<void> verifyMasterPassword(String password, String secretKey) =>
      _session(() => rvault.verifyMasterPassword(password: password, secretKey: secretKey));

  /// 备份二次确认：把用户重输的 Secret Key 与本机保存的做逐字节比对。
  ///
  /// 解析后的 30 字节必须完全一致；大小写、分组连字符、空白与 I/L/O 的手抄差异被容忍。
  /// 不一致抛 `secret_key_mismatch`。成功返回本机 Secret Key 的规范形态。
  static Future<String> verifySecretKey(String stored, String candidate) =>
      _session(() => rvault.verifySecretKey(stored: stored, candidate: candidate));

  /// 恢复码规范化：本机不保存恢复码字节，只校验 Crockford Base32 格式并返回规范形态。
  static Future<String> canonicalRecoveryCode(String candidate) =>
      _session(() => rvault.canonicalRecoveryCode(candidate: candidate));

  static Future<void> lock() => guard(rvault.lock);

  static Future<AccountInfo> account() => _session(() async {
        final a = await rvault.accountInfo();
        return AccountInfo(
          accountId: a.accountId,
          email: a.email,
          kdfSummary: a.kdfSummary,
          pendingChanges: a.pendingChanges.toInt(),
          itemCount: a.itemCount.toInt(),
        );
      });

  static Future<void> changePassword(String current, String secretKey, String newPassword) =>
      _network(() => rcloud.changePassword(current: current, secretKey: secretKey, newPassword: newPassword));

  static Future<void> wipeLocal() => guard(rvault.wipeLocal);

  // ---------- 条目 ----------

  static Future<List<VaultItem>> listItems() => _session(() async => _items(await rvault.listItems()));

  static Future<List<VaultItem>> listTrash() => _session(() async => _items(await rvault.listTrash()));

  static Future<VaultItem> createItem(ItemData data) =>
      _session(() async => _item(await rvault.createItem(dataJson: jsonEncode(data.toJson()))));

  static Future<VaultItem> updateItem(String id, ItemData data) =>
      _session(() async => _item(await rvault.updateItem(id: id, dataJson: jsonEncode(data.toJson()))));

  static Future<void> deleteItem(String id) => _session(() => rvault.deleteItem(id: id));

  static Future<void> restoreItem(String id) => _session(() => rvault.restoreItem(id: id));

  /// 从回收站彻底删除（本机物理抹除，不可恢复）。要求该条目的删除已同步。
  static Future<void> purgeItem(String id) => _session(() => rvault.purgeItem(id: id));

  /// 清空回收站：逐条抹除已同步条目，未同步的保留。返回 (已抹除, 保留)。
  static Future<({int purged, int kept})> emptyTrash() => _session(() async {
        final r = await rvault.emptyTrash();
        return (purged: r.purged.toInt(), kept: r.kept.toInt());
      });

  /// 分类树。聚合规则在内核实现一处，界面直接消费，避免两处各写一份计数逻辑。
  static Future<List<CategoryNode>> categoryTree() => _session(() async {
        final raw = jsonDecode(await rvault.categoryTree()) as List;
        return [for (final node in raw) CategoryNode.fromJson((node as Map).cast())];
      });

  // ---------- 标签与分类的批量管理（§3.6）----------
  // 四个操作都在内核完成改写并返回受影响条目数；界面只负责确认与展示。

  /// 标签改名（不区分大小写匹配；改成已存在的标签等于合并）。
  static Future<int> renameTag(String from, String to) =>
      _session(() async => (await rvault.taxonomyRenameTag(from: from, to: to)).toInt());

  static Future<int> deleteTag(String tag) =>
      _session(() async => (await rvault.taxonomyDeleteTag(tag: tag)).toInt());

  /// 分类改名（前缀改写，子分类一并跟着走）。
  static Future<int> renameCategory(String from, String to) =>
      _session(() async => (await rvault.taxonomyRenameCategory(from: from, to: to)).toInt());

  /// 清空分类（含子分类）的归属，不删条目。
  static Future<int> clearCategory(String path) =>
      _session(() async => (await rvault.taxonomyClearCategory(path: path)).toInt());

  static Future<List<AuditFinding>> audit() => _session(() async => [
        for (final f in await rvault.auditLocal())
          AuditFinding(itemId: f.itemId, weak: f.weak, score: f.score, reusedWith: f.reusedWith),
      ]);

  /// HIBP k-匿名泄露检测（在 Rust 侧发起请求），返回 条目 ID → 泄露次数。
  static Future<Map<String, int>> checkBreaches(List<String> itemIds) => _network(() async => {
        for (final r in await rvault.checkBreaches(itemIds: itemIds)) r.itemId: r.count.toInt(),
      });

  /// 安全体检（计划书 §5.1 / §5.2）。打分、任务清单与发现项规则全在内核，
  /// 这里只传输入并解析结果。
  static Future<HealthOverview> healthCheckup({
    required Map<String, int> breaches,
    required BreachStatus breachStatus,
    required Map<String, Object?> settings,
  }) =>
      _session(() async {
        final raw = await rvault.healthCheckup(
          breachesJson: jsonEncode(breaches),
          breachStatus: breachStatus.wire,
          settingsJson: jsonEncode(settings),
        );
        return HealthOverview.fromJson((jsonDecode(raw) as Map).cast());
      });

  static Future<List<String>> matchItems(String pageUrl) => _session(() => rvault.matchItems(pageUrl: pageUrl));

  static Future<String?> getSetting(String key) => guard(() => rvault.getSetting(key: key));

  static Future<void> setSetting(String key, String value) => guard(() => rvault.setSetting(key: key, value: value));

  /// 导入其他密码管理器的导出文件（CSV / 1PIF，格式由内核自动识别）。
  /// `source` 只用于历史记录（一般是文件名）。
  static Future<ImportSummary> importItems(String content, {String source = ''}) => _session(() async {
        final s = await rvault.importItems(content: content, source: source);
        return (format: s.format, added: s.added, updated: s.updated, duplicates: s.duplicates, skipped: s.skipped);
      });

  /// 导入预览（计划书 §3.7）：解析但不入库，供界面核对与调整列映射。
  static Future<ImportPreview> importPreview(String content, {ColumnMapping? mapping}) =>
      _session(() async {
        final raw = await rvault.importPreview(
          content: content,
          mappingJson: mapping == null ? '' : jsonEncode(mapping.toJson()),
        );
        return ImportPreview.fromJson((jsonDecode(raw) as Map).cast());
      });

  /// 按覆盖策略导入。
  static Future<ImportSummary> importItemsWith(
    String content, {
    ColumnMapping? mapping,
    ImportStrategy strategy = ImportStrategy.skip,
    String source = '',
  }) =>
      _session(() async {
        final s = await rvault.importItemsWith(
          content: content,
          mappingJson: mapping == null ? '' : jsonEncode(mapping.toJson()),
          strategy: strategy.wire,
          source: source,
        );
        return (format: s.format, added: s.added, updated: s.updated, duplicates: s.duplicates, skipped: s.skipped);
      });

  /// 导出加密备份包（`.wljbak`）字节流。
  static Future<Uint8List> exportBackup() => _session(rvault.exportBackup);

  /// 从加密备份包导入。
  static Future<ImportSummary> importBackup(Uint8List data, {String source = ''}) => _session(() async {
        final s = await rvault.importBackup(data: data, source: source);
        return (format: s.format, added: s.added, updated: s.updated, duplicates: s.duplicates, skipped: s.skipped);
      });

  /// 导出为明文 CSV（迁移用）。
  static Future<String> exportCsv() => _session(rvault.exportCsv);

  /// 导入 / 导出历史（§3.7）。本机记录、密封存放、不参与同步。
  static Future<List<TransferRecord>> transferHistory() => _session(() async {
        final raw = jsonDecode(await rvault.transferHistory()) as List;
        return [for (final r in raw) transferRecordFromJson((r as Map).cast())];
      });

  static Future<void> clearTransferHistory() => _session(rvault.clearTransferHistory);

  // ---------- 账户资料（§8.1 / §8.2）----------

  /// 读取账户资料。**离线不报错**：返回本机缓存并置 `online=false`。
  static Future<AccountProfile> accountProfile() => _session(() async {
        final p = await rsync.accountProfile();
        return (nickname: p.nickname, avatar: p.avatar, createdAt: p.createdAt, online: p.online);
      });

  /// 更新账户资料（昵称 / 头像地址）。需要联网。
  static Future<AccountProfile> updateAccountProfile(String nickname, String avatar) => _session(() async {
        final p = await rsync.updateAccountProfile(nickname: nickname, avatar: avatar);
        return (nickname: p.nickname, avatar: p.avatar, createdAt: p.createdAt, online: p.online);
      });

  // ---------- 本机冲突裁决 ----------

  static Future<List<ConflictDetail>> listConflicts(bool includeHistory) => _session(() async => [
        for (final value in jsonDecode(await rconflicts.listConflicts(includeHistory: includeHistory)) as List)
          ConflictDetail.fromJson((value as Map).cast<String, dynamic>()),
      ]);

  static Future<ConflictDetail> getConflict(String id) => _session(() async =>
      ConflictDetail.fromJson((jsonDecode(await rconflicts.getConflict(id: id)) as Map).cast<String, dynamic>()));

  static Future<ConflictDetail> refreshConflict(String id) => _session(() async =>
      ConflictDetail.fromJson((jsonDecode(await rconflicts.refreshConflict(id: id)) as Map).cast<String, dynamic>()));

  static Future<void> resolveConflict(String id, ConflictResolution resolution) => _session(() =>
      rconflicts.resolveConflict(id: id, resolutionJson: jsonEncode(resolution.toJson())));

  // ---------- 主动反馈 ----------

  static Future<String> newFeedbackId() => _session(rfeedback.newFeedbackId);

  static Future<FeedbackDetail> submitFeedback(FeedbackSubmission request) => _network(() async =>
      FeedbackDetail.fromJson((jsonDecode(await rfeedback.submitFeedback(requestJson: jsonEncode(request.toJson()))) as Map).cast<String, dynamic>()));

  static Future<FeedbackPageResult> listFeedback(int? before) => _network(() async =>
      FeedbackPageResult.fromJson((jsonDecode(await rfeedback.listFeedback(before: before, limit: 20)) as Map).cast<String, dynamic>()));

  static Future<FeedbackDetail> getFeedback(String id) => _network(() async =>
      FeedbackDetail.fromJson((jsonDecode(await rfeedback.getFeedback(id: id)) as Map).cast<String, dynamic>()));

  // ---------- 浏览器扩展（仅桌面端）----------

  /// 启动本地通道；返回的流推送待用户批准的配对请求。
  static Stream<PairingRequest> startBrowserBridge() =>
      rbrowser.startBrowserBridge().map((r) => (clientId: r.clientId, name: r.name, code: r.code));

  static Future<void> stopBrowserBridge() => guard(rbrowser.stopBrowserBridge);

  static Future<void> respondPairing(String clientId, bool approved) =>
      guard(() => rbrowser.respondPairing(clientId: clientId, approved: approved));

  static Future<List<BrowserClient>> browserClients() => _session(() async => [
        for (final c in await rbrowser.listBrowserClients())
          (id: c.id, name: c.name, createdAt: c.createdAt.toInt(), lastUsedAt: c.lastUsedAt.toInt()),
      ]);

  static Future<void> removeBrowserClient(String id) => guard(() => rbrowser.removeBrowserClient(id: id));

  /// 在 Chrome / Edge / Chromium / Brave 中登记 Native Messaging 宿主，返回清单路径。
  static Future<String> registerNativeHost() => guard(rbrowser.registerNativeHost);

  // ---------- 同步 ----------

  static Future<rsync.RemoteStatusDto?> remoteStatus() => _session(rsync.remoteStatus);

  static Future<void> pingServer(String url) => _network(() => rsync.pingServer(serverUrl: AppConfig.serverUrl(url)), boundAccount: false);

  static Future<rsync.SyncReportDto> connectRegister(String url, String deviceName) =>
      _network(() => rsync.connectRegister(serverUrl: url, deviceName: deviceName));

  static Future<bool> loginExisting(String url, String email, String password, String secretKey, String deviceName) =>
      _network(() => rsync.loginExisting(serverUrl: AppConfig.serverUrl(url), email: email, password: password, secretKey: secretKey, deviceName: deviceName), boundAccount: false);

  static Future<void> verifyNewDevice(String code) => _network(() => rsync.verifyNewDevice(code: code));

  static Future<bool> checkNewDeviceApproved() => _network(rsync.checkNewDeviceApproved);

  static Future<rsync.SyncReportDto> syncNow() => _network(rsync.syncNow);

  static Future<void> reconnect(String password, String secretKey) =>
      _network(() => rsync.reconnect(password: password, secretKey: secretKey));

  static Future<void> disconnect() => _network(rsync.disconnect);

  static Future<void> deleteRemoteAccount(String password, String secretKey) =>
      _network(() => rsync.deleteRemoteAccount(password: password, secretKey: secretKey));

  static Future<List<rsync.DeviceDto>> listDevices() => _network(rsync.listDevices);

  static Future<void> approveDevice(String id) => _network(() => rsync.approveDevice(deviceId: id));

  static Future<void> revokeDevice(String id) => _network(() => rsync.revokeDevice(deviceId: id));

  static Future<List<rsync.AuditEventDto>> auditEvents() => _network(rsync.auditEvents);

  static Future<Enrollment> recoverFromServer(
          String url, String email, String recoveryCode, String secretKey, String newPassword, String deviceName) =>
      _network(() async => _enrollment(await rcloud.recover(
            serverUrl: AppConfig.serverUrl(url),
            email: email,
            recoveryCode: recoveryCode,
            secretKey: secretKey,
            newPassword: newPassword,
            deviceName: deviceName,
          )), boundAccount: false);

  // ---------- 同步调用（微秒级） ----------

  static TotpCode totp(TotpConfig config) => guardSync(() {
        final c = rtools.totpCode(
          spec: rtools.TotpSpec(secret: config.secret, alg: config.alg, digits: config.digits, period: config.period),
          unixTime: BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000),
        );
        return TotpCode(c.code, c.remaining, c.period);
      });

  static ({TotpConfig config, String? issuer, String? account}) parseTotp(String text) => guardSync(() {
        final p = rtools.parseTotp(text: text);
        return (
          config: TotpConfig(secret: p.spec.secret, alg: p.spec.alg, digits: p.spec.digits, period: p.spec.period),
          issuer: p.issuer,
          account: p.account,
        );
      });

  static Generated generatePassword({
    int length = 20,
    bool lowercase = true,
    bool uppercase = true,
    bool digits = true,
    bool symbols = true,
    bool excludeAmbiguous = true,
  }) =>
      guardSync(() {
        final g = rtools.generatePassword(
          length: length,
          lowercase: lowercase,
          uppercase: uppercase,
          digits: digits,
          symbols: symbols,
          excludeAmbiguous: excludeAmbiguous,
        );
        return Generated(g.value, g.entropyBits);
      });

  static Generated generatePassphrase({int words = 5, String separator = '-', bool capitalize = true, bool includeNumber = true}) =>
      guardSync(() {
        final g = rtools.generatePassphrase(words: words, separator: separator, capitalize: capitalize, includeNumber: includeNumber);
        return Generated(g.value, g.entropyBits);
      });

  static Strength strength(String password, {List<String> inputs = const []}) {
    if (password.isEmpty) return Strength.empty;
    final s = rtools.passwordStrength(password: password, userInputs: inputs);
    return Strength(s.score, s.guessesLog10, s.warning);
  }

  /// 桌面端：写入剪贴板并排除剪贴板历史/云同步。返回 false 表示平台不支持。
  static bool clipboardCopySensitive(String text) => rclip.clipboardCopySensitive(text: text);

  static bool clipboardClearIfUnchanged() => rclip.clipboardClearIfUnchanged();

  /// 桌面端：开关截图保护（§8.3）。返回 false 表示平台不支持，界面据此把开关标成不可用。
  static bool setScreenshotProtection(bool enabled) => rscreenshot.setProtection(enabled: enabled);

  /// 当前平台是否支持截图保护。
  static bool screenshotProtectionSupported() => rscreenshot.isSupported();
}
