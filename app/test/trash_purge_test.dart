import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/item_detail.dart';
import 'package:vaultone/src/ui/screens/item_list.dart';
import 'package:vaultone/src/ui/theme.dart';

VaultItem _item(String title) => VaultItem(
      id: 'i-1',
      vaultId: 'v',
      revision: 3,
      // 用笔记条目：详情页不会渲染密码强度徽标（那条路径直连 Rust 桥，纯 widget 测试无桥）。
      data: ItemData(kind: ItemKind.note, title: title, notes: '备注'),
    );

Future<AppState> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1100, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final state = AppState();
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.dark),
    home: Scaffold(body: AppScope(state: state, child: child)),
  ));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  return state;
}

void main() {
  testWidgets('回收站条目的详情页提供「彻底删除」，活动条目不提供', (tester) async {
    await _pump(tester, ItemDetail(item: _item('待抹除'), inTrash: true, onEdit: () {}, onDeleted: () {}));
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('彻底删除'), findsOneWidget);
    expect(find.text('移入回收站'), findsNothing);
  });

  testWidgets('活动条目详情页仍是「移入回收站」，没有彻底删除', (tester) async {
    await _pump(tester, ItemDetail(item: _item('在用'), inTrash: false, onEdit: () {}, onDeleted: () {}));
    expect(find.byTooltip('移入回收站'), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
    expect(find.text('彻底删除'), findsNothing);
  });

  testWidgets('彻底删除需二次确认，正文区分本机与云端其他设备，取消不触发内核', (tester) async {
    var deleted = false;
    await _pump(tester, ItemDetail(item: _item('待抹除'), inTrash: true, onEdit: () {}, onDeleted: () => deleted = true));

    await tester.tap(find.text('彻底删除'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除？'), findsOneWidget);
    expect(find.textContaining('本机永久删除'), findsOneWidget);
    expect(find.textContaining('其他设备'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除？'), findsNothing);
    // 未确认即未删除：onDeleted 不被调用（真实路径还会调用内核，此处无桥）。
    expect(deleted, isFalse);
  });

  testWidgets('列表标题行渲染 headerAction（回收站清空入口）', (tester) async {
    var tapped = false;
    await _pump(
      tester,
      ItemListPane(
        title: '回收站',
        items: [_item('待抹除')],
        selectedId: null,
        query: '',
        searchController: TextEditingController(),
        searchFocus: FocusNode(),
        onQuery: (_) {},
        onSelect: (_) {},
        isTrash: true,
        headerAction: IconButton(
          tooltip: '清空回收站',
          onPressed: () => tapped = true,
          icon: const Icon(Icons.delete_sweep_outlined),
        ),
      ),
    );
    expect(find.byTooltip('清空回收站'), findsOneWidget);
    await tester.tap(find.byTooltip('清空回收站'));
    expect(tapped, isTrue);
  });

  testWidgets('列表没有 headerAction 时不渲染清空入口', (tester) async {
    await _pump(
      tester,
      ItemListPane(
        title: '全部条目',
        items: [_item('在用')],
        selectedId: null,
        query: '',
        searchController: TextEditingController(),
        searchFocus: FocusNode(),
        onQuery: (_) {},
        onSelect: (_) {},
        isTrash: false,
      ),
    );
    expect(find.byTooltip('清空回收站'), findsNothing);
  });
}
