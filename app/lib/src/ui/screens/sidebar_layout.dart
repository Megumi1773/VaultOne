import 'dart:convert';

import 'home.dart' show Section;

/// 侧栏（首页板块）的一项布局。
///
/// 顺序与显隐是**本机偏好**，存在本地设置表里，不进同步：不同设备屏幕大小不同，
/// 在手机上隐藏的分区在桌面上可能正需要，强行同步只会让两边都不顺手。
class SidebarEntry {
  const SidebarEntry({required this.section, required this.group, this.visible = true});

  final Section section;

  /// 所属分组标题（`AppStrings.sidebarCategories` / `sidebarTools`）。分组按首次出现的
  /// 位置渲染，因此拖动项目时分组标题会跟着走，不会出现「标题下面没有条目」。
  final String group;

  final bool visible;

  SidebarEntry copyWith({bool? visible}) =>
      SidebarEntry(section: section, group: group, visible: visible ?? this.visible);

  Map<String, Object?> toJson() => {'id': section.name, 'visible': visible};

  @override
  bool operator ==(Object other) =>
      other is SidebarEntry && other.section == section && other.group == group && other.visible == visible;

  @override
  int get hashCode => Object.hash(section, group, visible);
}

/// 默认布局：与侧栏原有顺序一致。
const List<({Section section, String group})> _defaults = [
  (section: Section.all, group: ''),
  (section: Section.favorites, group: ''),
  (section: Section.login, group: 'categories'),
  (section: Section.card, group: 'categories'),
  (section: Section.note, group: 'categories'),
  (section: Section.identity, group: 'categories'),
  (section: Section.generator, group: 'tools'),
  (section: Section.security, group: 'tools'),
  (section: Section.trash, group: 'tools'),
];

List<SidebarEntry> defaultSidebarLayout() =>
    [for (final d in _defaults) SidebarEntry(section: d.section, group: d.group)];

/// 按枚举名查找分区；找不到返回 null（`Section.values.firstOrNull` 不在 SDK 里）。
Section? _byName(String id) {
  for (final s in Section.values) {
    if (s.name == id) return s;
  }
  return null;
}

/// 解析已保存的布局。
///
/// 容错优先：设置可能来自旧版本、被手改或损坏。任何未知 id 都丢弃，缺失的分区按默认顺序
/// **补到末尾**——否则升级后新加的分区会直接消失，用户找不到入口。
List<SidebarEntry> resolveSidebarLayout(String? raw) {
  final defaults = defaultSidebarLayout();
  if (raw == null || raw.trim().isEmpty) return defaults;
  List<dynamic> parsed;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return defaults;
    parsed = decoded;
  } on FormatException {
    return defaults;
  }

  final out = <SidebarEntry>[];
  final seen = <Section>{};
  for (final item in parsed) {
    if (item is! Map) continue;
    final id = item['id'];
    if (id is! String) continue;
    final section = _byName(id);
    // 未知 id 直接丢弃：它可能来自被降级的版本，留着只会渲染不出来。
    // `settings` 不在可排序分区里（它固定在侧栏底部），也必须在这里挡掉。
    if (section == null || !seen.add(section)) continue;
    final defaultsFor = _defaults.where((d) => d.section == section).toList();
    if (defaultsFor.isEmpty) {
      seen.remove(section);
      continue;
    }
    out.add(SidebarEntry(
      section: section,
      group: defaultsFor.first.group,
      visible: item['visible'] != false,
    ));
  }
  for (final d in defaults) {
    if (seen.contains(d.section)) continue;
    out.add(SidebarEntry(section: d.section, group: d.group));
  }
  return out;
}

String encodeSidebarLayout(List<SidebarEntry> entries) =>
    jsonEncode([for (final e in entries) e.toJson()]);

/// 把第 [index] 项上移/下移一位。[delta] 为 -1 或 1；越界时原样返回。
List<SidebarEntry> moveSidebarEntry(List<SidebarEntry> entries, int index, int delta) {
  final target = index + delta;
  if (index < 0 || index >= entries.length || target < 0 || target >= entries.length) {
    return entries;
  }
  final out = [...entries];
  final moved = out.removeAt(index);
  out.insert(target, moved);
  return out;
}

/// 至少保留一项可见：全部隐藏会让侧栏变成一片空白，用户没有恢复入口。
bool canHide(List<SidebarEntry> entries, SidebarEntry entry) =>
    !entry.visible || entries.where((e) => e.visible && e.section != entry.section).isNotEmpty;
