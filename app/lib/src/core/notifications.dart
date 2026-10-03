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
///
/// 一个类型同时承载**本机提醒**与**服务端通知**：两者字段完全相同，唯一的差别是已读状态由谁维护。
/// 拆成两个类型会让通知中心的每处渲染都写两遍分支，而那两遍迟早会走偏。
class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.level,
    required this.title,
    required this.body,
    required this.at,
    required this.action,
    this.read = false,
  });

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String? ?? '',
        type: NotificationType.parse(j['type'] as String?),
        level: NotificationLevel.parse(j['level'] as String?),
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        // 服务端字段是 `published_at`，本机提醒是 `at`。两个名字都认，免得为了统一名字
        // 在两处各写一次映射。
        at: ((j['at'] ?? j['publishedAt']) as num?)?.toInt() ?? 0,
        action: NotificationAction.fromJson(((j['action'] as Map?) ?? const {}).cast()),
        read: j['read'] == true,
      );

  /// 本机提醒的 id 前缀。用它区分「已读存在本机」还是「已读存在服务端」。
  static const localPrefix = 'local.';

  /// 是否是本机提醒（已读状态存本机设置，不参与同步）。
  bool get isLocal => id.startsWith(localPrefix);

  final String id;
  final NotificationType type;
  final NotificationLevel level;
  final String title;
  final String body;

  /// 产生时间（Unix 秒）。
  final int at;
  final NotificationAction action;

  /// 已读状态。
  ///
  /// 本机提醒恒为 false——它的已读存在本机设置里，由状态层在合并时覆盖；
  /// 服务端通知则由服务端返回的 `read` 决定。合并后的列表里这个字段一定是权威值。
  final bool read;

  /// 同一内容的已读副本。合并时用来把「本机已读集合」应用到本机提醒上。
  AppNotification asRead() => read
      ? this
      : AppNotification(
          id: id, type: type, level: level, title: title, body: body, at: at, action: action, read: true);

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

/// 服务端返回的未读统计（计划书 §6.1）。
///
/// 与本地 [countUnread] 的结果分开：服务端统计覆盖**全部**通知（含尚未翻到的页），
/// 本地计数只覆盖已加载的部分。两者用途不同，不能互相顶替。
class NotificationUnread {
  const NotificationUnread({
    this.total = 0,
    this.announcement = 0,
    this.personal = 0,
    this.security = 0,
  });

  factory NotificationUnread.fromJson(Map<String, dynamic> j) => NotificationUnread(
        total: (j['total'] as num?)?.toInt() ?? 0,
        announcement: (j['announcement'] as num?)?.toInt() ?? 0,
        personal: (j['personal'] as num?)?.toInt() ?? 0,
        security: (j['security'] as num?)?.toInt() ?? 0,
      );

  final int total;
  final int announcement;
  final int personal;
  final int security;
}

/// 服务端通知的一页（计划书 §6.1）。
class NotificationPage {
  const NotificationPage({required this.items, this.nextCursor});

  factory NotificationPage.fromJson(Map<String, dynamic> j) => NotificationPage(
        items: [
          for (final n in (j['notifications'] as List? ?? const []))
            AppNotification.fromJson((n as Map).cast()),
        ],
        nextCursor: j['nextCursor'] as String?,
      );

  final List<AppNotification> items;

  /// null / 空表示没有下一页。
  final String? nextCursor;
}

/// 按合并后的已读状态统计未读（计划书 §6.1「总未读 / 公告 / 个人 / 安全」）。
///
/// 只看每条的 `read`：本机提醒的已读由状态层在合并时写好，服务端通知的已读由服务端返回。
/// **不在这里查本机已读集合**——那等于把「已读从哪来」这个知识复制到渲染路径上。
UnreadCounts countUnread(List<AppNotification> notifications) {
  var total = 0, announcement = 0, personal = 0, security = 0;
  for (final n in notifications) {
    if (n.read) continue;
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
