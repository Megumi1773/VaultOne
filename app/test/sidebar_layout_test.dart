import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/ui/screens/home.dart' show Section;
import 'package:vaultone/src/ui/screens/sidebar_layout.dart';

void main() {
  test('默认布局与侧栏原有顺序一致，且全部可见', () {
    final layout = defaultSidebarLayout();
    expect([for (final e in layout) e.section], [
      Section.all,
      Section.favorites,
      Section.login,
      Section.card,
      Section.note,
      Section.identity,
      Section.generator,
      Section.security,
      Section.trash,
    ]);
    expect(layout.every((e) => e.visible), isTrue);
    // `settings` 固定在侧栏底部，不参与排序。
    expect(layout.any((e) => e.section == Section.settings), isFalse);
  });

  test('空值与损坏的 JSON 都回退默认布局', () {
    for (final raw in [null, '', '   ', '不是 JSON', '{}', '[1,2,3]']) {
      expect(resolveSidebarLayout(raw), defaultSidebarLayout(), reason: '「$raw」应回退默认');
    }
  });

  test('解析顺序与显隐，并往返编码', () {
    const raw = '[{"id":"trash","visible":true},{"id":"all","visible":false},{"id":"favorites"}]';
    final layout = resolveSidebarLayout(raw);
    expect(layout.take(3).map((e) => e.section), [Section.trash, Section.all, Section.favorites]);
    expect(layout.first.visible, isTrue);
    expect(layout[1].visible, isFalse);
    expect(layout[2].visible, isTrue, reason: '缺 visible 视为可见');
    // 未列出的分区补到末尾，否则升级后新加的分区会直接消失。
    expect(layout.map((e) => e.section).toSet().length, defaultSidebarLayout().length);
    expect(resolveSidebarLayout(encodeSidebarLayout(layout)), layout, reason: '编码后应能原样读回');
  });

  test('未知与重复 id 被丢弃，不产生无法渲染的条目', () {
    const raw = '[{"id":"nope"},{"id":"all"},{"id":"all"},{"id":"settings"}]';
    final layout = resolveSidebarLayout(raw);
    expect(layout.map((e) => e.section).toList(), defaultSidebarLayout().map((e) => e.section).toList());
    expect(layout.any((e) => e.section == Section.settings), isFalse, reason: 'settings 固定底部，不参与排序');
  });

  test('缺项按默认顺序补到末尾，已有项保持用户顺序', () {
    const raw = '[{"id":"security"},{"id":"generator"}]';
    final layout = resolveSidebarLayout(raw);
    expect(layout.take(2).map((e) => e.section), [Section.security, Section.generator]);
    expect(layout.skip(2).map((e) => e.section), [
      Section.all,
      Section.favorites,
      Section.login,
      Section.card,
      Section.note,
      Section.identity,
      Section.trash,
    ]);
  });

  test('分组跟着条目走，不会出现「标题下面没有条目」', () {
    final layout = resolveSidebarLayout(null);
    final generator = layout.firstWhere((e) => e.section == Section.generator);
    expect(generator.group, 'tools');
    expect(layout.firstWhere((e) => e.section == Section.login).group, 'categories');
    expect(layout.firstWhere((e) => e.section == Section.all).group, '', reason: '置顶分区没有分组标题');
  });

  test('上移下移只在范围内生效，越界原样返回', () {
    final layout = defaultSidebarLayout();
    final moved = moveSidebarEntry(layout, 2, -1);
    expect(moved[1].section, Section.login);
    expect(moved[2].section, Section.favorites);

    expect(moveSidebarEntry(layout, 0, -1), layout, reason: '首项上移无效');
    expect(moveSidebarEntry(layout, layout.length - 1, 1), layout, reason: '末项下移无效');
    expect(moveSidebarEntry(layout, -1, 1), layout);
    expect(moveSidebarEntry(layout, 99, 1), layout);
    expect(layout[0].section, Section.all, reason: '原列表不应被就地修改');
  });

  test('不允许把最后一项可见也隐藏掉', () {
    final layout = defaultSidebarLayout();
    // 只剩一项可见时，那一项不能被隐藏，否则侧栏一片空白且没有恢复入口。
    final onlyOne = [
      for (final e in layout) e.copyWith(visible: e.section == Section.all),
    ];
    expect(canHide(onlyOne, onlyOne.first), isFalse);

    final twoVisible = [
      for (final e in layout) e.copyWith(visible: e.section == Section.all || e.section == Section.trash),
    ];
    expect(canHide(twoVisible, twoVisible.first), isTrue, reason: '还有其他可见项时可以隐藏');
    expect(canHide(layout, layout.first), isTrue);
    // 已经隐藏的项再「隐藏」是空操作，不算受限。
    expect(canHide(onlyOne, onlyOne.last), isTrue);
  });
}
