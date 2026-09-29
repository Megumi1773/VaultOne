import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../core/api.dart';
import '../core/config.dart';
import '../core/ffi.dart';
import '../core/models.dart';
import 'clipboard.dart';

enum AppPhase { loading, onboarding, locked, unlocked, error }

enum ThemeModeSetting { dark, light, system }

/// 应用设置（保存在本地库 settings 表，非敏感）。
class Settings {
  const Settings({
    this.autoLockMinutes = 10,
    this.clipboardSeconds = 30,
    this.lockOnMinimize = false,
    this.themeMode = ThemeModeSetting.system,
    this.serverUrl = AppConfig.defaultServerUrl,
    this.verboseLogs = false,
    this.closeToTray = true,
    this.globalHotkey = true,
    this.browserIntegration = true,
  });

  final int autoLockMinutes;
  final int clipboardSeconds;
  final bool lockOnMinimize;
  final ThemeModeSetting themeMode;
  final String serverUrl;
  final bool verboseLogs;

  /// 桌面端：关闭窗口时隐藏到系统托盘而非退出
  final bool closeToTray;

  /// 桌面端：全局快捷键唤起快速搜索
  final bool globalHotkey;

  /// 桌面端：允许浏览器扩展经 Native Messaging 连接
  final bool browserIntegration;

  Settings copyWith({
    int? autoLockMinutes,
    int? clipboardSeconds,
    bool? lockOnMinimize,
    ThemeModeSetting? themeMode,
    String? serverUrl,
    bool? verboseLogs,
    bool? closeToTray,
    bool? globalHotkey,
    bool? browserIntegration,
  }) =>
      Settings(
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        clipboardSeconds: clipboardSeconds ?? this.clipboardSeconds,
        lockOnMinimize: lockOnMinimize ?? this.lockOnMinimize,
        themeMode: themeMode ?? this.themeMode,
        serverUrl: serverUrl ?? this.serverUrl,
        verboseLogs: verboseLogs ?? this.verboseLogs,
        closeToTray: closeToTray ?? this.closeToTray,
        globalHotkey: globalHotkey ?? this.globalHotkey,
        browserIntegration: browserIntegration ?? this.browserIntegration,
      );
}

/// 系统安全存储（Windows DPAPI/凭据管理器、macOS/iOS Keychain、Android Keystore）。
/// 只保存两样东西：设备 Secret Key、生物识别快速解锁密钥。
class SecureStore {
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  static String _sk(String accountId) => 'vaultone.secret_key.$accountId';
  static String _qk(String accountId) => 'vaultone.quick_unlock.$accountId';

  static Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      VaultApi.log('secure storage read failed: ${e.runtimeType}', level: 'warn');
      return null;
    }
  }

  static Future<String?> readSecretKey(String accountId) => _read(_sk(accountId));

  static Future<void> writeSecretKey(String accountId, String secretKey) => _storage.write(key: _sk(accountId), value: secretKey);

  static Future<String?> readQuickKey(String accountId) => _read(_qk(accountId));

  static Future<void> writeQuickKey(String accountId, String hex) => _storage.write(key: _qk(accountId), value: hex);

  static Future<void> deleteQuickKey(String accountId) => _storage.delete(key: _qk(accountId));

  static Future<void> deleteAll(String accountId) async {
    await _storage.delete(key: _sk(accountId));
    await _storage.delete(key: _qk(accountId));
  }
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

enum SyncState { off, idle, syncing, error, needsReconnect }

class AppState extends ChangeNotifier {
  AppState();

  final _auth = LocalAuthentication();

  AppPhase phase = AppPhase.loading;
  String? fatalError;
  String? accountId;
  AccountInfo? account;
  bool hasStoredSecretKey = false;
  bool quickUnlockEnabled = false;
  bool biometricsAvailable = false;

  List<VaultItem> items = const [];
  List<VaultItem> trash = const [];
  Settings settings = const Settings();

  /// 注册 / 恢复完成、尚未确认保存 Recovery Kit 时持有；确认后立即丢弃。
  Enrollment? pendingEnrollment;

  /// 首次启动须同意隐私政策与用户协议（个人信息保护法 / 应用商店要求）；同意前不发起任何网络请求。
  bool privacyAccepted = false;
  static const privacyVersion = VaultApi.privacyVersion;

