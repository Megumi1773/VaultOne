import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'state/app_state.dart';
import 'state/scope.dart';
import 'ui/screens/home.dart';
import 'ui/screens/onboarding.dart';
import 'ui/screens/unlock.dart';
import 'ui/theme.dart';
import 'ui/widgets/brand.dart';
import 'ui/widgets/vault_widgets.dart';

/// 应用根：主题、自动锁定活动检测、生命周期锁定、隐私遮罩、阶段路由。
class VaultOneApp extends StatefulWidget {
  const VaultOneApp({super.key, required this.dbPath, required this.logDir});

  final String dbPath;
  final String logDir;

  @override
  State<VaultOneApp> createState() => _VaultOneAppState();
}

class _VaultOneAppState extends State<VaultOneApp> {
  final _state = AppState();
  late final AppLifecycleListener _lifecycle;

  /// 移动端切到后台时遮挡内容，避免在多任务界面泄露（iOS 无 FLAG_SECURE，需自行遮挡）。
  bool _obscured = false;

  bool get _mobile => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _state.init(widget.dbPath, widget.logDir);
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
    final Widget page = switch (state.phase) {
      AppPhase.loading => const _Splash(),
      AppPhase.onboarding => const OnboardingScreen(),
      AppPhase.locked => state.pendingEnrollment != null ? const OnboardingScreen() : const UnlockScreen(),
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
