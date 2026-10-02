import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/taxonomy_dialog.dart';
import 'package:vaultone/src/ui/theme.dart';

VaultItem _item(String title, {List<String> tags = const [], String? category}) => VaultItem(
      id: title,
      vaultId: 'v',
      revision: 1,
      data: ItemData(kind: ItemKind.login, title: title, tags: tags, category: category),
    );

CategoryNode _node(String name, String path, {int direct = 0, int total = 0, List<CategoryNode> children = const []}) =>
    CategoryNode(name: name, path: path, direct: direct, total: total, children: children);

/// 记录调用的假实现：这里只验证界面把**正确的参数**交给内核，改写规则本身在内核测试里。
class _Calls {
  final renamedTags = <(String, String)>[];
  final deletedTags = <String>[];
  final renamedCategories = <(String, String)>[];
  final clearedCategories = <String>[];
  int affected = 3;
}

Future<_Calls> _mount(
  WidgetTester tester, {
  required List<VaultItem> items,
  List<CategoryNode> tree = const [],
}) async {
  final calls = _Calls();
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: TaxonomyDialog(
        items: items,
        categoryTree: tree,
        renameTag: (from, to) async {
          calls.renamedTags.add((from, to));
          return calls.affected;
        },
        deleteTag: (tag) async {
          calls.deletedTags.add(tag);
          return calls.affected;
        },
        renameCategory: (from, to) async {
          calls.renamedCategories.add((from, to));
          return calls.affected;
        },
        clearCategory: (path) async {
          calls.clearedCategories.add(path);
          return calls.affected;
        },
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  testWidgets('标签按出现次数降序展示，并统计条目数', (tester) async {
    await _mount(tester, items: [
      _item('A', tags: ['工作', '个人']),
      _item('B', tags: ['工作']),
      _item('C', tags: ['工作', '旧']),
    ]);
    // 工作 3 条、个人 1 条、旧 1 条；同次数按名称排序。
    final rows = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).whereType<String>().toList();
    expect(rows, contains('工作'));
    expect(rows, contains('3'), reason: '工作 出现在 3 条条目上');
    expect(rows.where((t) => t == '1').length, 2, reason: '个人 与 旧 各 1 条');
  });

  testWidgets('没有标签时给出空态而不是空白列表', (tester) async {
    await _mount(tester, items: [_item('A')]);
    expect(find.text('还没有任何标签'), findsOneWidget);
  });

  testWidgets('重命名标签把原标签与新名称交给内核', (tester) async {
    final calls = await _mount(tester, items: [
      _item('A', tags: ['工作']),
      _item('B', tags: ['工作']),
    ]);
    await tester.tap(find.byTooltip('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名标签'), findsOneWidget);
    expect(find.textContaining('不区分大小写'), findsOneWidget, reason: '要说明匹配口径');

    await tester.enterText(find.byType(TextField), '职业');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls.renamedTags, [('工作', '职业')]);
    expect(find.textContaining('已更新 3 条条目'), findsOneWidget, reason: '要如实报告受影响条目数');
  });

  testWidgets('新名称与原名相同时不调用内核', (tester) async {
    final calls = await _mount(tester, items: [_item('A', tags: ['工作'])]);
    await tester.tap(find.byTooltip('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls.renamedTags, isEmpty, reason: '同名改名是空操作，不该白跑一趟');
  });

  testWidgets('删除标签需要确认，取消后不调用内核', (tester) async {
    final calls = await _mount(tester, items: [_item('A', tags: ['工作'])]);
    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('条目本身不会被删除'), findsOneWidget, reason: '破坏性操作要说清后果');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls.deletedTags, isEmpty);

    await tester.tap(find.byTooltip('删除'));
    await tester.pumpAndSettle();
    // 确认弹窗的标题与按钮都是「删除」，取最后一个（按钮）。
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(calls.deletedTags, ['工作']);
  });

  testWidgets('分类按层级顺序展示，计数取含后代的 total', (tester) async {
    await _mount(
      tester,
      items: const [],
      tree: [
        _node('工作', '工作', direct: 1, total: 4, children: [_node('生产', '工作/生产', direct: 3, total: 3)]),
      ],
    );
    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('工作/生产'), findsOneWidget);
    expect(find.text('4'), findsOneWidget, reason: '父分类显示含后代汇总');
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('重命名分类走前缀改写，确认文案说明子分类会跟着走', (tester) async {
    final calls = await _mount(tester, items: const [], tree: [_node('工作', '工作', total: 2)]);
    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名分类'), findsOneWidget);
    expect(find.textContaining('子分类会一起移动'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '职业');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls.renamedCategories, [('工作', '职业')]);
  });

  testWidgets('清空分类要确认，并说明不会删除条目', (tester) async {
    final calls = await _mount(tester, items: const [], tree: [_node('工作', '工作', total: 5)]);
    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 5 条条目'), findsOneWidget);
    expect(find.textContaining('条目本身不会被删除'), findsOneWidget);

    await tester.tap(find.text('清空').last);
    await tester.pumpAndSettle();
    expect(calls.clearedCategories, ['工作']);
  });

  testWidgets('没有分类时给出空态', (tester) async {
    await _mount(tester, items: const []);
    await tester.tap(find.text('分类'));
    await tester.pumpAndSettle();
    expect(find.text('还没有任何分类'), findsOneWidget);
  });
}