  int get sessionEpoch => VaultApi.sessionEpoch;
  bool isCurrentSession(int epoch) => phase == AppPhase.unlocked && epoch == sessionEpoch;

  Future<T> _withSession<T>(Future<T> Function() call) async {
    final epoch = sessionEpoch;
    void check() {
      if (!isCurrentSession(epoch)) {
        throw CoreException('session_expired', '保险库已锁定，请重新解锁后操作');
      }
    }
    check();
    final result = await call();
    check();
    return result;
  }


  /// 新设备登录：等待邮件验证码或其他设备批准。
  bool awaitingDeviceApproval = false;

  // 同步状态
  RemoteStatusDto? remote;
  SyncState syncState = SyncState.off;
  String? syncError;
  Timer? _syncDebounce;
  Timer? _syncPeriodic;

  Timer? _idleTimer;
  DateTime _lastActivity = DateTime.now();

  String get defaultDeviceName {
    try {
      final host = Platform.localHostname;
      if (host.isNotEmpty) return host.length > 60 ? host.substring(0, 60) : host;
    } catch (_) {}
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android 设备',
      TargetPlatform.iOS => 'iPhone',
      TargetPlatform.macOS => 'Mac',
      _ => 'Windows 电脑',
    };
  }

  // ---------- 生命周期 ----------

  Future<void> init(String dbPath, String logDir) async {
    try {
      await VaultApi.open(dbPath);
      await _loadSettings();
      await VaultApi.initLogging(logDir, verbose: settings.verboseLogs);
      biometricsAvailable = await _canUseBiometrics();
      await _refreshStatus();
    } catch (e) {
      fatalError = e.toString();
      phase = AppPhase.error;
      VaultApi.log('init failed: ${e is CoreException ? e.code : e.runtimeType}', level: 'error');
    }
    notifyListeners();
  }

  Future<void> _refreshStatus() async {
    final s = await VaultApi.status();
    if (!s.initialized) {
      phase = AppPhase.onboarding;
      accountId = null;
      return;
    }
    accountId = s.accountId;
    hasStoredSecretKey = (await SecureStore.readSecretKey(accountId!)) != null;
    quickUnlockEnabled = s.quickUnlockEnabled && (await SecureStore.readQuickKey(accountId!)) != null;
    phase = s.unlocked ? AppPhase.unlocked : AppPhase.locked;
  }

  Future<bool> _canUseBiometrics() async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadSettings() async {
    int intOr(String? v, int d) => int.tryParse(v ?? '') ?? d;
    final theme = await VaultApi.getSetting('theme') ?? 'system';
    final mobile = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
    settings = Settings(
      autoLockMinutes: intOr(await VaultApi.getSetting('auto_lock_minutes'), 10),
      clipboardSeconds: intOr(await VaultApi.getSetting('clipboard_seconds'), 30),
      lockOnMinimize: (await VaultApi.getSetting('lock_on_minimize') ?? (mobile ? '1' : '0')) == '1',
      themeMode: ThemeModeSetting.values.firstWhere((m) => m.name == theme, orElse: () => ThemeModeSetting.system),
      serverUrl: AppConfig.allowCustomServer
          ? (await VaultApi.getSetting('server_url') ?? AppConfig.defaultServerUrl)
          : AppConfig.defaultServerUrl,
      verboseLogs: (await VaultApi.getSetting('verbose_logs')) == '1',
      closeToTray: (await VaultApi.getSetting('close_to_tray')) != '0',
      globalHotkey: (await VaultApi.getSetting('global_hotkey')) != '0',
      browserIntegration: (await VaultApi.getSetting('browser_integration')) != '0',
    );
    privacyAccepted = (await VaultApi.getSetting('privacy_consent')) == privacyVersion;
  }

  Future<void> acceptPrivacy() async {
    await VaultApi.setSetting('privacy_consent', privacyVersion);
    privacyAccepted = true;
    VaultApi.log('privacy policy accepted');
    notifyListeners();
    if (phase == AppPhase.unlocked) {
      _startPeriodicSync();
      scheduleSync(immediate: true);
    }
  }

  // ---------- 注册 / 解锁 ----------

  Future<Enrollment> createAccount(String email, String password) async {
    final e = await VaultApi.createAccount(email, password);
    await SecureStore.writeSecretKey(e.accountId, e.secretKey);
    accountId = e.accountId;
    hasStoredSecretKey = true;
    pendingEnrollment = e;
    VaultApi.log('account created');
    notifyListeners();
    return e;
  }

  /// 用户确认已保存 Recovery Kit 后进入保险库。
  Future<void> finishOnboarding() async {
    pendingEnrollment = null;
    await _enterUnlocked();
  }

  Future<String> _secretKey(String? provided) async {
    if (provided != null && provided.trim().isNotEmpty) return provided.trim().toUpperCase();
    final sk = accountId == null ? null : await SecureStore.readSecretKey(accountId!);
    if (sk == null) throw CoreException('secret_key_missing', '本设备未保存 Secret Key，请输入 Recovery Kit 上的 Secret Key');
    return sk;
  }

  Future<void> unlock(String password, {String? secretKey}) async {
    final sk = await _secretKey(secretKey);
    await VaultApi.unlock(password, sk);
    if (secretKey != null && secretKey.trim().isNotEmpty) {
      await SecureStore.writeSecretKey(accountId!, sk);
      hasStoredSecretKey = true;
    }
    await _enterUnlocked();
  }

  /// 生物识别快速解锁（Touch ID / Face ID / Windows Hello / Android BiometricPrompt）。
  Future<bool> unlockWithBiometrics() async {
    if (!quickUnlockEnabled || accountId == null) return false;
    final ok = await _auth.authenticate(localizedReason: '解锁 VaultOne 保险库', biometricOnly: false);
    if (!ok) return false;
    final hex = await SecureStore.readQuickKey(accountId!);
    if (hex == null) {
      quickUnlockEnabled = false;
      notifyListeners();
      return false;
    }
    try {
      await VaultApi.unlockWithQuickKey(_unhex(hex));
    } on CoreException {
      // 快速解锁材料失效（例如主密码已变更）：清除并回退到主密码
      await SecureStore.deleteQuickKey(accountId!);
      quickUnlockEnabled = false;
      notifyListeners();
      rethrow;
    }
    await _enterUnlocked();
    return true;
  }

  Future<void> setQuickUnlock(bool enabled) async {
    if (enabled) {
      final ok = await _auth.authenticate(localizedReason: '启用生物识别解锁', biometricOnly: false);
      if (!ok) return;
      final key = await VaultApi.enableQuickUnlock();
      await SecureStore.writeQuickKey(accountId!, _hex(key));
    } else {
      await VaultApi.disableQuickUnlock();
      await SecureStore.deleteQuickKey(accountId!);
    }
    quickUnlockEnabled = enabled;
    notifyListeners();
  }

  Future<Enrollment> recover(String recoveryCode, String newPassword, {String? secretKey}) async {
    final sk = await _secretKey(secretKey);
    final e = await VaultApi.recover(recoveryCode, sk, newPassword);
    await SecureStore.writeSecretKey(accountId!, e.secretKey);
    await SecureStore.deleteQuickKey(accountId!);
    hasStoredSecretKey = true;
    quickUnlockEnabled = false;
    pendingEnrollment = e;
    notifyListeners();
    return e;
  }

  Future<void> changePassword(String current, String next) async {
    final sk = await _secretKey(null);
    await VaultApi.changePassword(current, sk, next);
    await SecureStore.deleteQuickKey(accountId!);
    quickUnlockEnabled = false;
    notifyListeners();
    scheduleSync(immediate: true);
  }

  /// 查看 Secret Key 前要求再次输入主密码，防止旁人趁未锁定时查看。
  Future<String> revealSecretKey(String masterPassword) => _withSession(() async {
    final sk = await _secretKey(null);
    await VaultApi.verifyMasterPassword(masterPassword, sk);
    return sk;
  });

  Future<void> _enterUnlocked() async {
    final epoch = sessionEpoch;
    phase = AppPhase.unlocked;
    final nextAccount = await VaultApi.account();
    if (!isCurrentSession(epoch)) return;
    account = nextAccount;
    await refresh(sync: false);
    if (!isCurrentSession(epoch)) return;
    final nextRemote = await VaultApi.remoteStatus();
    if (!isCurrentSession(epoch)) return;
    remote = nextRemote;
    syncState = remote == null ? SyncState.off : SyncState.idle;
    _startIdleTimer();
    _startPeriodicSync();
    notifyListeners();
    scheduleSync(immediate: true);
  }

  Future<void> lock() async {
    if (phase != AppPhase.unlocked) return;
    // 在任何 await 之前撤销 UI 会话，移除 Navigator 敏感页面并使旧读取失效。
    VaultApi.invalidateSession();
    phase = AppPhase.locked;
    _idleTimer?.cancel();
    _syncPeriodic?.cancel();
    _syncDebounce?.cancel();
    items = const [];
    trash = const [];
    account = null;
    pendingEnrollment = null;
    notifyListeners();
    unawaited(ClipboardService.clearNow());
    // 配对失败不得阻止内核锁定。
    try {
      await respondPairing(false);
    } finally {
      await VaultApi.lock();
    }
    VaultApi.log('locked');
  }

  // ---------- 云同步 ----------

  /// 新设备：登录已有账户。返回 true 表示已完成；false 表示需要设备验证。
  Future<bool> signIn(String serverUrl, String email, String password, String secretKey, String deviceName) async {
    await _saveServerUrl(serverUrl);
    final joined = await VaultApi.loginExisting(serverUrl, email, password, secretKey.trim().toUpperCase(), deviceName);
    if (!joined) {
      awaitingDeviceApproval = true;
      _pendingSecretKey = secretKey.trim().toUpperCase();
      notifyListeners();
      return false;
    }
    await _afterJoin(secretKey.trim().toUpperCase());
    return true;
  }

  String? _pendingSecretKey;

  Future<void> verifyDevice(String code) async {
    await VaultApi.verifyNewDevice(code);
    await _afterJoin(_pendingSecretKey!);
  }

  Future<bool> pollDeviceApproved() async {
    if (!await VaultApi.checkNewDeviceApproved()) return false;
    await _afterJoin(_pendingSecretKey!);
    return true;
  }

  void cancelDeviceApproval() {
    awaitingDeviceApproval = false;
    _pendingSecretKey = null;
    VaultApi.lock();
    notifyListeners();
  }

  Future<void> _afterJoin(String secretKey) async {
    awaitingDeviceApproval = false;
    _pendingSecretKey = null;
    final s = await VaultApi.status();
    accountId = s.accountId;
    await SecureStore.writeSecretKey(accountId!, secretKey);
    hasStoredSecretKey = true;
    await _loadSettings();
    await _enterUnlocked();
  }

  /// 所有设备丢失：用 Recovery Kit 从云端恢复。
  Future<Enrollment> recoverFromServer(String serverUrl, String email, String recoveryCode, String secretKey, String newPassword, String deviceName) async {
    await _saveServerUrl(serverUrl);
    final e = await VaultApi.recoverFromServer(serverUrl, email, recoveryCode, secretKey.trim().toUpperCase(), newPassword, deviceName);
    accountId = e.accountId;
    await SecureStore.writeSecretKey(e.accountId, e.secretKey);
    hasStoredSecretKey = true;
    pendingEnrollment = e;
    notifyListeners();
    return e;
  }

  Future<void> _saveServerUrl(String url) async {
    final fixed = AppConfig.allowCustomServer ? url.trim() : AppConfig.defaultServerUrl;
    settings = settings.copyWith(serverUrl: fixed);
    await VaultApi.setSetting('server_url', fixed);
  }

  /// 已解锁的本地账户开启云同步（首台设备注册）。
  Future<void> enableSync(String serverUrl, String deviceName) async {
    await _saveServerUrl(serverUrl);
    syncState = SyncState.syncing;
    notifyListeners();
    try {
      await VaultApi.connectRegister(serverUrl, deviceName);
      remote = await VaultApi.remoteStatus();
      syncState = SyncState.idle;
      syncError = null;
      _startPeriodicSync();
      await refresh(sync: false);
    } catch (e) {
      syncState = remote == null ? SyncState.off : SyncState.error;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> disableSync() async {
    await VaultApi.disconnect();
    remote = null;
    syncState = SyncState.off;
    _syncPeriodic?.cancel();
    notifyListeners();
  }

  Future<void> reconnect(String password) async {
    await VaultApi.reconnect(password, await _secretKey(null));
    syncState = SyncState.idle;
    syncError = null;
    notifyListeners();
    await syncNow();
  }

  void _startPeriodicSync() {
    _syncPeriodic?.cancel();
    if (remote == null || !privacyAccepted || phase != AppPhase.unlocked) return;
    _syncPeriodic = Timer.periodic(const Duration(minutes: 5), (_) => syncNow(silent: true));
  }

  /// 本地修改后 2 秒去抖同步；失败的修改留在离线队列，下次自动补传。
  void scheduleSync({bool immediate = false}) {
    if (!privacyAccepted || remote == null || phase != AppPhase.unlocked) return;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(immediate ? Duration.zero : const Duration(seconds: 2), () => syncNow(silent: true));
  }

  Future<SyncReportDto?> syncNow({bool silent = false}) async {
    if (!privacyAccepted || remote == null || phase != AppPhase.unlocked || syncState == SyncState.syncing) return null;
    final epoch = sessionEpoch;
    syncState = SyncState.syncing;
    notifyListeners();
    try {
      final r = await VaultApi.syncNow();
      if (!isCurrentSession(epoch)) return null;
      syncState = SyncState.idle;
      syncError = null;
      if (r.credentialsUpdated) {
        await SecureStore.deleteQuickKey(accountId!);
        quickUnlockEnabled = false;
      }
      await refresh(sync: false);
      remote = await VaultApi.remoteStatus();
      return r;
    } on CoreException catch (e) {
      if (!isCurrentSession(epoch)) return null;
      syncState = e.isUnauthorized ? SyncState.needsReconnect : SyncState.error;
      syncError = e.message;
      if (!silent) rethrow;
      return null;
    } finally {
      notifyListeners();
    }
  }

  // ---------- 自动锁定 ----------

  void registerActivity() => _lastActivity = DateTime.now();

  /// 快速搜索请求计数（全局快捷键 / 托盘菜单触发），主页监听后聚焦搜索框。
  final quickSearchRequests = ValueNotifier<int>(0);

  void requestQuickSearch() {
    registerActivity();
    quickSearchRequests.value++;
  }

  void _startIdleTimer() {
    _idleTimer?.cancel();
    _lastActivity = DateTime.now();
    _idleTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final minutes = settings.autoLockMinutes;
      if (minutes <= 0) return;
      if (DateTime.now().difference(_lastActivity) >= Duration(minutes: minutes)) lock();
    });
  }

  void onAppHidden() {
    if (settings.lockOnMinimize) lock();
  }

  // ---------- 条目 ----------

  Future<void> refresh({bool sync = true}) async {
    final epoch = sessionEpoch;
    if (!isCurrentSession(epoch)) return;
    try {
      final nextItems = await VaultApi.listItems();
      if (!isCurrentSession(epoch)) return;
      final nextTrash = await VaultApi.listTrash();
      if (!isCurrentSession(epoch)) return;
      final nextAccount = await VaultApi.account();
      if (!isCurrentSession(epoch)) return;
      items = nextItems;
      trash = nextTrash;
      account = nextAccount;
      notifyListeners();
      if (sync) scheduleSync();
    } on CoreException {
      if (isCurrentSession(epoch)) rethrow;
    }
  }

  VaultItem? byId(String? id) {
    if (id == null) return null;
    for (final i in items) {
      if (i.id == id) return i;
    }
    for (final i in trash) {
      if (i.id == id) return i;
    }
    return null;
  }

  Future<VaultItem> save(String? id, ItemData data) => _withSession(() async {
    final item = id == null ? await VaultApi.createItem(data) : await VaultApi.updateItem(id, data);
    await refresh();
    return item;
  });

  Future<void> toggleFavorite(VaultItem item) => _withSession(() async {
    await VaultApi.updateItem(item.id, item.data.copyWith(favorite: !item.data.favorite));
    await refresh();
  });

  Future<void> delete(String id) => _withSession(() async {
    await VaultApi.deleteItem(id);
    await refresh();
  });

  Future<void> restore(String id) => _withSession(() async {
    await VaultApi.restoreItem(id);
    await refresh();
  });

  Future<ImportSummary> importItems(String content) => _withSession(() async {
    final summary = await VaultApi.importItems(content);
    await refresh();
    return summary;
  });

  /// 从加密备份包（`.wljbak`）导入，导入后刷新。
  Future<ImportSummary> importBackup(Uint8List data) => _withSession(() async {
    final summary = await VaultApi.importBackup(data);
    await refresh();
    return summary;
  });

  /// 导出加密备份包字节流。
  Future<Uint8List> exportBackup() => _withSession(VaultApi.exportBackup);

  /// 导出明文 CSV。
  Future<String> exportCsv() => _withSession(VaultApi.exportCsv);

  // ---------- 设置 ----------

  Future<void> updateSettings(Settings s) async {
    settings = s;
    notifyListeners();
    await VaultApi.setSetting('auto_lock_minutes', '${s.autoLockMinutes}');
    await VaultApi.setSetting('clipboard_seconds', '${s.clipboardSeconds}');
    await VaultApi.setSetting('lock_on_minimize', s.lockOnMinimize ? '1' : '0');
    await VaultApi.setSetting('theme', s.themeMode.name);
    await VaultApi.setSetting('verbose_logs', s.verboseLogs ? '1' : '0');
    await VaultApi.setSetting('close_to_tray', s.closeToTray ? '1' : '0');
    await VaultApi.setSetting('global_hotkey', s.globalHotkey ? '1' : '0');
    await VaultApi.setSetting('browser_integration', s.browserIntegration ? '1' : '0');
  }

  // ---------- 浏览器扩展（由 DesktopShell 按设置启停）----------

  /// 等待用户批准的扩展配对请求（界面据此弹窗）。
  PairingRequest? pendingPairing;
  StreamSubscription<PairingRequest>? _pairingSub;

  void startBrowserBridge() {
    _pairingSub ??= VaultApi.startBrowserBridge().listen(
      (r) {
        pendingPairing = r;
        notifyListeners();
      },
      onError: (Object e) {
        VaultApi.log('browser bridge failed: ${e is CoreException ? e.code : e.runtimeType}', level: 'warn');
        _pairingSub = null;
      },
    );
    // 每次启动都重新登记宿主：应用被移动 / 升级后路径可能变化
    VaultApi.registerNativeHost().then(
      (_) {},
      onError: (Object e) => VaultApi.log('native host register failed: ${e is CoreException ? e.code : e.runtimeType}', level: 'warn'),
    );
  }

  Future<void> stopBrowserBridge() async {
    await _pairingSub?.cancel();
    _pairingSub = null;
    await respondPairing(false);
    await VaultApi.stopBrowserBridge();
  }

  Future<void> respondPairing(bool approved) async {
    final p = pendingPairing;
    if (p == null) return;
    pendingPairing = null;
    notifyListeners();
    await VaultApi.respondPairing(p.clientId, approved);
  }

  /// 清除本机全部数据（不影响云端）。之后回到欢迎页。
  Future<void> wipeThisDevice() async {
    final id = accountId;
    VaultApi.invalidateSession();
    _syncDebounce?.cancel();
    _idleTimer?.cancel();
    _syncPeriodic?.cancel();
    await VaultApi.wipeLocal();
    if (id != null) await SecureStore.deleteAll(id);
    items = const [];
    trash = const [];
    account = null;
    remote = null;
    accountId = null;
    syncState = SyncState.off;
    phase = AppPhase.onboarding;
    await Clipboard.setData(const ClipboardData(text: ''));
    notifyListeners();
  }

  Future<void> deleteCloudAccount(String password) async {
    await VaultApi.deleteRemoteAccount(password, await _secretKey(null));
    remote = null;
    syncState = SyncState.off;
    notifyListeners();
  }

  @override
  void dispose() {
    quickSearchRequests.dispose();
    _pairingSub?.cancel();
    _idleTimer?.cancel();
    _syncPeriodic?.cancel();
    _syncDebounce?.cancel();
    super.dispose();
  }
}
