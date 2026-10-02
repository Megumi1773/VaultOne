import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/ffi.dart';
import '../../l10n/strings.dart';
import '../../core/models.dart';
import '../../state/app_state.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
import 'generator_page.dart';
import 'item_detail.dart';
import 'item_editor.dart';
import 'item_list.dart';
import 'security_page.dart';
import 'settings_page.dart';

enum Section {
  all(AppStrings.sectionAll, Icons.grid_view_rounded, AppStrings.sectionAllShort),
  favorites(AppStrings.sectionFavorites, Icons.star_outline_rounded),
  login(AppStrings.sectionLogin, Icons.key_rounded),
  card(AppStrings.sectionCard, Icons.credit_card_rounded),
  note(AppStrings.sectionNote, Icons.sticky_note_2_outlined, AppStrings.sectionNoteShort),
  identity(AppStrings.sectionIdentity, Icons.badge_outlined, AppStrings.sectionIdentityShort),
  generator(AppStrings.sectionGenerator, Icons.auto_awesome_outlined),
  security(AppStrings.sectionSecurityCenter, Icons.shield_outlined),
  trash(AppStrings.sectionTrash, Icons.delete_outline_rounded),
  settings(AppStrings.settings, Icons.tune_rounded);

  const Section(this.label, this.icon, [String? short]) : short = short ?? label;

  final String label;
  final IconData icon;

  /// 窄屏过滤条用的短标签。
  final String short;

  bool get isVault => index <= Section.identity.index || this == Section.trash;

  ItemKind? get kind => switch (this) {
        Section.login => ItemKind.login,
        Section.card => ItemKind.card,
        Section.note => ItemKind.note,
        Section.identity => ItemKind.identity,
        _ => null,
      };

  /// 界面语言下的分区名。枚举上的 `label` / `short` 是简体中文原文，也是翻译回退值。
  String title(BuildContext context) => context.tr(_labelKeys[this]!);

  /// 界面语言下的窄屏短标签。
  String shortTitle(BuildContext context) => context.tr(_shortKeys[this] ?? _labelKeys[this]!);

  static const _labelKeys = <Section, String>{
    Section.all: AppStrings.sectionAll,
    Section.favorites: AppStrings.sectionFavorites,
    Section.login: AppStrings.sectionLogin,
    Section.card: AppStrings.sectionCard,
    Section.note: AppStrings.sectionNote,
    Section.identity: AppStrings.sectionIdentity,
    Section.generator: AppStrings.sectionGenerator,
    Section.security: AppStrings.sectionSecurityCenter,
    Section.trash: AppStrings.sectionTrash,
    Section.settings: AppStrings.settings,
  };

  static const _shortKeys = <Section, String>{
    Section.all: AppStrings.sectionAllShort,
    Section.note: AppStrings.sectionNoteShort,
    Section.identity: AppStrings.sectionIdentityShort,
  };
}

/// 手机端底部导航。桌面端的侧栏分区不照搬到窄屏：只保留四个一级入口，
/// 分类 / 收藏 / 回收站下沉为保险库页内的横向过滤条。
enum _MobileTab {
  vault(AppStrings.tabVault, Icons.inventory_2_outlined, Icons.inventory_2_rounded),
  generator(AppStrings.tabGenerator, Icons.auto_awesome_outlined, Icons.auto_awesome_rounded),
  security(AppStrings.tabSecurity, Icons.shield_outlined, Icons.shield_rounded),
  settings(AppStrings.settings, Icons.tune_outlined, Icons.tune_rounded);

  const _MobileTab(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// 界面语言下的底部导航标签。
  String title(BuildContext context) => context.tr(_labelKeys[this]!);

  static const _labelKeys = <_MobileTab, String>{
    _MobileTab.vault: AppStrings.tabVault,
    _MobileTab.generator: AppStrings.tabGenerator,
    _MobileTab.security: AppStrings.tabSecurity,
    _MobileTab.settings: AppStrings.settings,
  };
}

/// 编辑目标：新建某类条目，或编辑已有条目。
class EditTarget {
  const EditTarget.create(this.kind) : itemId = null;
  const EditTarget.edit(this.itemId, this.kind);

