import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/home.dart' show Section;
import 'package:vaultone/src/ui/screens/settings_page.dart';
import 'package:vaultone/src/ui/screens/sidebar_layout.dart';
import 'package:vaultone/src/ui/theme.dart';

/// 只替换 FRB 边界：测试仍执行真实 AppState 与设置页。
class _Bridge implements RustLibApi {
  final settings = <String, String>{};

  @override
  Future<String?> crateApiVaultGetSetting({required String key}) async => settings[key];
  @override
  Future<void> crateApiVaultSetSetting({required String key, required String value}) async {
    settings[key] = value;
  }

  /// 未用到的 FRB 方法走默认实现，这样测试只声明它真正需要的那两个。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AppState> _mount(WidgetTester tester, {String layout = ''}) async {
  RustLib.initMock(api: _Bridge());
  addTearDown(RustLib.dispose);
  final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
  state.settings = Settings(sidebarLayout: layout);
  addTearDown(state.dispose);
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: state,
    child: MaterialApp(
      theme: buildTheme(Brightness.light),
      home: const Scaffold(body: SettingsPage(initialSection: SettingsSection.sidebarLayout)),
    ),
  ));
  await tester.pumpAndSettle();
  return state;
}

/// 找到某一行标题对应的开关（行内既有上下移按钮也有开关，取最后一个 Switch）。
Finder _switchFor(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );

void main() {
  testWidgets('板块列表按当前布局渲染，并给出上移/下移/显隐', (tester) async {
    await _mount(tester);
    expect(find.text('首页板块'), findsOneWidget);
    for (final s in [Section.all, Section.favorites, Section.login, Section.trash]) {
      expect(find.text(s.title(tester.element(find.byType(SettingsPage)))), findsOneWidget);
    }
    // 设置页一次性布局，其他分区也有开关，因此按本分区独有的「上移」按钮计数。
    expect(find.byTooltip('上移'), findsNWidgets(defaultSidebarLayout().length));
    expect(find.text('恢复默认布局'), findsOneWidget);
  });

  testWidgets('上移会改写布局并持久化到本机设置', (tester) async {
    final state = await _mount(tester);
    // 「收藏」原本在第 2 位，上移后应排到「全部条目」之前。
    final up = find.byTooltip('上移');
    await tester.tap(up.at(1));
    await tester.pumpAndSettle();

    final layout = resolveSidebarLayout(state.settings.sidebarLayout);
    expect(layout.first.section, Section.favorites);
    expect(layout[1].section, Section.all);
    // 保存的是 JSON 字符串，读回来必须一致。
    expect(state.settings.sidebarLayout, isNotEmpty);
  });

  testWidgets('首项不能再上移、末项不能再下移', (tester) async {
    final state = await _mount(tester);
    final before = state.settings.sidebarLayout;
    await tester.tap(find.byTooltip('上移').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下移').last);
    await tester.pumpAndSettle();
    expect(state.settings.sidebarLayout, before, reason: '越界的移动不应写入设置');
  });

  testWidgets('隐藏一项后该分区从侧栏布局里消失，但设置里仍保留顺序', (tester) async {
    final state = await _mount(tester);
    await tester.tap(_switchFor('收藏'));
    await tester.pumpAndSettle();

    final layout = resolveSidebarLayout(state.settings.sidebarLayout);
    final favorites = layout.firstWhere((e) => e.section == Section.favorites);
    expect(favorites.visible, isFalse);
    expect(layout.map((e) => e.section).toList(), defaultSidebarLayout().map((e) => e.section).toList(),
        reason: '隐藏只改 visible，不改变顺序');
  });

  testWidgets('不允许把最后一项可见也关掉', (tester) async {
    // 先造出「只剩一项可见」的布局。
    final onlyOne = encodeSidebarLayout([
      for (final e in defaultSidebarLayout()) e.copyWith(visible: e.section == Section.all),
    ]);
    final state = await _mount(tester, layout: onlyOne);

    final sw = _switchFor('全部条目');
    expect(tester.widget<Switch>(sw).onChanged, isNull, reason: '唯一可见项必须禁用开关');
    expect(tester.widget<Switch>(_switchFor('收藏')).onChanged, isNotNull, reason: '隐藏项可以随时打开');
    expect(resolveSidebarLayout(state.settings.sidebarLayout).where((e) => e.visible), hasLength(1));
  });

  testWidgets('恢复默认布局把顺序与显隐一起还原', (tester) async {
    final messy = encodeSidebarLayout([
      for (final e in defaultSidebarLayout().reversed) e.copyWith(visible: e.section != Section.trash),
    ]);
    final state = await _mount(tester, layout: messy);
    expect(resolveSidebarLayout(state.settings.sidebarLayout).first.section, Section.trash);

    await tester.tap(find.text('恢复默认布局'));
    await tester.pumpAndSettle();
    expect(resolveSidebarLayout(state.settings.sidebarLayout), defaultSidebarLayout());
  });

  testWidgets('损坏的布局设置不会让设置页崩掉，回退默认', (tester) async {
    await _mount(tester, layout: '{不是 JSON');
    expect(find.text('首页板块'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('上移'), findsNWidgets(defaultSidebarLayout().length));
  });
}
