import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../widgets/controls.dart';
import 'generator_page.dart';
import 'item_detail.dart';
import 'item_editor.dart';
import 'item_list.dart';
import 'security_page.dart';
import 'settings_page.dart';

enum Section {
  all('全部条目', Icons.grid_view_rounded),
  favorites('收藏', Icons.star_outline_rounded),
  login('登录', Icons.key_rounded),
  card('支付卡', Icons.credit_card_rounded),
  note('安全笔记', Icons.sticky_note_2_outlined),
  identity('身份信息', Icons.badge_outlined),
  generator('密码生成器', Icons.auto_awesome_outlined),
  security('安全中心', Icons.shield_outlined),
  trash('回收站', Icons.delete_outline_rounded),
  settings('设置', Icons.tune_rounded);

  const Section(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get isVault => index <= Section.identity.index || this == Section.trash;

  ItemKind? get kind => switch (this) {
        Section.login => ItemKind.login,
        Section.card => ItemKind.card,
        Section.note => ItemKind.note,
        Section.identity => ItemKind.identity,
        _ => null,
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

class _HomeScreenState extends State<HomeScreen> {
  Section _section = Section.all;
  String _query = '';
  String? _selectedId;
  EditTarget? _editing;
  final _searchFocus = FocusNode();
  final _search = TextEditingController();
  AppState? _state;

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
    final q = _query.trim().toLowerCase();
    final kind = _section.kind;
    final out = source.where((i) {
      if (kind != null && i.data.kind != kind) return false;
      if (_section == Section.favorites && !i.data.favorite) return false;
      if (q.isNotEmpty && !i.data.searchText.contains(q)) return false;
      return true;
    }).toList();
    out.sort((a, b) {
      if (a.data.favorite != b.data.favorite && _section != Section.trash) return a.data.favorite ? -1 : 1;
      return a.data.title.toLowerCase().compareTo(b.data.title.toLowerCase());
    });
    return out;
  }

  void _go(Section s) => setState(() {
        _section = s;
        _editing = null;
        if (!s.isVault) _selectedId = null;
      });

  void _newItem([ItemKind? kind]) => setState(() {
        if (!_section.isVault || _section == Section.trash) _section = Section.all;
        _editing = EditTarget.create(kind ?? _section.kind ?? ItemKind.login);
      });

  /// 窄屏（手机）：抽屉导航 + 列表，详情与编辑以新页面推入。
  Widget _buildMobile(BuildContext context, List<VaultItem> visible, Map<Section, int> counts) {
    final state = AppScope.of(context);
    final c = context.zo;
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

    final Widget body = _section.isVault
        ? ItemListPane(
            title: _section.label,
            items: visible,
            selectedId: null,
            query: _query,
            searchController: _search,
            searchFocus: _searchFocus,
            isTrash: isTrash,
            onQuery: (q) => setState(() => _query = q),
            onSelect: openDetail,
            onNew: isTrash ? null : ([kind]) => openEditor(EditTarget.create(kind ?? _section.kind ?? ItemKind.login)),
          )
        : switch (_section) {
            Section.generator => const GeneratorPage(),
            Section.security => SecurityPage(onOpenItem: openDetail),
            _ => const SettingsPage(),
          };

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        title: const ZoWordmark(size: 14),
        actions: [
          if (state.remote != null)
            IconButton(
              tooltip: '立即同步',
              onPressed: state.syncNow,
              icon: state.syncState == SyncState.syncing
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(state.syncState == SyncState.error ? Icons.sync_problem_rounded : Icons.sync_rounded),
            ),
          IconButton(tooltip: '立即锁定', onPressed: state.lock, icon: const Icon(Icons.lock_outline_rounded)),
        ],
      ),
      drawer: Drawer(
        backgroundColor: c.surface,
        child: SafeArea(
          child: _Sidebar(
            section: _section,
            counts: counts,
            onSelect: (s) {
              Navigator.pop(context);
              _go(s);
            },
            onNew: () {
              Navigator.pop(context);
              openEditor(EditTarget.create(_section.kind ?? ItemKind.login));
            },
            onLock: state.lock,
          ),
        ),
      ),
      body: SafeArea(child: body),
      floatingActionButton: _section.isVault && !isTrash
          ? FloatingActionButton(
              tooltip: '新建条目',
              backgroundColor: c.accent,
              foregroundColor: c.onAccent,
              onPressed: () => openEditor(EditTarget.create(_section.kind ?? ItemKind.login)),
              child: const Icon(Icons.add_rounded),
            )
          : null,
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
              title: _section.label,
              items: visible,
              selectedId: _selectedId,
              query: _query,
              searchController: _search,
              searchFocus: _searchFocus,
              isTrash: _section == Section.trash,
              onQuery: (q) => setState(() => _query = q),
              onSelect: (id) => setState(() {
                _selectedId = id;
                _editing = null;
              }),
              onNew: _section == Section.trash ? null : _newItem,
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
      width: MediaQuery.sizeOf(context).width < 720 ? null : 236,
      color: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 18, 20, 22), child: Align(alignment: Alignment.centerLeft, child: ZoWordmark(size: 15))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: ZoButton(label: '新建条目', icon: Icons.add_rounded, expand: true, dense: true, onPressed: onNew),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                item(Section.all),
                item(Section.favorites),
                const _NavGroup('分类'),
                item(Section.login),
                item(Section.card),
                item(Section.note),
                item(Section.identity),
                const _NavGroup('工具'),
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
                        SyncState.off => '云账户尚未完成接入',
                        SyncState.syncing => '同步中…',
                        SyncState.error => '同步失败：${state.syncError ?? ''}',
                        SyncState.needsReconnect => '云账户需要重新验证',
                        SyncState.idle => '条目自动同步',
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
                    ZoIconButton(icon: Icons.lock_outline_rounded, tooltip: '立即锁定 (Ctrl+L)', onPressed: onLock),
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
                section.label,
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
            Text('选择一个条目查看详情', style: context.text.titleLarge),
            const SizedBox(height: 8),
            Text('Ctrl+F 搜索 · Ctrl+N 新建 · Ctrl+G 生成密码 · Ctrl+L 锁定', style: context.text.bodySmall?.copyWith(color: c.textFaint)),
            if (onNew != null) ...[
              const SizedBox(height: 22),
              ZoButton(label: '新建条目', icon: Icons.add_rounded, variant: ZoButtonVariant.secondary, onPressed: onNew),
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
          ? const Center(child: Text('条目不存在'))
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
