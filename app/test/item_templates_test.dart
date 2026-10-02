import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/item_templates.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/home.dart';
import 'package:vaultone/src/ui/screens/item_editor.dart';
import 'package:vaultone/src/ui/theme.dart';

Future<void> _pumpEditor(WidgetTester tester, ItemEditor editor) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: editor),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('每类条目都有模板，且模板字段属于对应类型', () {
    for (final kind in ItemKind.values) {
      final templates = itemTemplatesFor(kind);
      expect(templates, isNotEmpty, reason: '${kind.wire}缺少模板');
      expect(templates.every((t) => t.kind == kind), isTrue);
      expect(
        templates.any((t) => t.fields.isNotEmpty),
        isTrue,
        reason: '${kind.wire}缺少带预置字段的模板',
      );
    }
  });

  testWidgets('新建登录条目可选择模板，模板切换只预置字段不覆盖标题', (tester) async {
    await _pumpEditor(
      tester,
      ItemEditor(
        target: EditTarget.create(ItemKind.login),
        onCancel: () {},
        onSaved: (_) {},
      ),
    );

    expect(find.text('从模板开始'), findsOneWidget);
    expect(find.text('网站'), findsOneWidget);
    expect(find.text('API Key'), findsNothing);

    await tester.tap(find.text('API / 开发者账号'));
    await tester.pumpAndSettle();

    expect(find.text('API 凭据'), findsOneWidget);
    expect(find.text('API Key'), findsOneWidget);
    expect(find.text('API Secret'), findsOneWidget);
    expect(find.text('网站'), findsNothing);
    expect(find.byTooltip('敏感字段（默认隐藏）'), findsNWidgets(2));

    await tester.tap(find.text('API / 开发者账号'));
    await tester.pumpAndSettle();
    expect(find.text('API Key'), findsOneWidget, reason: '重复应用模板不应重复添加字段');

    await tester.tap(find.text('完整字段'));
    await tester.pumpAndSettle();
    expect(find.text('网站'), findsOneWidget);
    expect(find.text('API Key'), findsNothing);
    expect(find.text('API 凭据'), findsOneWidget, reason: '清除模板不应清空用户标题');
  });

  testWidgets('编辑已有条目不显示模板选择', (tester) async {
    await _pumpEditor(
      tester,
      ItemEditor(
        target: EditTarget.edit('item-1', ItemKind.login),
        initial: const ItemData(kind: ItemKind.login, title: '已有条目'),
        onCancel: () {},
        onSaved: (_) {},
      ),
    );

    expect(find.text('从模板开始'), findsNothing);
    expect(find.text('网站'), findsOneWidget);
  });
}
