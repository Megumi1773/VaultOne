import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/notifications.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';

/// 通知中心（计划书 §6.1 / §6.2）。
///
/// 目前只展示**本机安全提醒**：它们由体检任务清单投影而来，离线也有内容。
/// 服务端公告 / 弹窗需要 Java 侧的通知表与接口，尚未实现，界面不假装有。
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key, this.onAct});

  /// 点击动作按钮时的跳转回调。为 null 时只在应用内提示。
  final void Function(NotificationAction action)? onAct;

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

/// 通知中心的分类筛选项。`null` 表示「全部」。
enum _Category { announcement, personal, security }

class _NotificationsPageState extends State<NotificationsPage> {
  _Category? _category;
  bool _onlyUnread = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final all = state.notifications;
    final counts = state.unreadNotifications;
    final visible = [
      for (final n in all)
        if ((_category == null || n.category == _category!.name) &&
            (!_onlyUnread || !state.isNotificationRead(n.id)))
          n,
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: context.zo.surface,
        surfaceTintColor: Colors.transparent,
        title: Text(context.tr(AppStrings.notificationsCenter)),
        actions: [
          if (counts.total > 0)
            TextButton(
              onPressed: state.markAllNotificationsRead,
              child: Text(context.tr(AppStrings.notificationsMarkAllRead)),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FilterBar(
            counts: counts,
            category: _category,
            onlyUnread: _onlyUnread,
            onCategory: (c) => setState(() => _category = c),
            onOnlyUnread: (v) => setState(() => _onlyUnread = v),
          ),
          Expanded(
            child: visible.isEmpty
                ? _Empty()
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _NotificationTile(
                      notification: visible[i],
                      read: state.isNotificationRead(visible[i].id),
                      onOpen: () => _open(state, visible[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 进入即标记已读（计划书 §6.1「已读标记（进入详情即标记）」），然后执行动作。
  Future<void> _open(AppState state, AppNotification n) async {
    await state.markNotificationRead(n.id);
    final act = widget.onAct;
    if (act != null) {
      act(n.action);
      return;
    }
    if (n.action.kind == NotificationActionKind.url) {
      final uri = Uri.tryParse(n.action.value);
      if (uri != null && context.mounted) await launchUrl(uri);
    }
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.counts,
    required this.category,
    required this.onlyUnread,
    required this.onCategory,
    required this.onOnlyUnread,
  });

  final UnreadCounts counts;
  final _Category? category;
  final bool onlyUnread;
  final ValueChanged<_Category?> onCategory;
  final ValueChanged<bool> onOnlyUnread;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _chip(context, null, context.tr(AppStrings.sectionAllShort), counts.total),
            _chip(context, _Category.announcement, context.tr(AppStrings.notificationCategoryAnnouncement), counts.announcement),
            _chip(context, _Category.personal, context.tr(AppStrings.notificationCategoryPersonal), counts.personal),
            _chip(context, _Category.security, context.tr(AppStrings.notificationCategorySecurity), counts.security),
            FilterChip(
              selected: onlyUnread,
              label: Text(context.tr(AppStrings.notificationOnlyUnread)),
              onSelected: onOnlyUnread,
            ),
          ],
        ),
      );

  /// 分类计数为 0 时仍然显示该分类：藏起来会让「公告」这类入口永远找不到。
  Widget _chip(BuildContext context, _Category? value, String label, int unread) => FilterChip(
        selected: category == value,
        label: Text(unread > 0 ? '$label · $unread' : label),
        onSelected: (_) => onCategory(value),
      );
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_none_rounded, size: 40, color: context.zo.textFaint),
            const SizedBox(height: 10),
            Text(context.tr(AppStrings.notificationsEmpty), style: context.text.titleMedium),
            const SizedBox(height: 4),
            Text(context.tr(AppStrings.notificationsEmptyHint), style: context.text.bodySmall),
          ],
        ),
      );
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.read, required this.onOpen});

  final AppNotification notification;
  final bool read;
  final VoidCallback onOpen;

  static (Color Function(ZoColors), IconData) _style(NotificationLevel level) => switch (level) {
        NotificationLevel.critical => ((c) => c.danger, Icons.error_outline_rounded),
        NotificationLevel.important => ((c) => c.warning, Icons.priority_high_rounded),
        NotificationLevel.info => ((c) => c.accent, Icons.info_outline_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final (color, icon) = _style(notification.level);
    return ZoPanel(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(Zo.radiusLg),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color(c)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      // 未读用一颗点表示，而不是把整行加粗：整行加粗会让「已读」也显得很吵。
                      if (!read) ...[
                        Container(width: 6, height: 6, decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          notification.title,
                          style: context.text.titleMedium?.copyWith(fontSize: 13.5),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(notification.body, style: context.text.bodySmall),
                    if (notification.action.kind != NotificationActionKind.none) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ZoButton(
                          label: notification.action.label,
                          dense: true,
                          variant: ZoButtonVariant.secondary,
                          onPressed: onOpen,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 未读角标（计划书 §6.4）。包住任意按钮即可，角标的显隐规则只写这一处：
/// **没有未读时整个隐藏**，而不是显示「0」——0 也是个需要读的东西。
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final unread = AppScope.of(context).unreadNotifications.total;
    return Badge(
      isLabelVisible: unread > 0,
      label: Text(unread > 99 ? '99+' : '$unread'),
      child: child,
    );
  }
}

/// 全局通知铃铛（计划书 §6.4）：未读角标 + 点击进入通知中心。
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final unread = AppScope.of(context).unreadNotifications.total;
    return IconButton(
      tooltip: unread > 0
          ? '${context.tr(AppStrings.notificationsCenter)} · $unread ${context.tr(AppStrings.notificationsUnread)}'
          : context.tr(AppStrings.notificationsCenter),
      onPressed: onOpen,
      icon: const UnreadBadge(child: Icon(Icons.notifications_none_rounded)),
    );
  }
}

/// 打开通知中心。
Future<void> showNotifications(BuildContext context, {void Function(NotificationAction)? onAct}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => NotificationsPage(onAct: onAct)),
    );
