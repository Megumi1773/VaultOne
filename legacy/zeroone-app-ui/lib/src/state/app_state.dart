import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/api.dart';
import '../core/ffi.dart';
import '../core/models.dart';

enum AppPhase { loading, onboarding, locked, unlocked, error }

/// 应用设置（保存在本地库 settings 表，非敏感）。
class Settings {
  const Settings({
    this.autoLockMinutes = 10,
    this.clipboardSeconds = 30,
    this.lockOnMinimize = false,
    this.themeMode = ThemeModeSetting.dark,
  });

  final int autoLockMinutes;
  final int clipboardSeconds;
  final bool lockOnMinimize;
  final ThemeModeSetting themeMode;

  Settings copyWith({int? autoLockMinutes, int? clipboardSeconds, bool? lockOnMinimize, ThemeModeSetting? themeMode}) => Settings(
        autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
        clipboardSeconds: clipboardSeconds ?? this.clipboardSeconds,
        lockOnMinimize: lockOnMinimize ?? this.lockOnMinimize,
        themeMode: themeMode ?? this.themeMode,
      );
}

enum ThemeModeSetting { dark, light, system }

/// Secret Key 保存在系统安全存储（Windows DPAPI / macOS Keychain / Android Keystore）。
class SecretKeyStore {
  static const _storage = FlutterSecureStorage();

  static String _key(String accountId) => 'zeroone.secret_key.$accountId';

  static Future<String?> read(String accountId) async {
    try {
      return await _storage.read(key: _key(accountId));
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String accountId, String secretKey) => _storage.write(key: _key(accountId), value: secretKey);
}

class AppState extends ChangeNotifier {
  AppState();

  AppPhase phase = AppPhase.loading;
  String? fatalError;
  String? accountId;
  AccountInfo? account;
  bool hasStoredSecretKey = false;

  List<VaultItem> items = const [];
  List<VaultItem> trash = const [];
  Settings settings = const Settings();

  /// 注册完成、尚未确认保存 Recovery Kit 时持有；确认后立即丢弃。
  Enrollment? pendingEnrollment;

  Timer? _idleTimer;
  DateTime _lastActivity = DateTime.now();

  // ---------- 生命周期 ----------

  Future<void> init(String dbPath) async {
    try {
      await VaultApi.open(dbPath);
      final s = await VaultApi.status();
      await _loadSettings();
      if (!s.initialized) {
        phase = AppPhase.onboarding;
      } else {
        accountId = await VaultApi.accountId();
        hasStoredSecretKey = (await SecretKeyStore.read(accountId!)) != null;
        phase = AppPhase.locked;
      }
    } catch (e) {
      fatalError = e.toString();
      phase = AppPhase.error;
    }
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    int intOr(String? v, int d) => int.tryParse(v ?? '') ?? d;
    final theme = await VaultApi.getSetting('theme') ?? 'dark';
    settings = Settings(
      autoLockMinutes: intOr(await VaultApi.getSetting('auto_lock_minutes'), 10),
      clipboardSeconds: intOr(await VaultApi.getSetting('clipboard_seconds'), 30),
      lockOnMinimize: (await VaultApi.getSetting('lock_on_minimize')) == '1',
      themeMode: ThemeModeSetting.values.firstWhere((m) => m.name == theme, orElse: () => ThemeModeSetting.dark),
    );
  }

  // ---------- 注册 / 解锁 ----------

  Future<Enrollment> createAccount(String email, String password) async {
    final e = await VaultApi.createAccount(email, password);
    await SecretKeyStore.write(e.accountId, e.secretKey);
    accountId = e.accountId;
    hasStoredSecretKey = true;
    pendingEnrollment = e;
    notifyListeners();
    return e;
  }

  /// 用户确认已保存 Recovery Kit 后进入保险库。
  Future<void> finishOnboarding() async {
    pendingEnrollment = null;
    await _enterUnlocked();
  }

  Future<void> unlock(String password, {String? secretKey}) async {
    final id = accountId!;
    final sk = secretKey ?? await SecretKeyStore.read(id);
    if (sk == null) throw CoreException('secret_key_missing', '本设备未保存 Secret Key，请输入 Recovery Kit 上的 Secret Key');
    await VaultApi.unlock(password, sk);
    if (secretKey != null) {
      await SecretKeyStore.write(id, secretKey.trim().toUpperCase());
      hasStoredSecretKey = true;
    }
    await _enterUnlocked();
  }

  Future<Enrollment> recover(String recoveryCode, String newPassword, {String? secretKey}) async {
    final id = accountId!;
    final sk = secretKey ?? await SecretKeyStore.read(id);
    if (sk == null) throw CoreException('secret_key_missing', '请输入 Recovery Kit 上的 Secret Key');
    final e = await VaultApi.recover(recoveryCode, sk, newPassword);
    await SecretKeyStore.write(id, e.secretKey);
    hasStoredSecretKey = true;
    pendingEnrollment = e;
    notifyListeners();
    return e;
  }

  Future<void> changePassword(String current, String next) async {
    final sk = await SecretKeyStore.read(accountId!);
    if (sk == null) throw CoreException('secret_key_missing', '本设备未保存 Secret Key');
    await VaultApi.changePassword(current, sk, next);
  }

  Future<String?> revealSecretKey(String masterPassword) async {
    final sk = await SecretKeyStore.read(accountId!);
    if (sk == null) return null;
    // 通过重新解锁校验主密码，避免旁人趁未锁定时查看 Secret Key
    await VaultApi.unlock(masterPassword, sk);
    return sk;
  }

  Future<void> _enterUnlocked() async {
    phase = AppPhase.unlocked;
    account = await VaultApi.account();
    await refresh();
    _startIdleTimer();
    notifyListeners();
  }

  Future<void> lock() async {
    if (phase != AppPhase.unlocked) return;
    _idleTimer?.cancel();
    await VaultApi.lock();
    items = const [];
    trash = const [];
    account = null;
    phase = AppPhase.locked;
    // 锁定时清空剪贴板中我们写入的内容
    Clipboard.setData(const ClipboardData(text: ''));
    notifyListeners();
  }

  // ---------- 自动锁定 ----------

  void registerActivity() => _lastActivity = DateTime.now();

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

  Future<void> refresh() async {
    items = await VaultApi.listItems();
    trash = await VaultApi.listTrash();
    notifyListeners();
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

  Future<VaultItem> save(String? id, ItemData data) async {
    final item = id == null ? await VaultApi.createItem(data) : await VaultApi.updateItem(id, data);
    await refresh();
    return item;
  }

  Future<void> toggleFavorite(VaultItem item) async {
    await VaultApi.updateItem(item.id, item.data.copyWith(favorite: !item.data.favorite));
    await refresh();
  }

  Future<void> delete(String id) async {
    await VaultApi.deleteItem(id);
    await refresh();
  }

  Future<void> restore(String id) async {
    await VaultApi.restoreItem(id);
    await refresh();
  }

  // ---------- 设置 ----------

  Future<void> updateSettings(Settings s) async {
    settings = s;
    notifyListeners();
    await VaultApi.setSetting('auto_lock_minutes', '${s.autoLockMinutes}');
    await VaultApi.setSetting('clipboard_seconds', '${s.clipboardSeconds}');
    await VaultApi.setSetting('lock_on_minimize', s.lockOnMinimize ? '1' : '0');
    await VaultApi.setSetting('theme', s.themeMode.name);
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }
}
