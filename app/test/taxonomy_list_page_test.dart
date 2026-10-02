import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/home.dart' show categoryAncestors;
import 'package:vaultone/src/ui/screens/taxonomy_list_page.dart';
import 'package:vaultone/src/ui/theme.dart';

VaultItem _item(String title, {List<String> tags = const [], String? category, bool favorite = false}) => VaultItem(
      id: title,
      vaultId: 'v',
      revision: 1,
      data: ItemData(kind: ItemKind.login, title: title, tags: tags, category: category, favorite: favorite),
    );

Future<List<String>> _mount(
  WidgetTester tester, {
  required TaxonomyDimension dimension,
  required String value,
  required List<VaultItem> items,
  bool isTrash = false,
}) async {
  final opened = <String>[];
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: TaxonomyListPage(
      dimension: dimension,
      value: value,
      items: items,
      onOpenItem: (item) => opened.add(item.id),
      isTrash: isTrash,
    ),
  ));
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  test('categoryAncestors 与内核同规则：分段、去空白、丢空段', () {
    expect(categoryAncestors('工作/生产/服务器'), ['工作', '工作/生产', '工作/生产/服务器']);
    expect(categoryAncestors('  工作 / / 生产 '), ['工作', '工作/生产']);
    expect(categoryAncestors(''), isEmpty);
  });

  testWidgets('标签页只显示带该标签的条目，标题与计数正确', (tester) async {
    await _mount(
      tester,
      dimension: TaxonomyDimension.tag,
      value: 'work',
      items: [_item('A', tags: ['Work']), _item('B', tags: ['个人']), _item('C', tags: ['工作'])],
    );
    expect(find.text('标签：work'), findsWidgets);
    expect(find.text('共 1 条'), findsOneWidget, reason: 'Work 与 work 是同一个标签，大小写不敏感');
    expect(find.text('A'), findsWidgets);
    expect(find.text('B'), findsNothing);
    expect(find.text('C'), findsNothing, reason: '「工作」是另一个标签，不该被 work 命中');
  });

  testWidgets('分类页含后代，且显示面包屑', (tester) async {
    await _mount(
      tester,
      dimension: TaxonomyDimension.category,
      value: '工作/生产',
      items: [
        _item('直属', category: '工作/生产'),
        _item('子级', category: '工作/生产/服务器'),
        _item('同级', category: '工作/测试'),
      ],
    );
    expect(find.text('分类：工作/生产'), findsWidgets);
    expect(find.text('共 2 条'), findsOneWidget, reason: '含后代但不含同级');
    expect(find.text('工作 / 工作/生产'), findsOneWidget, reason: '面包屑说明所在层级');
    expect(find.text('直属'), findsWidgets);
    expect(find.text('子级'), findsWidgets);
    expect(find.text('同级'), findsNothing);
  });

  testWidgets('搜索只在当前维度内过滤', (tester) async {
    await _mount(
      tester,
      dimension: TaxonomyDimension.tag,
      value: '工作',
      items: [
        _item('GitHub', tags: ['工作']),
        _item('GitLab', tags: ['工作']),
        _item('Gmail', tags: ['个人']),
      ],
    );
    await tester.enterText(find.byType(TextField).first, 'git');
    await tester.pumpAndSettle();
    expect(find.text('共 2 条'), findsOneWidget);
    expect(find.text('GitHub'), findsWidgets);
    expect(find.text('GitLab'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'mail');
    await tester.pumpAndSettle();
    expect(find.text('共 0 条'), findsOneWidget, reason: 'Gmail 不在这个标签下，不该被搜出来');
  });

  testWidgets('空维度给出空态而不是崩', (tester) async {
    await _mount(tester, dimension: TaxonomyDimension.tag, value: '不存在', items: [_item('A', tags: ['工作'])]);
    expect(find.text('共 0 条'), findsOneWidget);
  });

  testWidgets('点条目回调打开的条目 id', (tester) async {
    final opened = await _mount(
      tester,
      dimension: TaxonomyDimension.tag,
      value: '工作',
      items: [_item('GitHub', tags: ['工作'])],
    );
    await tester.tap(find.text('GitHub').first);
    await tester.pumpAndSettle();
    expect(opened, ['GitHub']);
  });

  testWidgets('回收站维度只列回收站条目', (tester) async {
    // 通过 isTrash 走回收站分区；此处的 items 就是调用方传进来的回收站列表。
    await _mount(
      tester,
      dimension: TaxonomyDimension.tag,
      value: '工作',
      items: [_item('已删', tags: ['工作'])],
      isTrash: true,
    );
    expect(find.text('共 1 条'), findsOneWidget);
    expect(find.text('已删'), findsWidgets);
  });
}
