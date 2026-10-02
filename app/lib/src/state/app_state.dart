import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../core/api.dart';
import '../core/config.dart';
import '../core/ffi.dart';
import '../core/feedback_models.dart';
import '../core/import_models.dart';
import '../core/models.dart';
import '../l10n/strings.dart';
import 'clipboard.dart';

enum AppPhase { loading, onboarding, locked, cloudSetup, unlocked, error }

enum ThemeModeSetting { dark, light, system }

/// 应用设置（保存在本地库 settings 表，非敏感）。
class Settings {
  const Settings({
    this.autoLockMinutes = 10,
    this.clipboardSeconds = 30,
    this.lockOnMinimize = false,
    this.themeMode = ThemeModeSetting.system,
    this.language = AppStrings.defaultLanguage,
    this.serverUrl = AppConfig.defaultServerUrl,
    this.verboseLogs = false,
    this.closeToTray = true,
    this.globalHotkey = true,
    this.browserIntegration = true,
    this.sidebarLayout = '',
    this.lockOnExit = true,
    this.maskPasswords = true,
    this.screenshotProtection = false,
  });

  final int autoLockMinutes;
  final int clipboardSeconds;
  final bool lockOnMinimize;
  final ThemeModeSetting themeMode;

  /// 界面语言。只影响应用自身文案；条目内容与备注不翻译、不上传。
  final AppLanguage language;

  final String serverUrl;
  final bool verboseLogs;

  /// 桌面端：关闭窗口时隐藏到系统托盘而非退出
  final bool closeToTray;

  /// 桌面端：全局快捷键唤起快速搜索
  final bool globalHotkey;

  /// 桌面端：允许浏览器扩展经 Native Messaging 连接
  final bool browserIntegration;

  /// 侧栏（首页板块）布局，JSON 字符串。存成不透明字符串是为了保持分层：状态层不认识
  /// `Section`，由界面用 `resolveSidebarLayout` 解释；解析失败一律回退默认布局。
  final String sidebarLayout;

  /// 关闭窗口即锁定（§5.4）。默认开：隐藏到托盘后保险库仍是解锁状态，等于把锁敞着。
  final bool lockOnExit;

  /// 详情页默认隐藏密码（§5.4）。默认开；关掉后详情页直接显示明文。
  final bool maskPasswords;

  /// 截图保护（§8.3）：阻止本应用窗口被截屏 / 录屏捕获。平台不支持时该项无效。
  final bool screenshotProtection;