  final String? itemId;
  final ItemKind kind;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// 列表筛选条件。抽成值对象是为了让筛选逻辑成为**可单测的纯函数**：
/// 之前它埋在 `_HomeScreenState` 的私有方法里，只有启动真实保险库才能验证。
class VaultFilter {
  const VaultFilter({
    this.query = '',
    this.section = Section.all,
    this.tag,
    this.category,
  });

  final String query;
  final Section section;

  /// 标签筛选；大小写不敏感比较，与内核 `normalize_tags` 的去重口径一致。
  final String? tag;

  /// 分类筛选；精确匹配（分类名是用户自由输入，不做大小写折叠）。
  final String? category;

  bool get isFiltered => tag != null || category != null;

  /// 分区、类型、收藏、标签、分类与搜索词全部为「与」关系；顺序即短路顺序。
  bool matches(VaultItem item) {
    final kind = section.kind;
    if (kind != null && item.data.kind != kind) return false;
    if (section == Section.favorites && !item.data.favorite) return false;
    final t = tag;
    if (t != null && !item.data.tags.any((x) => x.toLowerCase() == t.toLowerCase())) return false;
    final c = category;
    if (c != null && item.data.category != c) return false;
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty && !item.data.searchText.contains(q)) return false;
    return true;
  }
}

/// 按筛选条件挑选并排序：收藏优先（回收站除外），其余按标题不区分大小写排序。
List<VaultItem> applyVaultFilter(Iterable<VaultItem> items, VaultFilter filter) {
  final out = items.where(filter.matches).toList();
  out.sort((a, b) {
    if (a.data.favorite != b.data.favorite && filter.section != Section.trash) {
      return a.data.favorite ? -1 : 1;
    }
    return a.data.title.toLowerCase().compareTo(b.data.title.toLowerCase());
  });
  return out;
}

/// 一组条目里出现过的标签与分类（各自去重并排序），用于生成筛选菜单。
({List<String> tags, List<String> categories}) taxonomyOf(Iterable<VaultItem> items) {
  final tags = <String>{};
  final categories = <String>{};
  for (final i in items) {
    tags.addAll(i.data.tags);
    final c = i.data.category;
    if (c != null) categories.add(c);
  }
  int byLower(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  return (
    tags: tags.toList()..sort(byLower),
    categories: categories.toList()..sort(byLower),
  );
}

class _HomeScreenState extends State<HomeScreen> {
  Section _section = Section.all;
  String _query = '';
  String? _selectedId;
  EditTarget? _editing;
  final _searchFocus = FocusNode();
  final _search = TextEditingController();
  AppState? _state;

  /// 标签 / 分类筛选（计划书 §3.6）。null 表示不筛选；两者可叠加，与搜索词也是与关系。
  String? _tagFilter;
  String? _categoryFilter;

  /// 手机端：记住离开保险库前的过滤条件，切回该 Tab 时恢复。
  Section _vaultSection = Section.all;

  _MobileTab get _tab => switch (_section) {
        Section.generator => _MobileTab.generator,
        Section.security => _MobileTab.security,
        Section.settings => _MobileTab.settings,
        _ => _MobileTab.vault,
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 全局快捷键 / 托盘「快速搜索」
    final s = AppScope.read(context);
    if (!identical(s, _state)) {
      _state?.quickSearchRequests.removeListener(_focusSearch);
      _state = s..quickSearchRequests.addListener(_focusSearch);
    }
  }

  void _focusSearch() {
    if (!_section.isVault) _go(Section.all);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
    });
  }

