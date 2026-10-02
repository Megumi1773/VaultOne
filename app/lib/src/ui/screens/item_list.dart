import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/controls.dart';

class ItemListPane extends StatelessWidget {
  const ItemListPane({
    super.key,
    required this.title,
    required this.items,
    required this.selectedId,
    required this.query,
    required this.searchController,
    required this.searchFocus,
    required this.onQuery,
    required this.onSelect,
    required this.isTrash,
    this.onNew,
    this.compact = false,
    this.filterBar,
    this.headerAction,
  });

  final String title;
  final List<VaultItem> items;
  final String? selectedId;
  final String query;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onSelect;
  final void Function([ItemKind? kind])? onNew;
  final bool isTrash;

  /// 手机端：省去大标题行与键盘提示，为列表留出空间；新建走悬浮按钮。
  final bool compact;

  /// 手机端：搜索框下方的横向过滤条（分类 / 收藏 / 回收站）。
  final Widget? filterBar;

  /// 标题行右侧的附加操作（如回收站的「清空」）。仅在非 compact 布局显示。
  final Widget? headerAction;

  void _move(int delta) {
    if (items.isEmpty) return;
    final idx = items.indexWhere((i) => i.id == selectedId);
    final next = (idx < 0 ? 0 : idx + delta).clamp(0, items.length - 1);
    onSelect(items[next].id);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return ColoredBox(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 12, 12),
              child: Row(
                children: [
                  Text(title, style: context.text.headlineSmall),
                  const SizedBox(width: 8),
                  Text('${items.length}', style: monoStyle(context, size: 12, color: c.textFaint)),
                  const Spacer(),
                  ?headerAction,
                  if (onNew != null)
                    PopupMenuButton<ItemKind>(
                      tooltip: context.tr(AppStrings.newItem),
                      position: PopupMenuPosition.under,
                      onSelected: (k) => onNew!(k),
                      itemBuilder: (_) => [
                        for (final k in ItemKind.values)
                          PopupMenuItem(
                            value: k,
                            height: 38,
                            child: Row(children: [Icon(k.icon, size: 16, color: c.textMuted), const SizedBox(width: 10), Text(k.label)]),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(Icons.add_rounded, size: 18, color: c.textMuted),
                      ),
                    ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(14, compact ? 12 : 0, 14, compact ? 8 : 10),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
                const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
                const SingleActivator(LogicalKeyboardKey.escape): () {
                  searchController.clear();
                  onQuery('');
                },
              },
              child: ZoTextField(
                controller: searchController,
                focusNode: searchFocus,
                hint: context.tr(AppStrings.searchItemsHint),
                prefixIcon: Icons.search_rounded,
                dense: true,
                onChanged: onQuery,
                onSubmitted: (_) {
                  if (items.isNotEmpty) onSelect(items.first.id);
                },
                trailing: [
                  if (query.isNotEmpty)
                    ZoIconButton(
                      icon: Icons.close_rounded,
                      tooltip: context.tr(AppStrings.clearSearch),
                      size: 26,
                      onPressed: () {
                        searchController.clear();
                        onQuery('');
                      },
                    )
                  else if (!compact)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text('Ctrl F', style: monoStyle(context, size: 10.5, color: c.textFaint)),
                    ),
                ],
              ),
            ),
          ),
          if (filterBar != null) ...[
            filterBar!,
            const SizedBox(height: 10),
          ],
          Expanded(
            child: items.isEmpty
                ? _EmptyList(query: query, isTrash: isTrash, compact: compact)
                : ListView.builder(
                    padding: EdgeInsets.fromLTRB(8, 2, 8, compact ? 88 : 16),
                    itemCount: items.length,
                    itemExtent: 60,
                    itemBuilder: (context, i) => _ItemTile(
                      item: items[i],
                      selected: items[i].id == selectedId,
                      onTap: () => onSelect(items[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.selected, required this.onTap});

  final VaultItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final d = item.data;
    return Hover(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: Zo.fast,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? c.surfaceRaised : (hover ? c.surface : Colors.transparent),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: selected ? c.borderStrong : Colors.transparent),
        ),
        child: Row(
          children: [
            Monogram(title: d.title, size: 34, icon: d.kind == ItemKind.login ? null : d.kind.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          d.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.titleMedium?.copyWith(fontSize: 13.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                        ),
                      ),
                      if (d.favorite) ...[const SizedBox(width: 6), Icon(Icons.star_rounded, size: 13, color: c.accent)],
                      if (d.totp != null) ...[const SizedBox(width: 6), Icon(Icons.timer_outlined, size: 12, color: c.textFaint)],
                    ],
                  ),
                  if (d.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(d.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  const _EmptyList({required this.query, required this.isTrash, this.compact = false});

  final String query;
  final bool isTrash;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final (icon, title, body) = query.isNotEmpty
        ? (Icons.search_off_rounded, context.trf(AppStrings.emptySearchTitle, {'query': query}), context.tr(AppStrings.emptySearchBody))
        : isTrash
            ? (Icons.delete_outline_rounded, context.tr(AppStrings.emptyTrashTitle), context.tr(AppStrings.emptyTrashBody))
            : (Icons.inventory_2_outlined, context.tr(AppStrings.emptyVaultTitle), compact ? context.tr(AppStrings.emptyVaultBodyCompact) : context.tr(AppStrings.emptyVaultBody));
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 28, color: c.textFaint),
          const SizedBox(height: 14),
          Text(title, style: context.text.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(body, style: context.text.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
