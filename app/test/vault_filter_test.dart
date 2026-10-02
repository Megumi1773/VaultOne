import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/home.dart';

VaultItem _item(
  String id,
  String title, {
  ItemKind kind = ItemKind.login,
  bool favorite = false,
  List<String> tags = const [],
  String? category,
  String? username,
}) =>
    VaultItem(
      id: id,
      vaultId: 'v',
      revision: 1,
      data: ItemData(
        kind: kind,
        title: title,
        favorite: favorite,
        tags: tags,
        category: category,
        username: username,
      ),
    );

void main() {
  final bank = _item('1', '银行', tags: ['金融', '工作'], category: '金融');
  final github = _item('2', 'GitHub', tags: ['工作'], category: '开发', username: 'alice');
  final wifi = _item('3', '家里 Wi-Fi', kind: ItemKind.note, category: '个人');
  final all = [bank, github, wifi];

  List<String> titles(List<VaultItem> items) => [for (final i in items) i.data.title];

  test('无筛选时按收藏优先、标题排序', () {
    final fav = _item('4', 'AAA', favorite: true);
    final out = applyVaultFilter([...all, fav], const VaultFilter());
    expect(titles(out).first, 'AAA', reason: '收藏项应排在最前');
    expect(titles(out).length, 4);
  });

  test('标签筛选忽略大小写，且与分区、搜索词叠加', () {
    expect(titles(applyVaultFilter(all, const VaultFilter(tag: '工作'))), ['GitHub', '银行']);

    // 大小写不敏感：内核规范化保留首次写法，筛选不应因大小写不同而漏掉。
    // 注意「工作」与「work」是两个不同标签，不应互相命中。
    final upper = _item('5', '大写', tags: ['Work']);
    expect(titles(applyVaultFilter([...all, upper], const VaultFilter(tag: 'work'))), ['大写']);
    expect(titles(applyVaultFilter([...all, upper], const VaultFilter(tag: 'WORK'))), ['大写']);

    // 叠加搜索词：标签命中但搜索词不命中时为空。
    expect(applyVaultFilter(all, const VaultFilter(tag: '工作', query: 'github')), hasLength(1));
    expect(applyVaultFilter(all, const VaultFilter(tag: '工作', query: '不存在')), isEmpty);
  });

  test('分类筛选精确匹配，并与类型分区叠加', () {
    expect(titles(applyVaultFilter(all, const VaultFilter(category: '开发'))), ['GitHub']);
    expect(applyVaultFilter(all, const VaultFilter(category: '开发不存在')), isEmpty);

    // 类型分区 + 分类：笔记分区下没有「开发」分类的条目。
    expect(
      applyVaultFilter(all, const VaultFilter(section: Section.note, category: '开发')),
      isEmpty,
    );
    expect(
      titles(applyVaultFilter(all, const VaultFilter(section: Section.note, category: '个人'))),
      ['家里 Wi-Fi'],
    );
  });

  test('标签与分类同时给出时是与关系', () {
    expect(titles(applyVaultFilter(all, const VaultFilter(tag: '工作', category: '开发'))), ['GitHub']);
    expect(applyVaultFilter(all, const VaultFilter(tag: '工作', category: '个人')), isEmpty);
  });

  test('收藏分区只保留收藏项', () {
    final out = applyVaultFilter(all, const VaultFilter(section: Section.favorites));
    expect(out, isEmpty, reason: '样本里没有收藏项');
    final fav = _item('4', 'AAA', favorite: true);
    expect(titles(applyVaultFilter([...all, fav], const VaultFilter(section: Section.favorites))), ['AAA']);
  });

  test('taxonomyOf 去重并按不区分大小写排序', () {
    final tax = taxonomyOf([...all, _item('5', '重复', tags: ['工作', 'Zed'], category: '金融')]);
    expect(tax.tags, ['Zed', '工作', '金融'], reason: '工作应去重，排序不区分大小写');
    expect(tax.categories, ['个人', '开发', '金融']);
  });

  test('taxonomyOf 对无标签无分类的条目返回空', () {
    final tax = taxonomyOf([_item('9', '裸条目')]);
    expect(tax.tags, isEmpty);
    expect(tax.categories, isEmpty);
  });

  test('isFiltered 只在标签或分类生效时为真，搜索词不算', () {
    expect(const VaultFilter(query: 'x').isFiltered, isFalse);
    expect(const VaultFilter(tag: 't').isFiltered, isTrue);
    expect(const VaultFilter(category: 'c').isFiltered, isTrue);
  });
}