  @override
  void dispose() {
    _state?.quickSearchRequests.removeListener(_focusSearch);
    _searchFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  List<VaultItem> _visible(List<VaultItem> items, List<VaultItem> trash) {
    final source = _section == Section.trash ? trash : items;
    return applyVaultFilter(
      source,
      VaultFilter(query: _query, section: _section, tag: _tagFilter, category: _categoryFilter),
    );
  }

  /// 当前分区里出现过的标签与分类，用于筛选菜单。
  ({List<String> tags, List<String> categories}) _taxonomyOf(List<VaultItem> items, List<VaultItem> trash) =>
      taxonomyOf(_section == Section.trash ? trash : items);

  /// 标签 / 分类筛选条。只在该分区确有标签或分类时出现，避免空菜单占位。
  Widget? _taxonomyBar(List<VaultItem> visible, List<VaultItem> trash) {
    final tax = _taxonomyOf(visible, trash);
    if (tax.tags.isEmpty && tax.categories.isEmpty) return null;
    final c = context.zo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (tax.tags.isNotEmpty)
            PopupMenuButton<String?>(
              tooltip: context.tr(AppStrings.filterByTagTitle),
              position: PopupMenuPosition.under,
              onSelected: (v) => setState(() => _tagFilter = v),
              itemBuilder: (_) => [
                PopupMenuItem(value: null, height: 38, child: Text(context.tr(AppStrings.allTags))),
                for (final t in tax.tags) PopupMenuItem(value: t, height: 38, child: Text(t)),
              ],
              child: ZoTag(
                _tagFilter ?? context.tr(AppStrings.tagLabel),
                icon: Icons.local_offer_outlined,
                color: _tagFilter == null ? c.textMuted : c.accent,
              ),
            ),
          if (tax.categories.isNotEmpty)
            PopupMenuButton<String?>(
              tooltip: context.tr(AppStrings.filterByCategoryTitle),
              position: PopupMenuPosition.under,
              onSelected: (v) => setState(() => _categoryFilter = v),
              itemBuilder: (_) => [
                PopupMenuItem(value: null, height: 38, child: Text(context.tr(AppStrings.sidebarCategories))),
                for (final t in tax.categories) PopupMenuItem(value: t, height: 38, child: Text(t)),
              ],
              child: ZoTag(
                _categoryFilter ?? context.tr(AppStrings.sidebarCategories),
                icon: Icons.folder_outlined,
                color: _categoryFilter == null ? c.textMuted : c.accent,
              ),
            ),
          if (_tagFilter != null || _categoryFilter != null)
            ZoIconButton(
              icon: Icons.filter_alt_off_outlined,
              tooltip: context.tr(AppStrings.clearFilter),
              size: 24,
              onPressed: () => setState(() {
                _tagFilter = null;
                _categoryFilter = null;
              }),
            ),
        ],
      ),
    );
  }

  void _go(Section s) => setState(() {
        // 回收站是临时去处，不作为「保险库」Tab 的恢复目标。
        if (s.isVault && s != Section.trash) _vaultSection = s;
        _section = s;
        _editing = null;
        // 换分区时清掉标签/分类筛选：旧筛选值在新分区里可能根本不存在，
        // 留着会让列表看起来「空了」而用户不知道原因。
        _tagFilter = null;
        _categoryFilter = null;
        if (!s.isVault) _selectedId = null;
      });

  void _selectTab(_MobileTab tab) {
    switch (tab) {
      case _MobileTab.vault:
        _go(_vaultSection);
      case _MobileTab.generator:
        _go(Section.generator);
      case _MobileTab.security:
        _go(Section.security);
      case _MobileTab.settings:
        _go(Section.settings);
    }
  }

  void _newItem([ItemKind? kind]) => setState(() {
        if (!_section.isVault || _section == Section.trash) _section = Section.all;
        _editing = EditTarget.create(kind ?? _section.kind ?? ItemKind.login);
      });

  /// 清空回收站：已同步条目抹除，未同步的保留并如实告知。
  Future<void> _emptyTrash() async {
    final state = AppScope.read(context);
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.emptyTrashConfirmTitle),
      body: context.tr(AppStrings.emptyTrashConfirmBody),
      confirm: context.tr(AppStrings.emptyTrashConfirmAction),
      danger: true,
    );
    if (ok != true || !mounted) return;
    try {
      final r = await state.emptyTrash();
      if (!mounted) return;
      final keptNote = r.kept == 0 ? '' : context.trf(AppStrings.emptyTrashKeptNote, {'kept': r.kept});
      final message = r.purged == 0
          ? context.trf(AppStrings.emptyTrashNone, {'kept': keptNote})
          : context.trf(AppStrings.emptyTrashDone, {'purged': r.purged, 'kept': keptNote});
      showZoMessage(context, message, error: r.purged == 0 && r.kept > 0);
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, purgeErrorMessage(context, e), error: true);
    }
  }

  /// 窄屏（手机）：底部导航 + 列表，详情与编辑以新页面推入。
  Widget _buildMobile(BuildContext context, List<VaultItem> visible, Map<Section, int> counts) {
    final state = AppScope.of(context);
    final c = context.zo;
    final tab = _tab;
    final isTrash = _section == Section.trash;

    void openDetail(String id) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => _MobileItemPage(itemId: id, inTrash: isTrash)));
    }

    void openEditor(EditTarget target) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (ctx) => Scaffold(
          backgroundColor: c.bg,
          body: SafeArea(
            child: ItemEditor(
              target: target,
              initial: state.byId(target.itemId)?.data,
              onCancel: () => Navigator.pop(ctx),
              onSaved: (_) => Navigator.pop(ctx),
            ),
          ),
        ),
      ));
    }

    // 分类明确时直接建该类；在「全部 / 收藏」下先让用户选类型（编辑器不允许改类型）。
    Future<void> newItem() async {
      final kind = _section.kind;
      if (kind != null) {
        openEditor(EditTarget.create(kind));
        return;
      }
      final picked = await _pickKind(context);
      if (picked != null && mounted) openEditor(EditTarget.create(picked));
    }

    final Widget body = switch (tab) {
      _MobileTab.vault => ItemListPane(
          compact: true,
          title: _section.title(context),
          // 手机端过滤条本就占用一行，标签/分类筛选接在其下。
          filterBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _VaultFilters(section: _section, counts: counts, onSelect: _go),
              ?_taxonomyBar(visible, state.trash),
            ],
          ),
          items: visible,
          selectedId: null,
          query: _query,
          searchController: _search,
          searchFocus: _searchFocus,
          isTrash: isTrash,
          onQuery: (q) => setState(() => _query = q),
          onSelect: openDetail,
        ),
      _MobileTab.generator => const GeneratorPage(),
      _MobileTab.security => SecurityPage(onOpenItem: openDetail),
      _MobileTab.settings => const SettingsPage(),
    };

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        title: const ZoWordmark(size: 14),
        actions: [
          if (isTrash && state.trash.isNotEmpty)
            IconButton(tooltip: context.tr(AppStrings.emptyTrashTooltip), onPressed: _emptyTrash, icon: const Icon(Icons.delete_sweep_outlined)),
          if (state.remote != null)
            IconButton(
              tooltip: context.tr(AppStrings.syncNow),
              onPressed: state.syncNow,
              icon: state.syncState == SyncState.syncing
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(state.syncState == SyncState.error ? Icons.sync_problem_rounded : Icons.sync_rounded),
            ),
          IconButton(tooltip: context.tr(AppStrings.lockNow), onPressed: state.lock, icon: const Icon(Icons.lock_outline_rounded)),
        ],
      ),
      body: SafeArea(bottom: false, child: body),
      floatingActionButton: tab == _MobileTab.vault && !isTrash
          ? FloatingActionButton(
              tooltip: context.tr(AppStrings.newItemTooltip),
              backgroundColor: c.accent,
              foregroundColor: c.onAccent,
              onPressed: () => newItem(),
              child: const Icon(Icons.add_rounded),
            )
          : null,
      bottomNavigationBar: _MobileNavBar(tab: tab, onSelect: _selectTab),
    );
  }

  /// 手机端新建：底部弹层选条目类型。
  Future<ItemKind?> _pickKind(BuildContext context) {
    final c = context.zo;
    return showModalBottomSheet<ItemKind>(
      context: context,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Zo.radiusLg))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 34,
                height: 4,
                decoration: BoxDecoration(color: c.borderStrong, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 6),
              child: Text(ctx.tr(AppStrings.newItemTooltip), style: ctx.text.titleLarge),
            ),
            for (final k in ItemKind.values)
              Hover(
                onTap: () => Navigator.pop(ctx, k),
                builder: (context, hover) => Container(
                  height: 52,
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: hover ? c.surfaceHover : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    children: [
                      Icon(k.icon, size: 18, color: c.textMuted),
                      const SizedBox(width: 14),
                      Text(k.title(context), style: context.text.bodyLarge),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final c = context.zo;
    final visible = _visible(state.items, state.trash);
    final selected = state.byId(_selectedId);

    final counts = <Section, int>{
      Section.all: state.items.length,
      Section.favorites: state.items.where((i) => i.data.favorite).length,
      for (final s in [Section.login, Section.card, Section.note, Section.identity])
        s: state.items.where((i) => i.data.kind == s.kind).length,
      Section.trash: state.trash.length,
    };

    if (MediaQuery.sizeOf(context).width < 720) return _buildMobile(context, visible, counts);

    Widget content;
    if (_section.isVault) {
      final editing = _editing;
      content = Row(
        children: [
          SizedBox(
            width: 340,
            child: ItemListPane(
              title: _section.title(context),
              items: visible,
              selectedId: _selectedId,
              query: _query,
              searchController: _search,
              searchFocus: _searchFocus,
              isTrash: _section == Section.trash,
              onQuery: (q) => setState(() => _query = q),
              filterBar: _taxonomyBar(visible, state.trash),
              onSelect: (id) => setState(() {
                _selectedId = id;
                _editing = null;
              }),
              onNew: _section == Section.trash ? null : _newItem,
              headerAction: _section == Section.trash && state.trash.isNotEmpty
                  ? ZoIconButton(
                      icon: Icons.delete_sweep_outlined,
                      tooltip: context.tr(AppStrings.emptyTrashTooltip),
                      onPressed: _emptyTrash,
                    )
                  : null,
            ),
          ),
          VerticalDivider(width: 1, color: c.border),
          Expanded(
            child: AnimatedSwitcher(
              duration: Zo.medium,
              switchInCurve: Zo.ease,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(a), child: child),
              ),
              child: editing != null
                  ? ItemEditor(
                      key: ValueKey('edit-${editing.itemId ?? editing.kind.name}'),
                      target: editing,
                      initial: state.byId(editing.itemId)?.data,
                      onCancel: () => setState(() => _editing = null),
                      onSaved: (item) => setState(() {
                        _editing = null;
                        _selectedId = item.id;
                      }),
                    )
                  : selected != null
                      ? ItemDetail(
                          key: ValueKey('detail-${selected.id}-${selected.revision}'),
                          item: selected,
                          inTrash: _section == Section.trash || state.trash.any((t) => t.id == selected.id),
                          onEdit: () => setState(() => _editing = EditTarget.edit(selected.id, selected.data.kind)),
                          onDeleted: () => setState(() => _selectedId = null),
                        )
                      : _EmptyDetail(onNew: _section == Section.trash ? null : () => _newItem()),
            ),
          ),
        ],
      );
    } else {
      content = switch (_section) {
        Section.generator => const GeneratorPage(),
        Section.security => SecurityPage(onOpenItem: (id) => setState(() {
              _section = Section.all;
              _selectedId = id;
            })),
        _ => const SettingsPage(),
      };
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => _newItem(),
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): state.lock,
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): () => _go(Section.generator),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_editing != null) setState(() => _editing = null);
        },
      },
      child: Focus(
        autofocus: true,
        child: Row(
          children: [
            _Sidebar(section: _section, counts: counts, onSelect: _go, onNew: () => _newItem(), onLock: state.lock),
            VerticalDivider(width: 1, color: c.border),
            Expanded(child: ColoredBox(color: c.bg, child: content)),
          ],
        ),
      ),
    );
  }
}

