import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/api.dart';
import 'state/app_state.dart';
import 'state/desktop_shell.dart';
import 'state/scope.dart';
import 'ui/screens/home.dart';
import 'ui/screens/cloud_setup.dart';
import 'ui/screens/onboarding.dart';
import 'ui/screens/unlock.dart';
import 'ui/theme.dart';
import 'ui/widgets/brand.dart';
import 'ui/widgets/controls.dart';
import 'ui/widgets/vault_widgets.dart';

/// 应用根：主题、自动锁定活动检测、生命周期锁定、隐私遮罩、阶段路由。
class VaultOneApp extends StatefulWidget {
  const VaultOneApp({super.key, required this.dbPath, required this.logDir, this.desktopShell = false});

  final String dbPath;
  final String logDir;

  /// 启用系统托盘与全局快捷键（仅正式启动的桌面端；测试中关闭）
  final bool desktopShell;

  @override
  State<VaultOneApp> createState() => _VaultOneAppState();
}

class _VaultOneAppState extends State<VaultOneApp> {
  final _state = AppState();
  late final AppLifecycleListener _lifecycle;
  DesktopShell? _shell;

  /// 移动端切到后台时遮挡内容，避免在多任务界面泄露（iOS 无 FLAG_SECURE，需自行遮挡）。
  bool _obscured = false;

  bool get _mobile => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    // init 自身已兜住各阶段异常并落到 error 状态；这里再兜一层未预期异常，
    // 避免 fire-and-forget 的 future 把错误变成无人处理的异步异常。
    unawaited(_state.init(widget.dbPath, widget.logDir).catchError((Object e) {
      VaultApi.log('init unhandled: ${e.runtimeType}', level: 'error');
    }));
    if (widget.desktopShell) _shell = DesktopShell(_state)..start();
    _lifecycle = AppLifecycleListener(
      onHide: _state.onAppHidden,
      onInactive: () {
        if (_mobile) setState(() => _obscured = true);
      },
      onResume: () => setState(() => _obscured = false),
    );
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  bool _onKey(KeyEvent _) {
    _state.registerActivity();
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _shell?.dispose();
    _lifecycle.dispose();
    _state.dispose();
    super.dispose();
  }

  ThemeMode _themeMode(ThemeModeSetting s) => switch (s) {
        ThemeModeSetting.dark => ThemeMode.dark,
        ThemeModeSetting.light => ThemeMode.light,
        ThemeModeSetting.system => ThemeMode.system,
      };

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: ListenableBuilder(
        listenable: _state,
        builder: (context, _) => MaterialApp(
          // 安全边界改变时销毁整个 Navigator（含已 push 的页面、弹窗和编辑器）。
          // 不对锁定做出场动画，避免上一会话的明文短暂留在屏幕上。
          key: ValueKey((_state.phase, _state.privacyAccepted, _state.sessionEpoch)),
          title: 'VaultOne',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: _themeMode(_state.settings.themeMode),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _state.registerActivity(),
            onPointerSignal: (_) => _state.registerActivity(),
            child: Stack(
              children: [
                child ?? const SizedBox.shrink(),
                const Positioned(right: 20, bottom: 20, child: ClipboardToast()),
                if (_state.pendingPairing != null) Positioned.fill(child: _PairingPrompt(state: _state)),
                if (_obscured) const Positioned.fill(child: _PrivacyCover()),
              ],
            ),
          ),
          home: _PhaseRouter(state: _state),
        ),
      ),
    );
  }
}

class _PhaseRouter extends StatelessWidget {
  const _PhaseRouter({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final Widget page = !state.privacyAccepted && state.phase != AppPhase.loading && state.phase != AppPhase.error
        ? const OnboardingScreen()
        : switch (state.phase) {
      AppPhase.loading => const _Splash(),
      AppPhase.onboarding => const OnboardingScreen(),
      AppPhase.locked => state.pendingEnrollment != null ? const OnboardingScreen() : const UnlockScreen(),
      AppPhase.cloudSetup => const CloudSetupScreen(),
      AppPhase.unlocked => const HomeScreen(),
      AppPhase.error => FatalScreen(message: state.fatalError ?? '未知错误'),
    };
    return Scaffold(
      body: AnimatedSwitcher(
        duration: Zo.slow,
        switchInCurve: Zo.ease,
        child: KeyedSubtree(key: ValueKey(state.phase), child: page),
      ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Center(child: ZoMark(size: 56));
}

class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: context.zo.bg,
        child: const Center(child: ZoWordmark(size: 22)),
      );
}

/// 浏览器扩展配对确认。配对码由扩展生成的密钥派生，两端一致才说明连接的是用户自己的浏览器。
class _PairingPrompt extends StatelessWidget {
  const _PairingPrompt({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.pendingPairing!;
    // 位于 Navigator 之上，需自带 Material 提供文本样式与水波纹
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ZoPanel(
            color: context.zo.surface,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('连接浏览器扩展？', style: context.text.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  '「${p.name}」中的 VaultOne 扩展请求连接。请确认扩展弹窗中显示的配对码与下方一致；不一致或不是你发起的，请拒绝。',
                  style: context.text.bodyMedium?.copyWith(color: context.zo.textMuted),
                ),
                const SizedBox(height: 18),
                Center(child: Text(p.code, style: monoStyle(context, size: 28, weight: FontWeight.w700, spacing: 3))),
                const SizedBox(height: 22),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  ZoButton(label: '拒绝', variant: ZoButtonVariant.ghost, onPressed: () => state.respondPairing(false)),
                  const SizedBox(width: 8),
                  ZoButton(label: '配对码一致，允许连接', onPressed: () => state.respondPairing(true)),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
