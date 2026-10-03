/// 通知类型（计划书 §6.1）。服务端公告与弹窗由 Java 侧下发；本机只产生 [security]。
enum NotificationType {
  announcement('announcement'),
  popup('popup'),
  personal('personal'),
  security('security');

  const NotificationType(this.wire);

  final String wire;

  static NotificationType parse(String? value) =>
      NotificationType.values.firstWhere((t) => t.wire == value, orElse: () => NotificationType.security);
}

/// 通知级别（计划书 §6.1）。
enum NotificationLevel {
  info('info'),
  important('important'),
  critical('critical');

  const NotificationLevel(this.wire);

  final String wire;

  static NotificationLevel parse(String? value) =>
      NotificationLevel.values.firstWhere((l) => l.wire == value, orElse: () => NotificationLevel.info);
}

/// 动作类型（计划书 §6.1）。
enum NotificationActionKind {
  none('none'),
  route('route'),
  url('url');

  const NotificationActionKind(this.wire);

  final String wire;

  static NotificationActionKind parse(String? value) =>
      NotificationActionKind.values.firstWhere((a) => a.wire == value, orElse: () => NotificationActionKind.none);
}

/// 通知上的动作按钮。
class NotificationAction {
  const NotificationAction({required this.kind, required this.label, required this.value});

  factory NotificationAction.fromJson(Map<String, dynamic> j) => NotificationAction(
        kind: NotificationActionKind.parse(j['kind'] as String?),
        label: j['label'] as String? ?? '',
        value: j['value'] as String? ?? '',
      );

  static const none = NotificationAction(kind: NotificationActionKind.none, label: '', value: '');

  final NotificationActionKind kind;
  final String label;

  /// [NotificationActionKind.route] 时是 [FindingAction] 的线协议取值；[NotificationActionKind.url] 时是链接。
  final String value;

  /// 是否是可跳转的内部路由。
  ///
  /// 这里**只返回线协议取值，不解析成 `FindingAction`**：那样本文件就要 import
  /// `health_models.dart`，而后者又要 import 本文件，两个库互相依赖。
  /// 界面本来就已经 import 了 `health_models.dart`，由它做 `FindingAction.parse(value)` 更顺。
  bool get isRoute => kind == NotificationActionKind.route && value.isNotEmpty;
}

/// 一条通知（计划书 §6.1）。正文是纯文本，不渲染 HTML。
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.level,
    required this.title,
    required this.body,
    required this.at,
    required this.action,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String? ?? '',
        type: NotificationType.parse(j['type'] as String?),
        level: NotificationLevel.parse(j['level'] as String?),
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        at: (j['at'] as num?)?.toInt() ?? 0,
        action: NotificationAction.fromJson(((j['action'] as Map?) ?? const {}).cast()),
      );

  final String id;
  final NotificationType type;
  final NotificationLevel level;
  final String title;
  final String body;

  /// 产生时间（Unix 秒）。
  final int at;
  final NotificationAction action;

  /// 是否必须确认才能关掉（计划书 §6.3 的 `mustAck`）。与内核 `AppNotification::must_ack` 同一规则：
  /// **只有严重级别**。把「弱密码」也做成关不掉的弹窗，用户会直接学会无视弹窗，那比不弹更糟。
  bool get mustAck => level == NotificationLevel.critical;

  /// 分类计数用的类别键。弹窗与服务端公告都计入公告类。
  String get category => switch (type) {
        NotificationType.announcement || NotificationType.popup => 'announcement',
        NotificationType.personal => 'personal',
        NotificationType.security => 'security',
      };
}

/// 未读分类计数（计划书 §6.1「总未读 / 公告 / 个人 / 安全」）。
class UnreadCounts {
  const UnreadCounts({
    this.total = 0,
    this.announcement = 0,
    this.personal = 0,
    this.security = 0,
  });

  final int total;
  final int announcement;
  final int personal;
  final int security;

  bool get isEmpty => total == 0;
}

/// 按已读集合统计未读。
///
/// 与内核 `notify::unread_counts` 同一规则；这里保留一份是因为界面要在**不重跑体检**的情况下
/// 随已读状态实时刷新角标。内核那份用于服务端合并后的口径，两份的输入都是同一组通知与已读集合，
/// 规则本身只有一条：**在已读集合里就不算未读**。
UnreadCounts countUnread(List<AppNotification> notifications, Set<String> read) {
  var total = 0, announcement = 0, personal = 0, security = 0;
  for (final n in notifications) {
    if (read.contains(n.id)) continue;
    total++;
    switch (n.category) {
      case 'announcement':
        announcement++;
      case 'personal':
        personal++;
      default:
        security++;
    }
  }
  return UnreadCounts(
    total: total,
    announcement: announcement,
    personal: personal,
    security: security,
  );
}
