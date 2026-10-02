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
    expect(titles(applyVaultFilter(all, const VaultFilter(categoryPath: '开发'))), ['GitHub']);
    expect(applyVaultFilter(all, const VaultFilter(categoryPath: '开发不存在')), isEmpty);

    // 类型分区 + 分类：笔记分区下没有「开发」分类的条目。
    expect(
      applyVaultFilter(all, const VaultFilter(section: Section.note, categoryPath: '开发')),
      isEmpty,
    );
    expect(
      titles(applyVaultFilter(all, const VaultFilter(section: Section.note, categoryPath: '个人'))),
      ['家里 Wi-Fi'],
    );
  });

  // 分类是层级路径（`工作/生产/服务器`），选中父节点要连同后代一起显示，
  // 否则用户点「工作」看不到任何条目会以为数据丢了。
  test('分类筛选含后代，且只匹配完整段名', () {
    final tree = [
      _item('10', '服务器', category: '工作/生产/服务器'),
      _item('11', '数据库', category: '工作/生产/数据库'),
      _item('12', '生产总览', category: '工作/生产'),
      _item('13', '私事', category: '工作/个人'),
      _item('14', '无关', category: '工作台'), // 前缀相似但段名不同
    ];

    // 无收藏项时按标题排序，因此这里的顺序是标题序而非层级序。
    expect(
      titles(applyVaultFilter(tree, const VaultFilter(categoryPath: '工作'))),
      ['数据库', '服务器', '生产总览', '私事'],
      reason: '选中祖先应包含全部后代',
    );
    expect(
      titles(applyVaultFilter(tree, const VaultFilter(categoryPath: '工作/生产'))),
      ['数据库', '服务器', '生产总览'],
    );
    expect(
      titles(applyVaultFilter(tree, const VaultFilter(categoryPath: '工作/生产/服务器'))),
      ['服务器'],
    );
    // `工作台` 与 `工作` 是不同的段名，不应被 `工作` 命中。
    expect(
      titles(applyVaultFilter(tree, const VaultFilter(categoryPath: '工作'))),
      isNot(contains('无关')),
    );
  });

  test('categoryMatches 的规则：自身或后代，段名必须完整', () {
    expect(categoryMatches('工作/生产', '工作'), isTrue);
    expect(categoryMatches('工作', '工作'), isTrue);
    expect(categoryMatches('工作台', '工作'), isFalse, reason: '段名必须完整匹配');
    expect(categoryMatches('工作/生产', '工作/生'), isFalse);
    expect(categoryMatches(null, '工作'), isFalse);
  });

  test('标签与分类同时给出时是与关系', () {
    expect(titles(applyVaultFilter(all, const VaultFilter(tag: '工作', categoryPath: '开发'))), ['GitHub']);
    expect(applyVaultFilter(all, const VaultFilter(tag: '工作', categoryPath: '个人')), isEmpty);
  });

  test('收藏分区只保留收藏项', () {
    final out = applyVaultFilter(all, const VaultFilter(section: Section.favorites));
    expect(out, isEmpty, reason: '样本里没有收藏项');
    final fav = _item('4', 'AAA', favorite: true);
    expect(titles(applyVaultFilter([...all, fav], const VaultFilter(section: Section.favorites))), ['AAA']);
  });

  test('tagsOf 去重并按不区分大小写排序', () {
    final tags = tagsOf([...all, _item('5', '重复', tags: ['工作', 'Zed'], category: '金融')]);
    expect(tags, ['Zed', '工作', '金融'], reason: '工作应去重，排序不区分大小写');
  });

  test('tagsOf 对无标签的条目返回空', () {
    expect(tagsOf([_item('9', '裸条目')]), isEmpty);
  });

  test('isFiltered 只在标签或分类生效时为真，搜索词不算', () {
    expect(const VaultFilter(query: 'x').isFiltered, isFalse);
    expect(const VaultFilter(tag: 't').isFiltered, isTrue);
    expect(const VaultFilter(categoryPath: 'c').isFiltered, isTrue);
  });

  test('CategoryNode 按深度优先展开，层级用于缩进', () {
    const tree = CategoryNode(
      name: '工作',
      path: '工作',
      direct: 1,
      total: 3,
      children: [
        CategoryNode(
          name: '生产',
          path: '工作/生产',
          direct: 1,
          total: 2,
          children: [CategoryNode(name: '服务器', path: '工作/生产/服务器', direct: 1, total: 1)],
        ),
      ],
    );
    final flat = tree.flatten();
    expect([for (final e in flat) (e.node.name, e.depth)], [
      ('工作', 0),
      ('生产', 1),
      ('服务器', 2),
    ]);
  });

  test('CategoryNode.fromJson 容错：缺字段按空值与 0 处理', () {
    final node = CategoryNode.fromJson(const {'path': '工作'});
    expect(node.name, '');
    expect(node.direct, 0);
    expect(node.total, 0);
    expect(node.children, isEmpty);
  });
}
