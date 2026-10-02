import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/api.dart';
import '../l10n/strings.dart';
import 'app_state.dart';

/// 桌面端外壳（计划书 §2.3 系统托盘 / P1 全局快捷键）：
/// - 系统托盘：单击显示窗口；右键菜单「打开 / 快速搜索 / 立即锁定 / 退出」；
/// - 关闭窗口时隐藏到托盘（可在设置中关闭），真正退出走托盘菜单；
/// - 全局快捷键 Ctrl+Shift+Space（macOS ⌘⇧Space）：任何时候唤起窗口并聚焦搜索框（Spotlight 式）；
/// - 浏览器扩展通道（Native Messaging）：按设置启停，配对请求到来时唤起窗口。
///
/// 只在 Windows / macOS / Linux 的正式启动路径（`main.dart`）中创建；集成测试不创建，避免抢占系统快捷键。
class DesktopShell with TrayListener, WindowListener {
  DesktopShell(this.state);

  final AppState state;

  static bool get supported => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static final hotKey = HotKey(
    key: PhysicalKeyboardKey.space,
    modifiers: [Platform.isMacOS ? HotKeyModifier.meta : HotKeyModifier.control, HotKeyModifier.shift],
  );

  static String get hotKeyLabel => Platform.isMacOS ? '⌘⇧Space' : 'Ctrl+Shift+Space';

  bool? _hotKeyOn;
  bool? _closeToTray;
  bool? _browserOn;
  bool? _screenshotProtection;
  AppPhase? _phase;
  Object? _pairing;

  /// 在 `runApp` 之前调用。
  static Future<void> ensureInitialized() async {
    await windowManager.ensureInitialized();
    await hotKeyManager.unregisterAll(); // 热重启后清理上次注册
  }

  Future<void> start() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    try {
      await trayManager.setIcon(Platform.isWindows ? 'assets/tray/tray_icon.ico' : 'assets/tray/tray_icon.png');
      await trayManager.setToolTip('VaultOne');
    } catch (e) {
      // 托盘不可用（如 GNOME 未装 AppIndicator）时不影响主窗口
      VaultApi.log('tray unavailable: ${e.runtimeType}', level: 'warn');
    }
    state.addListener(_sync);
    await _sync();
  }

  Future<void> dispose() async {
    state.removeListener(_sync);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
  }

  /// 跟随设置与锁定状态更新快捷键注册、关闭行为与托盘菜单。
  Future<void> _sync() async {
    final s = state.settings;
    if (_closeToTray != s.closeToTray) {
      _closeToTray = s.closeToTray;
      await windowManager.setPreventClose(s.closeToTray);
    }
    if (_hotKeyOn != s.globalHotkey) {
      _hotKeyOn = s.globalHotkey;
      try {
        if (s.globalHotkey) {
          await hotKeyManager.register(hotKey, keyDownHandler: (_) => quickSearch());
        } else {
          await hotKeyManager.unregister(hotKey);
        }
      } catch (e) {
        // 快捷键已被其他程序占用
        VaultApi.log('hotkey register failed: ${e.runtimeType}', level: 'warn');
      }
    }
    if (_screenshotProtection != s.screenshotProtection) {
      _screenshotProtection = s.screenshotProtection;
      try {
        final ok = VaultApi.setScreenshotProtection(s.screenshotProtection);
        // 平台不支持时如实记一笔，界面据此把开关标成不可用。
        if (!ok) VaultApi.log('screenshot protection unsupported on this platform', level: 'warn');
      } catch (e) {
        VaultApi.log('screenshot protection failed: ${e.runtimeType}', level: 'warn');
      }
    }
    // 等设置从本地库载入后再启停，避免按默认值先启动一次
    if (state.phase != AppPhase.loading && _browserOn != s.browserIntegration) {
      _browserOn = s.browserIntegration;
      if (s.browserIntegration) {
        state.startBrowserBridge();
      } else {
        await state.stopBrowserBridge();
      }
    }
    // 扩展请求配对时把窗口带到前台
    if (_pairing != state.pendingPairing) {
      _pairing = state.pendingPairing;
      if (_pairing != null) await showWindow();
    }
    if (_phase != state.phase) {
      _phase = state.phase;
      await _menu();
    }
  }

  Future<void> _menu() async {
    final unlocked = state.phase == AppPhase.unlocked;
    // 托盘菜单由原生层渲染，没有 BuildContext，按当前设置的语言直接取词。
    String t(String source) => AppStrings.translate(source, state.settings.language);
    try {
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: t(AppStrings.trayOpen)),
        MenuItem(key: 'search', label: '${t(AppStrings.trayQuickSearch)}    $hotKeyLabel'),
        MenuItem.separator(),
        MenuItem(key: 'lock', label: t(AppStrings.lockNow), disabled: !unlocked),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: t(AppStrings.trayQuit)),
      ]));
    } catch (_) {}
  }

  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// 唤起窗口并请求聚焦搜索框（锁定状态下停在解锁页）。
  Future<void> quickSearch() async {
    await showWindow();
    state.requestQuickSearch();
  }

  Future<void> quit() async {
    await state.lock();
    await dispose();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    // setPreventClose(true) 时关闭按钮只会触发本回调
    if (state.settings.closeToTray) {
      // 隐藏到托盘后保险库仍是解锁状态，等于把锁敞着；「退出即锁定」打开时先锁再隐藏。
      if (state.settings.lockOnExit) state.lock();
      unawaited(windowManager.hide());
    } else {
      unawaited(quit());
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(showWindow());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'search':
        unawaited(quickSearch());
      case 'lock':
        unawaited(state.lock());
      case 'quit':
        unawaited(quit());
    }
  }
}