  Settings copyWith({
    int? autoLockMinutes,
    int? clipboardSeconds,
    bool? lockOnMinimize,
    ThemeModeSetting? themeMode,
    AppLanguage? language,
    String? serverUrl,
    bool? verboseLogs,
    bool? closeToTray,
    bool? globalHotkey,
    bool? browserIntegration,
    String? sidebarLayout,
    bool? lockOnExit,
    bool? maskPasswords,
    bool? screenshotProtection,
  }) =>
      Settings(
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        clipboardSeconds: clipboardSeconds ?? this.clipboardSeconds,
        lockOnMinimize: lockOnMinimize ?? this.lockOnMinimize,
        themeMode: themeMode ?? this.themeMode,
        language: language ?? this.language,
        serverUrl: serverUrl ?? this.serverUrl,
        verboseLogs: verboseLogs ?? this.verboseLogs,
        closeToTray: closeToTray ?? this.closeToTray,
        globalHotkey: globalHotkey ?? this.globalHotkey,
        browserIntegration: browserIntegration ?? this.browserIntegration,
        sidebarLayout: sidebarLayout ?? this.sidebarLayout,
        lockOnExit: lockOnExit ?? this.lockOnExit,
        maskPasswords: maskPasswords ?? this.maskPasswords,
        screenshotProtection: screenshotProtection ?? this.screenshotProtection,
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

  /// 当前平台是否支持截图保护（§8.3）。启动时探测一次；不支持时设置页禁用该开关。
  bool screenshotProtectionSupported = false;

  static bool _screenshotSupported() {
    try {
      return VaultApi.screenshotProtectionSupported();
    } catch (_) {
      return false;
    }
  }

  List<VaultItem> items = const [];
  List<VaultItem> trash = const [];

  /// 分类树（层级分组）。由内核从条目派生，含后代汇总计数。
  List<CategoryNode> categoryTree = const [];
  Settings settings = const Settings();

  /// 注册 / 恢复完成、尚未确认保存 Recovery Kit 时持有；确认后立即丢弃。
  Enrollment? pendingEnrollment;
  String? cloudSetupError;
  String? pendingAccountOperation;

  /// 首次启动须同意隐私政策与用户协议（个人信息保护法 / 应用商店要求）；同意前不发起任何网络请求。
  bool privacyAccepted = false;
  static const privacyVersion = VaultApi.privacyVersion;

  /// 备份状态（本机可见，非敏感元数据，存在 settings 表）。
  ///
  /// `lastBackupAt` 为 Unix 秒，0 表示从未记录；`lastBackupKind` 取 recovery_kit / wljbak / csv。
  /// 云端备份历史需要 Java 端点，尚未实现，因此这里只描述本机事实，不冒充云端已备份。
  int lastBackupAt = 0;
  String? lastBackupKind;

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


  Future<String> newFeedbackId() => _withSession(VaultApi.newFeedbackId);
  Future<FeedbackDetail> submitFeedback(FeedbackSubmission request) =>
      _withSession(() => VaultApi.submitFeedback(request));
  Future<FeedbackPageResult> listFeedback(int? before) =>
      _withSession(() => VaultApi.listFeedback(before));
  Future<FeedbackDetail> getFeedback(String id) =>
      _withSession(() => VaultApi.getFeedback(id));

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
    // 日志必须最先初始化：否则 open/_loadSettings 一旦抛错，日志从未建立，
    // 现场只剩 0 字节文件，故障无法事后诊断。
    // 日志初始化自身失败不能中断启动（否则连保险库都打不开），故单独兜住。
    try {
      await VaultApi.initLogging(logDir, verbose: false);
    } catch (e) {
      VaultApi.log('initLogging failed: ${e is CoreException ? e.code : e.runtimeType}', level: 'error');
    }
    try {
      await VaultApi.open(dbPath);
      await _loadSettings();
      biometricsAvailable = await _canUseBiometrics();
      // 平台能力在启动时探测一次并存进状态：设置页在 build 里读它，
      // 若在那里直接调同步 FFI，任何不初始化桥的测试都会在构建期炸掉。
      screenshotProtectionSupported = _screenshotSupported();
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
    phase = AppPhase.locked;
    if (s.unlocked) await _enterUnlocked();
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
      language: AppLanguage.parse(await VaultApi.getSetting('language')),
      serverUrl: AppConfig.serverUrl(await VaultApi.getSetting('server_url') ?? AppConfig.defaultServerUrl),
      verboseLogs: (await VaultApi.getSetting('verbose_logs')) == '1',
      closeToTray: (await VaultApi.getSetting('close_to_tray')) != '0',
      globalHotkey: (await VaultApi.getSetting('global_hotkey')) != '0',
      browserIntegration: (await VaultApi.getSetting('browser_integration')) != '0',
      sidebarLayout: await VaultApi.getSetting('sidebar_layout') ?? '',
      // 默认值取 `!= '0'` 而不是 `== '1'`：老库里没有这个键时应当落到「开」。
      lockOnExit: (await VaultApi.getSetting('lock_on_exit')) != '0',
      maskPasswords: (await VaultApi.getSetting('mask_passwords')) != '0',
      screenshotProtection: (await VaultApi.getSetting('screenshot_protection')) == '1',
    );
    privacyAccepted = (await VaultApi.getSetting('privacy_consent')) == privacyVersion;
    lastBackupAt = intOr(await VaultApi.getSetting('backup_last_at'), 0);
    lastBackupKind = await VaultApi.getSetting('backup_last_kind');
  }

