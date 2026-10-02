import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/home.dart';
import 'package:vaultone/src/ui/screens/item_editor.dart';
import 'package:vaultone/src/ui/theme.dart';

Future<void> _pumpEditor(WidgetTester tester, ItemEditor editor) async {
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: editor)),
  );
  await tester.pumpAndSettle();
}

/// 在标签输入框里输入并回车确认。
Future<void> _addTag(WidgetTester tester, String tag) async {
  await tester.enterText(find.byKey(const Key('tag-input')), tag);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('标签回车确认后成为可删除标签，重复标签不新增', (tester) async {
    await _pumpEditor(
      tester,
      ItemEditor(
        target: EditTarget.create(ItemKind.login),
        onCancel: () {},
        onSaved: (_) {},
      ),
    );

    expect(find.text('标签与分类'), findsOneWidget);

    await _addTag(tester, '工作');
    expect(find.text('工作'), findsOneWidget);

    // 忽略大小写的重复标签不应产生第二个标签，也不应报错。
    await _addTag(tester, '工作');
    expect(find.text('工作'), findsOneWidget, reason: '重复标签不应重复添加');
  });

  testWidgets('编辑已有条目会带出已保存的标签与分类', (tester) async {
    await _pumpEditor(
      tester,
      ItemEditor(
        target: EditTarget.edit('item-1', ItemKind.login),
        initial: const ItemData(
          kind: ItemKind.login,
          title: '已有条目',
          tags: ['生产', '基础设施'],
          category: '运维',
        ),
        onCancel: () {},
        onSaved: (_) {},
      ),
    );

    expect(find.text('生产'), findsOneWidget);
    expect(find.text('基础设施'), findsOneWidget);
    expect(find.text('运维'), findsOneWidget);
  });

  testWidgets('标签数量达到上限后输入框禁用并提示', (tester) async {
    await _pumpEditor(
      tester,
      ItemEditor(
        target: EditTarget.edit('item-1', ItemKind.login),
        initial: ItemData(
          kind: ItemKind.login,
          title: '已有条目',
          tags: [for (var i = 0; i < itemTagLimit; i++) 'tag$i'],
        ),
        onCancel: () {},
        onSaved: (_) {},
      ),
    );

    expect(find.text('最多 $itemTagLimit 个标签'), findsOneWidget);
  });
}
