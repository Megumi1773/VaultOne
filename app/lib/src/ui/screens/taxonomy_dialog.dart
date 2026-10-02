import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
import 'item_detail.dart' show confirmDialog;

/// 标签与分类管理（计划书 §3.6）。
///
/// 改写的规则**全部在内核**（`Vault::rename_tag` / `delete_tag` / `rename_category` /
/// `clear_category`）：界面只收集目标名称、确认破坏性操作、展示受影响条目数。
/// 尤其是「改成分类的子分类会成环」这类判断，绝不能只在界面上做一次校验就算数。
///
/// 统计口径：标签计数由传入的条目现算；分类计数取内核给的分类树 `total`（含后代），
/// 与侧栏显示的数字同源。
class TaxonomyDialog extends StatefulWidget {
  const TaxonomyDialog({
    super.key,
    required this.items,
    required this.categoryTree,
    required this.renameTag,
    required this.deleteTag,
    required this.renameCategory,
    required this.clearCategory,
  });

  final List<VaultItem> items;
  final List<CategoryNode> categoryTree;
  final Future<int> Function(String from, String to) renameTag;
  final Future<int> Function(String tag) deleteTag;
  final Future<int> Function(String from, String to) renameCategory;
  final Future<int> Function(String path) clearCategory;

  @override
  State<TaxonomyDialog> createState() => _TaxonomyDialogState();
}

class _TaxonomyDialogState extends State<TaxonomyDialog> {
  bool _busy = false;

  /// 标签计数：按出现次数降序、同次数按名称排序，方便一眼找到大标签。
  List<(String, int)> get _tags {
    final counts = <String, int>{};
    final spelling = <String, String>{};
    for (final item in widget.items) {
      for (final tag in item.data.tags) {
        final key = tag.toLowerCase();
        counts[key] = (counts[key] ?? 0) + 1;
        spelling.putIfAbsent(key, () => tag);
      }
    }
    final list = [for (final e in counts.entries) (spelling[e.key]!, e.value)];
    list.sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
    return list;
  }

  /// 分类展开成扁平列表，保留层级顺序（父在子前），便于阅读。
  List<(CategoryNode, int)> _flatten(List<CategoryNode> nodes, int depth) => [
        for (final node in nodes) ...[
          (node, depth),
          ..._flatten(node.children, depth + 1),
        ],
      ];

  Future<void> _run(Future<int> Function() action) async {
    setState(() => _busy = true);
    try {
      final n = await action();
      if (!mounted) return;
      showZoMessage(context, context.trf(AppStrings.taxonomyAffected, {'n': n}));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _askRename({required bool isTag, required String current, required int count}) async {
    final next = await _askName(
      context,
      title: context.tr(isTag ? AppStrings.taxonomyRenameTagTitle : AppStrings.taxonomyRenameCategoryTitle),
      initial: current,
      hint: context.tr(isTag ? AppStrings.taxonomyTagHint : AppStrings.taxonomyCategoryHint),
    );
    if (next == null || next == current) return;
    await _run(() => isTag ? widget.renameTag(current, next) : widget.renameCategory(current, next));
  }

  Future<void> _askDeleteTag(String tag, int count) async {
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.delete),
      body: context.trf(AppStrings.taxonomyDeleteTagBody, {'name': tag, 'n': count}),
      confirm: context.tr(AppStrings.delete),
    );
    if (ok != true) return;
    await _run(() => widget.deleteTag(tag));
  }

  Future<void> _askClearCategory(CategoryNode node) async {
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.taxonomyClearCategoryTitle),
      body: context.trf(AppStrings.taxonomyClearBody, {'name': node.path, 'n': node.total}),
      confirm: context.tr(AppStrings.emptyTrashConfirmAction),
    );
    if (ok != true) return;
    await _run(() => widget.clearCategory(node.path));
  }

  @override
  Widget build(BuildContext context) {
    final categories = _flatten(widget.categoryTree, 0);
    final tags = _tags;
    return AlertDialog(
      title: Text(context.tr(AppStrings.taxonomyManage)),
      content: SizedBox(
        width: 560,
        height: 420,
        child: DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.tr(AppStrings.taxonomyManageSubtitle), style: context.text.bodySmall),
              const SizedBox(height: 8),
              const TabBar(tabs: [_TabLabel(AppStrings.tagLabel), _TabLabel(AppStrings.sidebarCategories)]),
              Expanded(
                child: TabBarView(
                  children: [
                    _list(
                      empty: AppStrings.taxonomyNoTags,
                      children: [
                        for (final (tag, count) in tags)
                          _row(
                            label: tag,
                            count: count,
                            removeTooltip: context.tr(AppStrings.delete),
                            onRename: () => _askRename(isTag: true, current: tag, count: count),
                            onRemove: () => _askDeleteTag(tag, count),
                          ),
                      ],
                    ),
                    _list(
                      empty: AppStrings.taxonomyNoCategories,
                      children: [
                        for (final (node, depth) in categories)
                          _row(
                            label: node.path,
                            count: node.total,
                            indent: depth,
                            removeTooltip: context.tr(AppStrings.emptyTrashConfirmAction),
                            onRename: () => _askRename(isTag: false, current: node.path, count: node.total),
                            onRemove: () => _askClearCategory(node),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr(AppStrings.close)))],
    );
  }

  Widget _list({required String empty, required List<Widget> children}) {
    if (children.isEmpty) {
      return Center(child: Text(context.tr(empty), style: context.text.bodySmall));
    }
    return ListView(children: children);
  }

  Widget _row({
    required String label,
    required int count,
    required String removeTooltip,
    required VoidCallback onRename,
    required VoidCallback onRemove,
    int indent = 0,
  }) {
    final c = context.zo;
    return Padding(
      padding: EdgeInsets.only(left: indent * 16.0),
      child: Row(children: [
        Expanded(child: Text(label, style: context.text.bodyMedium, overflow: TextOverflow.ellipsis)),
        Text('$count', style: context.text.labelSmall?.copyWith(color: c.textMuted)),
        const SizedBox(width: 8),
        ZoIconButton(
          icon: Icons.drive_file_rename_outline_rounded,
          tooltip: context.tr(AppStrings.taxonomyRename),
          onPressed: _busy ? null : onRename,
        ),
        ZoIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: removeTooltip,
          onPressed: _busy ? null : onRemove,
        ),
      ]),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Tab(height: 36, child: Text(context.tr(text), style: context.text.bodyMedium));
}

/// 输入新名称。取消返回 null。
Future<String?> _askName(
  BuildContext context, {
  required String title,
  required String initial,
  required String hint,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _NamePrompt(title: title, initial: initial, hint: hint),
    );

/// 控制器由这个 StatefulWidget 自己持有并在 `dispose` 里释放。
///
/// 不能在 `showDialog` 返回后就 `controller.dispose()`：那时退场动画还在跑，`TextField`
/// 仍持有控制器，会抛「A TextEditingController was used after being disposed」。
class _NamePrompt extends StatefulWidget {
  const _NamePrompt({required this.title, required this.initial, required this.hint});

  final String title;
  final String initial;
  final String hint;

  @override
  State<_NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<_NamePrompt> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    // 空名称直接当作取消：改名成空是无意义的，内核也会拒绝。
    Navigator.pop(context, value.isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(labelText: context.tr(AppStrings.taxonomyNewName)),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            Text(widget.hint, style: context.text.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr(AppStrings.cancel))),
          FilledButton(onPressed: _submit, child: Text(context.tr(AppStrings.save))),
        ],
      );
}