  /// 记录一次本机备份事实。只写非敏感元数据，不记录路径与内容。
  Future<void> recordBackup(String kind) async {
    lastBackupAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    lastBackupKind = kind;
    await VaultApi.setSetting('backup_last_at', '$lastBackupAt');
    await VaultApi.setSetting('backup_last_kind', kind);
    notifyListeners();
  }

  /// 备份二次确认：重输的 Secret Key 必须与本机保存的逐字节一致。
  ///
  /// 比对在 Rust 侧解析后做常量时间比较，因此大小写、分组连字符、空白与 I/L/O 的手抄
  /// 差异被容忍，但字节内容必须完全一致。成功时把本机记录标为已核对并返回规范形态的
  /// Secret Key，供备份卡与展示使用。
  Future<String> confirmSecretKey(String candidate) async {
    final stored = await _secretKey(null);
    final canonical = await VaultApi.verifySecretKey(stored, candidate);
    await VaultApi.setSetting('backup_verified_at', '${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
    return canonical;
  }

  /// 核对备份材料：Secret Key 与本机保存的逐字节比对（必须一致），恢复码只做格式规范化。
  ///
  /// 本机不保存恢复码字节（它只在生成时展示、由用户离线保管），因此恢复码的内容正确性
  /// 无法在本机验证，只在真正恢复时由服务端判定；这里如实返回规范形态而不谎称已校验。
  Future<({String secretKey, String recoveryCode})> verifyRecoveryMaterials({
    required String secretKey,
    required String recoveryCode,
  }) async {
    final sk = await confirmSecretKey(secretKey);
    final rc = await VaultApi.canonicalRecoveryCode(recoveryCode);
    return (secretKey: sk, recoveryCode: rc);
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
    final epoch = sessionEpoch;
    final server = AppConfig.serverUrl(settings.serverUrl);
    final e = await VaultApi.prepareCloudRegistration(server, email, password, defaultDeviceName);
    if (epoch != sessionEpoch) throw CoreException('session_expired', '账户操作已取消');
    accountId = e.accountId;
    phase = AppPhase.cloudSetup;
    pendingAccountOperation = 'register';
    cloudSetupError = null;
    notifyListeners();
    try {
      await SecureStore.writeSecretKey(e.accountId, e.secretKey);
      hasStoredSecretKey = true;
      await completeCloudRegistration(password, secretKey: e.secretKey);
    } catch (error) {
      if (epoch == sessionEpoch) {
        cloudSetupError = error is CoreException ? error.message : '安全存储或注册未完成，请保留恢复材料后重试';
        notifyListeners();
      }
      rethrow;
    }
    return e;
  }

  Future<void> completeCloudRegistration(String password, {String? secretKey}) async {
    if (phase != AppPhase.cloudSetup) throw CoreException('session_expired', '请先解锁账户草稿');
    final epoch = sessionEpoch;
    final sk = await _secretKey(secretKey);
    await VaultApi.completeCloudRegistration(AppConfig.serverUrl(settings.serverUrl), password, sk, defaultDeviceName);
    if (epoch != sessionEpoch) return;
    await SecureStore.writeSecretKey(accountId!, sk);
    hasStoredSecretKey = true;
    cloudSetupError = null;
    await _enterUnlocked();
  }

  /// 云账户已确认且用户保存恢复套件后，才进入条目界面。
  Future<void> finishOnboarding() async {
    if (await VaultApi.remoteStatus() == null) throw CoreException('not_connected', '请先完成云账户注册');
    await VaultApi.confirmCloudEnrollment();
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
    final ok = await _auth.authenticate(
      // 系统弹窗没有 BuildContext，按当前设置的语言直接取词。
      localizedReason: AppStrings.translate(AppStrings.unlockVaultPrompt, settings.language),
      biometricOnly: false,
    );
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
      final ok = await _auth.authenticate(
        localizedReason: AppStrings.translate(AppStrings.biometricEnable, settings.language),
        biometricOnly: false,
      );
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

  Future<Enrollment> recover(String recoveryCode, String newPassword, {String? secretKey, required String email}) async {
    final sk = await _secretKey(secretKey);
    return recoverFromServer(settings.serverUrl, email, recoveryCode, sk, newPassword, defaultDeviceName);
  }

  Future<void> changePassword(String current, String next) async {
    final sk = await _secretKey(null);
    try {
      await VaultApi.changePassword(current, sk, next);
    } on CoreException catch (error) {
      pendingAccountOperation = await VaultApi.pendingCloudOperation();
      if (pendingAccountOperation == 'password') {
        throw CoreException(error.code, '改密结果尚未确认。旧本机密码仍可解锁，请使用相同的新密码重试；其他设备可能已采用新密码。');
      }
      rethrow;
    }
    pendingAccountOperation = null;
    await SecureStore.deleteQuickKey(accountId!);
    quickUnlockEnabled = false;
    notifyListeners();
    scheduleSync(immediate: true);
  }

  Future<void> _enterUnlocked() async {
    final epoch = sessionEpoch;
    phase = AppPhase.unlocked;
    final nextAccount = await VaultApi.account();
    if (!isCurrentSession(epoch)) return;
    account = nextAccount;
    final nextRemote = await VaultApi.remoteStatus();
    final kit = await VaultApi.pendingCloudEnrollment();
    final operation = await VaultApi.pendingCloudOperation();
    if (!isCurrentSession(epoch)) return;
    remote = nextRemote;
    pendingAccountOperation = operation;
    if (kit != null) {
      pendingEnrollment = kit;
      phase = AppPhase.onboarding;
      notifyListeners();
      return;
    }
    if (remote == null) {
      phase = AppPhase.cloudSetup;
      items = const [];
      trash = const [];
      syncState = SyncState.off;
      _startIdleTimer();
      notifyListeners();
      return;
    }
    await refresh(sync: false);
    if (!isCurrentSession(epoch)) return;
    syncState = remote!.serverUrl == settings.serverUrl ? SyncState.idle : SyncState.needsReconnect;
    if (syncState == SyncState.needsReconnect) syncError = '请重新验证 Java 服务连接；原数据与待同步条目已保留';
    _startIdleTimer();
    _startPeriodicSync();
    notifyListeners();
    scheduleSync(immediate: true);
  }

  Future<void> lock() async {
    if (phase != AppPhase.unlocked && phase != AppPhase.cloudSetup) return;
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
    final selected = AppConfig.serverUrl(serverUrl);
    await _saveServerUrl(selected);
    final joined = await VaultApi.loginExisting(selected, email, password, secretKey.trim().toUpperCase(), deviceName);
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
    final epoch = sessionEpoch;
    final key = _pendingSecretKey;
    if (!awaitingDeviceApproval || key == null) return;
    await VaultApi.verifyNewDevice(code);
    if (epoch != sessionEpoch || !awaitingDeviceApproval) return;
    await _afterJoin(key);
  }

  Future<bool> pollDeviceApproved() async {
    final epoch = sessionEpoch;
    final key = _pendingSecretKey;
    if (!awaitingDeviceApproval || key == null) return false;
    if (!await VaultApi.checkNewDeviceApproved()) return false;
    if (epoch != sessionEpoch || !awaitingDeviceApproval) return false;
    await _afterJoin(key);
    return true;
  }

  Future<void> cancelDeviceApproval() async {
    VaultApi.invalidateSession();
    awaitingDeviceApproval = false;
    _pendingSecretKey = null;
    notifyListeners();
    await VaultApi.lock();
    await _refreshStatus();
    notifyListeners();
  }

  Future<void> _afterJoin(String secretKey) async {
    final epoch = sessionEpoch;
    awaitingDeviceApproval = false;
    _pendingSecretKey = null;
    final s = await VaultApi.status();
    if (epoch != sessionEpoch) return;
    accountId = s.accountId;
    await SecureStore.writeSecretKey(accountId!, secretKey);
    if (epoch != sessionEpoch) return;
    hasStoredSecretKey = true;
    await _loadSettings();
    if (epoch != sessionEpoch) return;
    await _enterUnlocked();
  }

  /// 所有设备丢失：用 Recovery Kit 从云端恢复。
  Future<Enrollment> recoverFromServer(String serverUrl, String email, String recoveryCode, String secretKey, String newPassword, String deviceName) async {
    final selected = AppConfig.serverUrl(serverUrl);
    await _saveServerUrl(selected);
    final e = await VaultApi.recoverFromServer(selected, email, recoveryCode, secretKey.trim().toUpperCase(), newPassword, deviceName);
    accountId = e.accountId;
    await SecureStore.writeSecretKey(e.accountId, e.secretKey);
    await SecureStore.deleteQuickKey(e.accountId);
    quickUnlockEnabled = false;
    hasStoredSecretKey = true;
    pendingEnrollment = e;
    phase = AppPhase.onboarding;
    notifyListeners();
    return e;
  }

  Future<void> _saveServerUrl(String url) async {
    final fixed = AppConfig.serverUrl(url);
    settings = settings.copyWith(serverUrl: fixed);
    await VaultApi.setSetting('server_url', fixed);
  }

  Future<void> signOut() async {
    await VaultApi.logoutCloud();
    syncState = SyncState.needsReconnect;
    await lock();
  }

  /// 显式重新认证到配置中的 Java 服务；内核校验同一账户后才换绑。
  Future<void> reconnect(String password) async {
    await VaultApi.reconnectCloud(AppConfig.serverUrl(settings.serverUrl), password, await _secretKey(null));
    remote = await VaultApi.remoteStatus();
    await SecureStore.deleteQuickKey(accountId!);
    quickUnlockEnabled = false;
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
    if (remote!.serverUrl != settings.serverUrl) {
      syncState = SyncState.needsReconnect;
      syncError = '请重新验证 Java 服务连接；不会自动向旧服务器发送请求';
      notifyListeners();
      return null;
    }
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
      // 分类树由内核派生（聚合计数只实现一处），随条目一起刷新。
      final nextTree = await VaultApi.categoryTree();
      if (!isCurrentSession(epoch)) return;
      items = nextItems;
      trash = nextTrash;
      account = nextAccount;
      categoryTree = nextTree;
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

  /// 从回收站彻底删除（本机物理抹除，不可恢复）。
  Future<void> purge(String id) => _withSession(() async {
    await VaultApi.purgeItem(id);
    await refresh();
  });

  /// 清空回收站。返回 (已抹除, 未同步而保留)。
  Future<({int purged, int kept})> emptyTrash() => _withSession(() async {
    final r = await VaultApi.emptyTrash();
    await refresh();
    return r;
  });

  Future<ImportSummary> importItems(String content, {String source = ''}) => _withSession(() async {
    final summary = await VaultApi.importItems(content, source: source);
    await refresh();
    return summary;
  });

  // ---------- 标签与分类的批量管理（§3.6）----------

  /// 四个批量操作都在内核改写并返回受影响条目数；完成后刷新（分类树也跟着变）。
  Future<int> renameTag(String from, String to) => _withSession(() async {
        final n = await VaultApi.renameTag(from, to);
        await refresh(sync: false);
        return n;
      });

  Future<int> deleteTag(String tag) => _withSession(() async {
        final n = await VaultApi.deleteTag(tag);
        await refresh(sync: false);
        return n;
      });

  Future<int> renameCategory(String from, String to) => _withSession(() async {
        final n = await VaultApi.renameCategory(from, to);
        await refresh(sync: false);
        return n;
      });

  Future<int> clearCategory(String path) => _withSession(() async {
        final n = await VaultApi.clearCategory(path);
        await refresh(sync: false);
        return n;
      });

  /// 按预览确认的字段映射与覆盖策略导入（§3.7），导入后刷新。
  Future<ImportSummary> importItemsWith(
    String content, {
    ColumnMapping? mapping,
    ImportStrategy strategy = ImportStrategy.skip,
    String source = '',
  }) =>
      _withSession(() async {
        final summary = await VaultApi.importItemsWith(content, mapping: mapping, strategy: strategy, source: source);
        await refresh();
        return summary;
      });

  /// 从加密备份包（`.wljbak`）导入，导入后刷新。
  Future<ImportSummary> importBackup(Uint8List data, {String source = ''}) => _withSession(() async {
    final summary = await VaultApi.importBackup(data, source: source);
    await refresh();
    return summary;
  });

  /// 导出加密备份包字节流。
  Future<Uint8List> exportBackup() => _withSession(VaultApi.exportBackup);

  /// 导出明文 CSV。
  Future<String> exportCsv() => _withSession(VaultApi.exportCsv);

  /// 导入 / 导出历史（§3.7）。本机记录、密封存放、不参与同步。
  Future<List<TransferRecord>> transferHistory() => _withSession(VaultApi.transferHistory);

  Future<void> clearTransferHistory() => _withSession(VaultApi.clearTransferHistory);

  // ---------- 设置 ----------

  Future<void> updateSettings(Settings s) async {
    settings = s;
    notifyListeners();
    await VaultApi.setSetting('auto_lock_minutes', '${s.autoLockMinutes}');
    await VaultApi.setSetting('clipboard_seconds', '${s.clipboardSeconds}');
    await VaultApi.setSetting('lock_on_minimize', s.lockOnMinimize ? '1' : '0');
    await VaultApi.setSetting('theme', s.themeMode.name);
    await VaultApi.setSetting('language', s.language.storageKey);
    await VaultApi.setSetting('verbose_logs', s.verboseLogs ? '1' : '0');
    await VaultApi.setSetting('close_to_tray', s.closeToTray ? '1' : '0');
    await VaultApi.setSetting('global_hotkey', s.globalHotkey ? '1' : '0');
    await VaultApi.setSetting('browser_integration', s.browserIntegration ? '1' : '0');
    await VaultApi.setSetting('sidebar_layout', s.sidebarLayout);
    await VaultApi.setSetting('lock_on_exit', s.lockOnExit ? '1' : '0');
    await VaultApi.setSetting('mask_passwords', s.maskPasswords ? '1' : '0');
    await VaultApi.setSetting('screenshot_protection', s.screenshotProtection ? '1' : '0');
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
    pendingEnrollment = null;
    pendingAccountOperation = null;
    cloudSetupError = null;
    hasStoredSecretKey = false;
    quickUnlockEnabled = false;
    awaitingDeviceApproval = false;
    _pendingSecretKey = null;
    syncState = SyncState.off;
    phase = AppPhase.onboarding;
    await _loadSettings();
    await Clipboard.setData(const ClipboardData(text: ''));
    notifyListeners();
  }

  Future<void> deleteCloudAccount(String password) async {
    await VaultApi.deleteRemoteAccount(password, await _secretKey(null));
    remote = null;
    syncState = SyncState.off;
    _syncPeriodic?.cancel();
    _syncDebounce?.cancel();
    items = const [];
    trash = const [];
    phase = AppPhase.cloudSetup;
    cloudSetupError = '云账户已注销。本机加密数据保留，可先导出备份或明确清除本机数据。';
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
