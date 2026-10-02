import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import 'home.dart' show Section, VaultFilter, applyVaultFilter, categoryAncestors;
import 'item_list.dart' show ItemListPane;

/// 条目子列表页的维度（计划书 §2.3：全部条目 / 收藏 / 分组 / 分类 / 标签各有一页）。
enum TaxonomyDimension { tag, category }

/// 某一维度的独立条目子列表页（计划书 §2.3 / §3.6）。
///
/// **筛选规则不在这里实现**：页面只组装一个 [`VaultFilter`] 交给 [`applyVaultFilter`]，
/// 与首页列表走的是同一份规则。否则「标签页里能看到的条目」和「首页筛出来的条目」迟早会对不上。
class TaxonomyListPage extends StatefulWidget {
  const TaxonomyListPage({
    super.key,
    required this.dimension,
    required this.value,
    required this.items,
    required this.onOpenItem,
    this.isTrash = false,
  });

  final TaxonomyDimension dimension;

  /// 标签名或分类路径。
  final String value;

  /// 全部条目；本页自行按维度筛选。
  final List<VaultItem> items;

  /// 点开某条条目（通常是跳到详情）。
  final ValueChanged<VaultItem> onOpenItem;

  final bool isTrash;

  @override
  State<TaxonomyListPage> createState() => _TaxonomyListPageState();
}

class _TaxonomyListPageState extends State<TaxonomyListPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  String _query = '';
  String? _selected;

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  VaultFilter get _filter => VaultFilter(
        query: _query,
        section: widget.isTrash ? Section.trash : Section.all,
        tag: widget.dimension == TaxonomyDimension.tag ? widget.value : null,
        categoryPath: widget.dimension == TaxonomyDimension.category ? widget.value : null,
      );

  String get _title => context.trf(
        widget.dimension == TaxonomyDimension.tag ? AppStrings.subListTagTitle : AppStrings.subListCategoryTitle,
        {'name': widget.value},
      );

  @override
  Widget build(BuildContext context) {
    final visible = applyVaultFilter(widget.items, _filter);
    final ancestors = widget.dimension == TaxonomyDimension.category ? categoryAncestors(widget.value) : const <String>[];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: context.tr(AppStrings.back),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_title, style: context.text.titleMedium),
            Text(
              context.trf(AppStrings.subListCount, {'n': visible.length}),
              style: context.text.labelSmall?.copyWith(color: context.zo.textMuted),
            ),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 分类路径的面包屑：让用户知道自己在这棵树的哪一层。
          if (ancestors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(ancestors.join(' / '), style: context.text.labelSmall?.copyWith(color: context.zo.textMuted)),
            ),
          Expanded(
            child: ItemListPane(
              title: _title,
              items: visible,
              selectedId: _selected,
              query: _query,
              searchController: _search,
              searchFocus: _focus,
              onQuery: (v) => setState(() => _query = v),
              onSelect: (id) {
                setState(() => _selected = id);
                final item = visible.where((i) => i.id == id).firstOrNull;
                if (item != null) widget.onOpenItem(item);
              },
              isTrash: widget.isTrash,
              compact: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// 以路由形式打开子列表页。
Future<void> openTaxonomyList(
  BuildContext context, {
  required TaxonomyDimension dimension,
  required String value,
  required List<VaultItem> items,
  required ValueChanged<VaultItem> onOpenItem,
  bool isTrash = false,
}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => TaxonomyListPage(
        dimension: dimension,
        value: value,
        items: items,
        onOpenItem: onOpenItem,
        isTrash: isTrash,
      ),
    ));
