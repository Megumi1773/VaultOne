import 'dart:convert';

import '../rust/api/clipboard.dart' as rclip;
import '../rust/api/logging.dart' as rlog;
import '../rust/api/sync.dart' as rsync;
import '../rust/api/tools.dart' as rtools;
import '../rust/api/vault.dart' as rvault;
import 'ffi.dart';
import 'models.dart';

export '../rust/api/sync.dart' show DeviceDto, AuditEventDto, RemoteStatusDto, SyncReportDto;

/// Rust 内核（vault-core，经 flutter_rust_bridge）的强类型门面。
///
/// UI 只依赖本类；所有 [BridgeError] 在此统一转换为 [CoreException]。
abstract final class VaultApi {
  static List<VaultItem> _items(String json) =>
      [for (final i in jsonDecode(json) as List) VaultItem.fromJson((i as Map).cast<String, dynamic>())];

  static VaultItem _item(String json) => VaultItem.fromJson((jsonDecode(json) as Map).cast<String, dynamic>());

  static Enrollment _enrollment(rvault.EnrollmentDto e) =>
      Enrollment(accountId: e.accountId, email: e.email, secretKey: e.secretKey, recoveryCode: e.recoveryCode);

  // ---------- 生命周期 ----------

  static Future<void> initLogging(String dir, {bool verbose = false}) =>
      guard(() => rlog.initLogging(logDir: dir, verbose: verbose));

  static void log(String message, {String level = 'info'}) => rlog.logEvent(level: level, message: message);

  static Future<void> open(String path) => guard(() => rvault.openVault(path: path));

  static Future<rvault.VaultStatus> status() => guard(rvault.status);

  static Future<Enrollment> createAccount(String email, String password) =>
      guard(() async => _enrollment(await rvault.createAccount(email: email, password: password)));

  static Future<void> unlock(String password, String secretKey) =>
      guard(() => rvault.unlock(password: password, secretKey: secretKey));

  static Future<void> unlockWithQuickKey(List<int> key) => guard(() => rvault.unlockWithQuickKey(key: key));

  static Future<List<int>> enableQuickUnlock() => guard(rvault.enableQuickUnlock);

  static Future<void> disableQuickUnlock() => guard(rvault.disableQuickUnlock);

  static Future<void> verifyMasterPassword(String password, String secretKey) =>
      guard(() => rvault.verifyMasterPassword(password: password, secretKey: secretKey));

  static Future<void> lock() => guard(rvault.lock);

  static Future<AccountInfo> account() => guard(() async {
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
      guard(() => rvault.changePassword(current: current, secretKey: secretKey, newPassword: newPassword));

  static Future<Enrollment> recover(String recoveryCode, String secretKey, String newPassword) => guard(() async =>
      _enrollment(await rvault.recoverLocal(recoveryCode: recoveryCode, secretKey: secretKey, newPassword: newPassword)));

  static Future<void> wipeLocal() => guard(rvault.wipeLocal);

  // ---------- 条目 ----------

  static Future<List<VaultItem>> listItems() => guard(() async => _items(await rvault.listItems()));

  static Future<List<VaultItem>> listTrash() => guard(() async => _items(await rvault.listTrash()));

  static Future<VaultItem> createItem(ItemData data) =>
      guard(() async => _item(await rvault.createItem(dataJson: jsonEncode(data.toJson()))));

  static Future<VaultItem> updateItem(String id, ItemData data) =>
      guard(() async => _item(await rvault.updateItem(id: id, dataJson: jsonEncode(data.toJson()))));

  static Future<void> deleteItem(String id) => guard(() => rvault.deleteItem(id: id));

  static Future<void> restoreItem(String id) => guard(() => rvault.restoreItem(id: id));

  static Future<List<AuditFinding>> audit() => guard(() async => [
        for (final f in await rvault.auditLocal())
          AuditFinding(itemId: f.itemId, weak: f.weak, score: f.score, reusedWith: f.reusedWith),
      ]);

  /// HIBP k-匿名泄露检测（在 Rust 侧发起请求），返回 条目 ID → 泄露次数。
  static Future<Map<String, int>> checkBreaches(List<String> itemIds) => guard(() async => {
        for (final r in await rvault.checkBreaches(itemIds: itemIds)) r.itemId: r.count.toInt(),
      });

  static Future<List<String>> matchItems(String pageUrl) => guard(() => rvault.matchItems(pageUrl: pageUrl));

  static Future<String?> getSetting(String key) => guard(() => rvault.getSetting(key: key));

  static Future<void> setSetting(String key, String value) => guard(() => rvault.setSetting(key: key, value: value));

  // ---------- 同步 ----------

  static Future<rsync.RemoteStatusDto?> remoteStatus() => guard(rsync.remoteStatus);

  static Future<void> pingServer(String url) => guard(() => rsync.pingServer(serverUrl: url));

  static Future<rsync.SyncReportDto> connectRegister(String url, String deviceName) =>
      guard(() => rsync.connectRegister(serverUrl: url, deviceName: deviceName));

  static Future<bool> loginExisting(String url, String email, String password, String secretKey, String deviceName) =>
      guard(() => rsync.loginExisting(serverUrl: url, email: email, password: password, secretKey: secretKey, deviceName: deviceName));

  static Future<void> verifyNewDevice(String code) => guard(() => rsync.verifyNewDevice(code: code));

  static Future<bool> checkNewDeviceApproved() => guard(rsync.checkNewDeviceApproved);

  static Future<rsync.SyncReportDto> syncNow() => guard(rsync.syncNow);

  static Future<void> reconnect(String password, String secretKey) =>
      guard(() => rsync.reconnect(password: password, secretKey: secretKey));

  static Future<void> disconnect() => guard(rsync.disconnect);

  static Future<void> deleteRemoteAccount(String password, String secretKey) =>
      guard(() => rsync.deleteRemoteAccount(password: password, secretKey: secretKey));

  static Future<List<rsync.DeviceDto>> listDevices() => guard(rsync.listDevices);

  static Future<void> approveDevice(String id) => guard(() => rsync.approveDevice(deviceId: id));

  static Future<void> revokeDevice(String id) => guard(() => rsync.revokeDevice(deviceId: id));

  static Future<List<rsync.AuditEventDto>> auditEvents() => guard(rsync.auditEvents);

  static Future<Enrollment> recoverFromServer(
          String url, String email, String recoveryCode, String secretKey, String newPassword, String deviceName) =>
      guard(() async => _enrollment(await rsync.recoverFromServer(
            serverUrl: url,
            email: email,
            recoveryCode: recoveryCode,
            secretKey: secretKey,
            newPassword: newPassword,
            deviceName: deviceName,
          )));

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
}