/// 手机端保险库页的横向过滤条：桌面侧栏的分类 / 收藏 / 回收站都在这里。
class _VaultFilters extends StatelessWidget {
  const _VaultFilters({required this.section, required this.counts, required this.onSelect});

  static const _order = [
    Section.all,
    Section.favorites,
    Section.login,
    Section.card,
    Section.note,
    Section.identity,
    Section.trash,
  ];

  final Section section;
  final Map<Section, int> counts;
  final ValueChanged<Section> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: _order.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = _order[i];
          final active = s == section;
          final n = counts[s] ?? 0;
          return Hover(
            onTap: () => onSelect(s),
            builder: (context, hover) => AnimatedContainer(
              duration: Zo.fast,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: ShapeDecoration(
                color: active ? c.accentSoft : (hover ? c.surfaceHover : c.surfaceRaised),
                shape: Zo.bevel(5).copyWith(side: BorderSide(color: active ? c.accent : c.border)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.shortTitle(context),
                    style: context.text.labelLarge?.copyWith(fontSize: 12.5, color: active ? c.accent : c.textMuted),
                  ),
                  if (n > 0) ...[
                    const SizedBox(width: 6),
                    Text('$n', style: monoStyle(context, size: 10.5, color: active ? c.accent : c.textFaint)),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 手机端底部导航条。
class _MobileNavBar extends StatelessWidget {
  const _MobileNavBar({required this.tab, required this.onSelect});

  final _MobileTab tab;
  final ValueChanged<_MobileTab> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Container(
      decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.border))),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              for (final t in _MobileTab.values)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: t == tab,
                    label: t.title(context),
                    child: Hover(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onSelect(t);
                      },
                      builder: (context, hover) {
                        final active = t == tab;
                        final color = active ? c.accent : (hover ? c.text : c.textFaint);
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            AnimatedContainer(
                              duration: Zo.fast,
                              width: 46,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: active ? c.accentSoft : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(active ? t.activeIcon : t.icon, size: 19, color: color),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              t.title(context),
                              style: context.text.labelMedium?.copyWith(
                                fontSize: 10.5,
                                color: color,
                                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.section, required this.counts, required this.onSelect, required this.onNew, required this.onLock});

  final Section section;
  final Map<Section, int> counts;
  final ValueChanged<Section> onSelect;
  final VoidCallback onNew;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final state = AppScope.of(context);
    Widget item(Section s) => _NavItem(section: s, active: section == s, count: counts[s], onTap: () => onSelect(s));
    return Container(
      width: 236,
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, 22), child: Align(alignment: Alignment.centerLeft, child: ZoWordmark(size: 15))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: ZoButton(
              label: context.tr(AppStrings.newItemTooltip),
              icon: Icons.add_rounded,
              expand: true,
              dense: true,
              onPressed: onNew,
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                item(Section.all),
                item(Section.favorites),
                const _NavGroup(AppStrings.sidebarCategories),
                item(Section.login),
                item(Section.card),
                item(Section.note),
                item(Section.identity),
                const _NavGroup(AppStrings.sidebarTools),
                item(Section.generator),
                item(Section.security),
                item(Section.trash),
              ],
            ),
          ),
          Divider(color: c.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
            child: Column(
              children: [
                item(Section.settings),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const SizedBox(width: 10),
                    Tooltip(
                      message: switch (state.syncState) {
                        SyncState.off => context.tr(AppStrings.cloudSetupPending),
                        SyncState.syncing => context.tr(AppStrings.syncing),
                        SyncState.error => context.trf(AppStrings.syncFailed, {
                          'reason': context.tr(state.syncError ?? ''),
                        }),
                        SyncState.needsReconnect => context.tr(AppStrings.cloudNeedsRevalidate),
                        SyncState.idle => context.tr(AppStrings.autoSync),
                      },
                      child: Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: switch (state.syncState) {
                            SyncState.error || SyncState.needsReconnect => c.danger,
                            SyncState.syncing => c.accent,
                            SyncState.off => c.textFaint,
                            SyncState.idle => c.success,
                          },
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        state.account?.email ?? '',
                        style: context.text.bodySmall?.copyWith(color: c.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    ZoIconButton(
                      icon: Icons.lock_outline_rounded,
                      tooltip: context.tr(AppStrings.lockNowWithHotkey),
                      onPressed: onLock,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavGroup extends StatelessWidget {
  const _NavGroup(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
        child: Text(label.toUpperCase(), style: context.text.labelSmall),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.section, required this.active, required this.onTap, this.count});

  final Section section;
  final bool active;
  final int? count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Hover(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: Zo.fast,
        height: 34,
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: active ? c.surfaceHover : (hover ? c.surfaceHover.withValues(alpha: 0.6) : Colors.transparent),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: Zo.fast,
              width: 2,
              height: active ? 14 : 0,
              margin: const EdgeInsets.only(right: 8),
              color: c.accent,
            ),
            Icon(section.icon, size: 16, color: active ? c.accent : c.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                section.title(context),
                style: context.text.bodyMedium?.copyWith(
                  color: active ? c.text : c.textMuted,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (count != null && count! > 0) Text('$count', style: monoStyle(context, size: 11, color: c.textFaint)),
          ],
        ),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail({this.onNew});

  final VoidCallback? onNew;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return ZoBackdrop(
      intensity: 0.6,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(opacity: 0.9, child: const ZoMark(size: 44)),
            const SizedBox(height: 22),
            Text(context.tr(AppStrings.selectItemHint), style: context.text.titleLarge),
            const SizedBox(height: 8),
            Text(context.tr(AppStrings.shortcutHint), style: context.text.bodySmall?.copyWith(color: c.textFaint)),
            if (onNew != null) ...[
              const SizedBox(height: 22),
              ZoButton(
                label: context.tr(AppStrings.newItemTooltip),
                icon: Icons.add_rounded,
                variant: ZoButtonVariant.secondary,
                onPressed: onNew,
              ),
            ],
          ],
        ),
      ),
    );
  }
}


/// 手机端条目详情页（数据随 AppState 刷新）。
class _MobileItemPage extends StatelessWidget {
  const _MobileItemPage({required this.itemId, required this.inTrash});

  final String itemId;
  final bool inTrash;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final item = state.byId(itemId);
    final c = context.zo;
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(backgroundColor: c.bg, surfaceTintColor: Colors.transparent),
      body: item == null
          ? Center(child: Text(context.tr(AppStrings.itemMissing)))
          : ItemDetail(
              key: ValueKey('m-${item.id}-${item.revision}'),
              item: item,
              inTrash: inTrash || state.trash.any((t) => t.id == item.id),
              onEdit: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (ctx) => Scaffold(
                  backgroundColor: c.bg,
                  body: SafeArea(
                    child: ItemEditor(
                      target: EditTarget.edit(item.id, item.data.kind),
                      initial: item.data,
                      onCancel: () => Navigator.pop(ctx),
                      onSaved: (_) => Navigator.pop(ctx),
                    ),
                  ),
                ),
              )),
              onDeleted: () => Navigator.of(context).maybePop(),
            ),
    );
  }
}
