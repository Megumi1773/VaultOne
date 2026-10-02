import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/home.dart';
import 'package:vaultone/src/ui/screens/settings_page.dart';
import 'package:vaultone/src/ui/theme.dart';

const _phone = Size(390, 844);
const _desktop = Size(1280, 800);

Future<AppState> _pumpHome(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.dark),
    // 真实路径里 _PhaseRouter 会套一层 Scaffold，这里保持一致。
    home: Scaffold(body: AppScope(state: state, child: const HomeScreen())),
  ));
  await tester.pumpAndSettle();
  // 先卸载再释放：HomeScreen 会在 dispose 里摘除监听。
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  return state;
}

void main() {
  testWidgets('手机宽度：底部导航承载一级入口，分类下沉为过滤条，不再用侧栏', (tester) async {
    await _pumpHome(tester, _phone);

    for (final label in ['保险库', '生成器', '安全', '设置']) {
      expect(find.text(label), findsOneWidget, reason: '底部导航缺少 $label');
    }
    for (final label in ['全部', '收藏', '登录', '支付卡', '笔记', '身份']) {
      expect(find.text(label), findsOneWidget, reason: '过滤条缺少 $label');
    }
    // 桌面侧栏的条目名不应出现在手机布局里。
    expect(find.text('全部条目'), findsNothing);
    expect(find.text('密码生成器'), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('手机宽度：切 Tab 换页，切回保险库回到条目列表', (tester) async {
    await _pumpHome(tester, _phone);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);

    await tester.tap(find.text('保险库'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('手机宽度：回收站过滤条下不出现新建按钮', (tester) async {
    await _pumpHome(tester, _phone);

    await tester.drag(find.byType(ListView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('回收站是空的'), findsOneWidget);
  });

  // 「安全」页在 initState 里直连 Rust 内核（VaultApi.audit），纯 widget 测试没有桥，
  // 它的手机宽度渲染由 integration_test/screenshots_test.dart 覆盖。
  testWidgets('手机宽度：可离线的 Tab 依次渲染均无布局溢出', (tester) async {
    await _pumpHome(tester, _phone);

    for (final label in ['生成器', '设置', '保险库']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$label 在手机宽度下渲染异常');
    }
  });

  testWidgets('桌面宽度：保留侧栏分区，不出现底部导航', (tester) async {
    await _pumpHome(tester, _desktop);

    // 侧栏用完整分区名，底部导航用短标签，两者不会混淆。
    expect(find.text('密码生成器'), findsOneWidget);
    expect(find.text('安全中心'), findsOneWidget);
    expect(find.text('全部条目'), findsWidgets);
    expect(find.text('保险库'), findsNothing);
    expect(find.text('生成器'), findsNothing);
    expect(find.text('安全'), findsNothing);
  });
}
