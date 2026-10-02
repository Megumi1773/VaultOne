import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/item_detail.dart' show FieldRow;
import 'package:vaultone/src/ui/screens/settings_page.dart';
import 'package:vaultone/src/ui/theme.dart';

/// 只替换 FRB 边界：测试仍执行真实 AppState 与设置页。
class _Bridge implements RustLibApi {
  final settings = <String, String>{};
  int setCalls = 0;

  @override
  Future<String?> crateApiVaultGetSetting({required String key}) async => settings[key];
  @override
  Future<void> crateApiVaultSetSetting({required String key, required String value}) async {
    setCalls++;
    settings[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<(AppState, _Bridge)> _mountSettings(WidgetTester tester, {AppState? state}) async {
  final bridge = _Bridge();
  RustLib.initMock(api: bridge);
  addTearDown(RustLib.dispose);
  final app = state ?? (AppState()..phase = AppPhase.unlocked..privacyAccepted = true);
  addTearDown(app.dispose);
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: app,
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(body: SettingsPage(initialSection: SettingsSection.security)),
    ),
  ));
  await tester.pumpAndSettle();
  return (app, bridge);
}

/// 找到某一行标题对应的开关。
Finder _switchFor(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );

void main() {
  testWidgets('自动锁定提供 1/3/5/10/15/30/60 与「从未」', (tester) async {
    await _mountSettings(tester);
    await tester.tap(find.text('10 分钟').first);
    await tester.pumpAndSettle();
    for (final m in [1, 3, 5, 10, 15, 30, 60]) {
      expect(find.text('$m 分钟'), findsWidgets, reason: '应提供 $m 分钟选项');
    }
    expect(find.text('从未'), findsWidgets, reason: '还应能关闭自动锁定');
  });

  testWidgets('退出即锁定默认打开，关掉后写入设置', (tester) async {
    final (state, bridge) = await _mountSettings(tester);
    expect(state.settings.lockOnExit, isTrue, reason: '默认应锁定');

    await tester.tap(_switchFor('退出即锁定'));
    await tester.pumpAndSettle();
    expect(state.settings.lockOnExit, isFalse);
    expect(bridge.settings['lock_on_exit'], '0');
  });

  testWidgets('剪贴板开关与延时分家：关掉写 0，打开回到 30 秒', (tester) async {
    final (state, bridge) = await _mountSettings(tester);
    expect(state.settings.clipboardSeconds, 30);

    await tester.tap(_switchFor('剪贴板自动清除'));
    await tester.pumpAndSettle();
    expect(state.settings.clipboardSeconds, 0);
    expect(bridge.settings['clipboard_seconds'], '0');
    // 关掉后文案要跟着变，否则与开关状态自相矛盾。
    expect(find.text('不自动清空'), findsWidgets);

    await tester.tap(_switchFor('剪贴板自动清除'));
    await tester.pumpAndSettle();
    expect(state.settings.clipboardSeconds, 30);
    expect(bridge.settings['clipboard_seconds'], '30');
  });

  testWidgets('截图保护：平台不支持时禁用开关并说明原因', (tester) async {
    final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
    state.screenshotProtectionSupported = false;
    final (app, bridge) = await _mountSettings(tester, state: state);

    expect(tester.widget<Switch>(_switchFor('截图保护')).onChanged, isNull, reason: '不支持时不可点');
    expect(find.text('当前平台不支持截图保护'), findsWidgets);
    expect(app.settings.screenshotProtection, isFalse);
    expect(bridge.setCalls, 0, reason: '不该写入无效设置');
  });

  testWidgets('截图保护：平台支持时可开关并持久化', (tester) async {
    final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
    state.screenshotProtectionSupported = true;
    final (app, bridge) = await _mountSettings(tester, state: state);

    expect(tester.widget<Switch>(_switchFor('截图保护')).onChanged, isNotNull);
    await tester.tap(_switchFor('截图保护'));
    await tester.pumpAndSettle();
    expect(app.settings.screenshotProtection, isTrue);
    expect(bridge.settings['screenshot_protection'], '1');
  });

  testWidgets('默认隐藏密码打开时详情页打码，关掉后直接显示明文', (tester) async {
    final bridge = _Bridge();
    RustLib.initMock(api: bridge);
    addTearDown(RustLib.dispose);

    Future<void> mount({required bool mask}) async {
      final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
      state.settings = Settings(maskPasswords: mask);
      addTearDown(state.dispose);
      await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: FieldRow(label: '密码', value: 'Sup3r-Secret-Pass', secret: true, onCopy: () {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    await mount(mask: true);
    expect(find.text('Sup3r-Secret-Pass'), findsNothing, reason: '默认应打码');
    expect(find.textContaining('•'), findsOneWidget);

    // 换一个 State：同一个 widget 类型在同一位置会复用 State，设置不会重新生效。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await mount(mask: false);
    expect(find.text('Sup3r-Secret-Pass'), findsOneWidget, reason: '关掉打码后应直接显示明文');
  });

  testWidgets('改设置不会把已经揭开的字段又盖回去', (tester) async {
    final bridge = _Bridge();
    RustLib.initMock(api: bridge);
    addTearDown(RustLib.dispose);
    final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
    state.settings = const Settings(maskPasswords: true);
    addTearDown(state.dispose);

    await tester.pumpWidget(AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: FieldRow(label: '密码', value: 'Sup3r-Secret-Pass', secret: true, onCopy: () {})),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Sup3r-Secret-Pass'), findsOneWidget);

    // 重新挂载同一棵树（触发 didChangeDependencies），已揭开的字段不应被打回。
    state.settings = const Settings(maskPasswords: false);
    state.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Sup3r-Secret-Pass'), findsOneWidget);
  });
}
