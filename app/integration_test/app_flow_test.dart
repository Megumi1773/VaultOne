// 端到端 UI 流程测试（真实 Rust 内核 + 真实 SQLite 文件）：
// 建号 → 保存 Recovery Kit 确认 → 新建登录条目 → 锁定 → 错误主密码 → 正确主密码解锁 → 条目仍在。
//
// 运行：cd app && flutter test integration_test -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vaultone/src/app.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/ffi.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/conflicts_page.dart';
import 'package:vaultone/src/ui/screens/item_editor.dart';
import 'package:vaultone/src/ui/screens/item_list.dart';
import 'package:vaultone/src/rust/frb_generated.dart';

const _password = 'Correct-Horse-Battery-Staple-42';

Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().take(40).join(' | ');
  throw TestFailure('等待超时：$finder；当前可见文本：$texts');
}

Future<void> enter(WidgetTester tester, int index, String text, {Finder? within}) async {
  final field = (within == null ? find.byType(TextField) : find.descendant(of: within, matching: find.byType(TextField))).at(index);
  await tester.enterText(field, text);
  await tester.pump();
  // 桌面端输入连接在焦点未变化时可能不重建：直接写入控制器兜底
  final controller = tester.widget<TextField>(field).controller;
  if (controller != null && controller.text != text) {
    controller.text = text;
    await tester.pump();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUpAll(() async {
    await RustLib.init();
    tmp = await Directory.systemTemp.createTemp('vaultone_it_');
  });
  tearDownAll(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('建号 → 条目 → 锁定 → 解锁', (tester) async {
    await tester.pumpWidget(VaultOneApp(dbPath: '${tmp.path}/vault.db', logDir: '${tmp.path}/logs'));

    // 首启隐私同意
    await waitFor(tester, find.text('同意并继续'));
    await tester.tap(find.text('同意并继续'));

    // 欢迎页
    await waitFor(tester, find.text('创建我的保险库'));
    await tester.tap(find.text('创建我的保险库'));
    await waitFor(tester, find.text('设置主密码'));

    // 建号表单：邮箱 / 主密码 / 确认
    await enter(tester, 0, 'it@example.com');
    await enter(tester, 1, _password);
    await enter(tester, 2, _password);
    await tester.tap(find.text('创建保险库'));

    // Recovery Kit：复制 Secret Key 视为已保存 → 勾选确认 → 进入
    await waitFor(tester, find.text('保存你的 Recovery Kit'));
    // 锚定行首：随机恢复码的某组可能以 "V1" 结尾（如 …-DJV1-…），不锚定会偶发匹配两处
    expect(find.textContaining(RegExp(r'^V1-')), findsOneWidget);
    expect(find.textContaining(RegExp(r'^R1-')), findsOneWidget);
    await tester.tap(find.byTooltip('复制').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('进入保险库'));

    // 主界面：新建登录条目
    await waitFor(tester, find.text('选择一个条目查看详情'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await waitFor(tester, find.text('保存'));
    await enter(tester, 0, 'GitHub 集成测试', within: find.byType(ItemEditor));
    await tester.tap(find.text('保存'));
    // 条目出现在左侧列表中（而不是输入框里的文字）
    final inList = find.descendant(of: find.byType(ItemListPane), matching: find.text('GitHub 集成测试'));
    await waitFor(tester, inList);
    // 锁定
    await tester.tap(find.byTooltip('立即锁定 (Ctrl+L)'));
    await waitFor(tester, find.text('欢迎回来'));
    // 等待页面切换动画结束，旧页面完全卸载
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('GitHub 集成测试'), findsNothing);

    // 错误主密码 → 提示错误且仍停留在解锁页
    await enter(tester, 0, 'definitely-wrong-password');
    await tester.tap(find.text('解锁'));
    await waitFor(tester, find.text('主密码或 Secret Key 不正确'));

    // 正确主密码 → 条目仍在
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await enter(tester, 0, _password);
    await tester.tap(find.text('解锁'));
    await waitFor(tester, inList);

    // 冲突入口走真实生成绑定与SQLite，空态和历史态均可读；锁定销毁该路由。
    await tester.tap(find.text('设置'));
    await waitFor(tester, find.text('查看冲突'));
    await tester.ensureVisible(find.text('查看冲突'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('查看冲突'));
    await waitFor(tester, find.text('没有待处理的冲突'));
    await tester.tap(find.text('显示历史记录'));
    await waitFor(tester, find.text('暂无冲突记录'));
    final state = AppScope.read(tester.element(find.byType(ConflictsPage)));
    await state.lock();
    await waitFor(tester, find.text('欢迎回来'));
    expect(find.byType(ConflictsPage), findsNothing);
    await expectLater(VaultApi.listConflicts(false), throwsA(isA<CoreException>()));

    // 本地数据库文件中没有明文
    final raw = String.fromCharCodes(await File('${tmp.path}/vault.db').readAsBytes());
    expect(raw.contains('it@example.com'), isFalse);
    expect(raw.contains('GitHub'), isFalse);
  });
}
