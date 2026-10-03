import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/notifications.dart';
import 'package:vaultone/src/rust/api/sync.dart';
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/notifications_page.dart';
import 'package:vaultone/src/ui/theme.dart';

/// 只替换 FRB 边界：测试仍执行真实 AppState 与通知中心。
///
/// 服务端通知走 `VaultApi._network`，它会先查 `privacy_consent`、再校验账号绑定的服务器，
/// 因此这个假桥必须把这两步都实现出来，否则测到的是门禁而不是通知。
class _Bridge implements RustLibApi {
  _Bridge({this.pages = const []});

  /// 依次返回的页：每项是 (notifications JSON, nextCursor)。
  final List<(String, String?)> pages;
  int fetchCalls = 0;

  // 通知走 `_network`，它会先查隐私同意：写死一个假版本号只会得到一个
  // privacy_required，测到的就不是通知了。
  final settings = <String, String>{'privacy_consent': VaultApi.privacyVersion};
  final markedRead = <String>[];

  @override
  Future<String?> crateApiVaultGetSetting({required String key}) async => settings[key];

  @override
  Future<void> crateApiVaultSetSetting({required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<void> crateApiSyncConfigureDevelopmentHttp({String? serverUrl}) async {}

  @override
  Future<RemoteStatusDto?> crateApiSyncRemoteStatus() async => null;

  @override
  Future<String> crateApiSyncNotifications({required String cursor, required int limit}) async {
    final index = fetchCalls++;
    if (index >= pages.length) return '{"notifications":[],"nextCursor":null}';
    final (body, next) = pages[index];
    return '{"notifications":$body,"nextCursor":${next == null ? 'null' : '"$next"'},'
        '"unread":{"total":0,"announcement":0,"personal":0,"security":0}}';
  }

  @override
  Future<String> crateApiSyncMarkNotificationRead({required String id}) async {
    markedRead.add(id);
    return '{"total":0,"announcement":0,"personal":0,"security":0}';
  }

  @override
  Future<AccountProfileDto> crateApiSyncAccountProfile() async =>
      const AccountProfileDto(nickname: '', avatar: '', createdAt: 0, inviteCode: '', online: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppNotification _note({
  required String id,
  NotificationType type = NotificationType.security,
  NotificationLevel level = NotificationLevel.info,
  String title = '标题',
  String body = '正文',
  NotificationAction action = NotificationAction.none,
  bool read = false,
  int at = 1,
}) =>
    AppNotification(
      id: id,
      type: type,
      level: level,
      title: title,
      body: body,
      at: at,
      action: action,
      read: read,
    );

/// 本机提醒的 id 一定带 `local.` 前缀（内核 `notify::from_checklist` 就是这么生成的）。
AppNotification _local({
  required String suffix,
  NotificationLevel level = NotificationLevel.info,
  String title = '标题',
  String body = '正文',
  NotificationAction action = NotificationAction.none,
  int at = 1,
}) =>
    _note(id: 'local.$suffix', type: NotificationType.security, level: level, title: title, body: body, action: action, at: at);

/// 服务端通知的 JSON 片段。
String _wire(String id, {String type = 'announcement', String level = 'info', bool read = false, int at = 1}) =>
    '{"id":"$id","type":"$type","level":"$level","title":"服务端 $id","body":"正文","publishedAt":$at,"read":$read,'
    '"action":{"kind":"none","value":"","label":""}}';

Future<(AppState, _Bridge)> _mount(
  WidgetTester tester,
  List<AppNotification> notes, {
  void Function(NotificationAction)? onAct,
  List<(String, String?)> pages = const [],
}) async {
  final bridge = _Bridge(pages: pages);
  RustLib.initMock(api: bridge);
  addTearDown(RustLib.dispose);
  final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
  addTearDown(state.dispose);
  await state.setNotifications(notes);
  tester.view.physicalSize = const Size(1000, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: state,
    child: MaterialApp(theme: buildTheme(Brightness.light), home: NotificationsPage(onAct: onAct)),
  ));
  await tester.pumpAndSettle();
  return (state, bridge);
}

void main() {
  group('未读计数（§6.1）', () {
    test('按类别拆分，已读不计入', () {
      final notes = [
        _note(id: 'a', type: NotificationType.security),
        _note(id: 'b', type: NotificationType.personal),
        _note(id: 'c', type: NotificationType.announcement),
        _note(id: 'd', type: NotificationType.popup),
      ];
      final all = countUnread(notes);
      expect(all.total, 4);
      expect(all.security, 1);
      expect(all.personal, 1);
      // 弹窗与服务端公告都算公告类，与内核 notify::unread_counts 同一口径。
      expect(all.announcement, 2);

      final some = countUnread([
        notes[0].asRead(),
        notes[1],
        notes[2].asRead(),
        notes[3],
      ]);
      expect(some.total, 2);
      expect(some.security, 0);
      expect(some.announcement, 1);
    });

    test('计数只看每条的 read，不查外部集合', () {
      // 已读来自哪里是状态层的事；计数与渲染都不该再知道一遍。
      expect(countUnread([_note(id: 'x', read: true)]).total, 0);
      expect(countUnread([_note(id: 'x')]).total, 1);
    });
  });

  group('强制确认（§6.3）', () {
    test('只有严重级别必须确认', () {
      expect(_note(id: 'a', level: NotificationLevel.critical).mustAck, isTrue);
      // 弱密码这类「重要」提醒不强制确认：满屏关不掉的弹窗只会让人学会无视弹窗。
      expect(_note(id: 'b', level: NotificationLevel.important).mustAck, isFalse);
      expect(_note(id: 'c', level: NotificationLevel.info).mustAck, isFalse);
    });
  });

  group('本机提醒的已读（§6.1）', () {
    testWidgets('空态给出说明而不是白屏', (tester) async {
      await _mount(tester, const []);
      expect(find.text('暂无通知'), findsOneWidget);
      expect(find.text('这里会出现安全提醒与官方公告。'), findsOneWidget);
    });

    testWidgets('列出通知并显示正文与动作', (tester) async {
      await _mount(tester, [
        _local(
          suffix: 'task.noBreach',
          title: '密码已泄露',
          body: '3 条密码出现在公开泄露数据中。',
          level: NotificationLevel.critical,
          action: const NotificationAction(kind: NotificationActionKind.route, label: '去体检', value: 'openCheckup'),
        ),
      ]);
      expect(find.text('密码已泄露'), findsOneWidget);
      expect(find.text('3 条密码出现在公开泄露数据中。'), findsOneWidget);
      expect(find.text('去体检'), findsOneWidget);
    });

    testWidgets('点击即标记已读并触发动作', (tester) async {
      NotificationAction? acted;
      final (state, _) = await _mount(
        tester,
        [
          _local(
            suffix: 'task.backup',
            title: '该备份了',
            action: const NotificationAction(kind: NotificationActionKind.route, label: '立即备份', value: 'openBackup'),
          ),
        ],
        onAct: (a) => acted = a,
      );
      expect(state.unreadNotifications.total, 1);

      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(state.isNotificationRead('local.task.backup'), isTrue);
      expect(state.unreadNotifications.total, 0);
      expect(acted?.value, 'openBackup');
    });

    testWidgets('「全部标为已读」清空角标', (tester) async {
      final (state, _) = await _mount(tester, [_local(suffix: 'a'), _local(suffix: 'b')]);
      expect(state.unreadNotifications.total, 2);

      await tester.tap(find.text('全部标为已读'));
      await tester.pumpAndSettle();
      expect(state.unreadNotifications.total, 0);
    });

    testWidgets('分类筛选只留下该类别', (tester) async {
      await _mount(tester, [
        _local(suffix: 'a', title: '安全那条'),
        _note(id: 'n1', type: NotificationType.personal, title: '个人那条'),
      ]);
      expect(find.text('安全那条'), findsOneWidget);
      expect(find.text('个人那条'), findsOneWidget);

      await tester.tap(find.textContaining('个人消息'));
      await tester.pumpAndSettle();
      expect(find.text('个人那条'), findsOneWidget);
      expect(find.text('安全那条'), findsNothing);
    });

    testWidgets('「仅显示未读」把已读的藏起来', (tester) async {
      final (state, _) = await _mount(tester, [
        _local(suffix: 'a', title: '已读那条'),
        _local(suffix: 'b', title: '未读那条'),
      ]);
      await state.markNotificationRead('local.a');
      await tester.pumpAndSettle();

      await tester.tap(find.text('仅显示未读'));
      await tester.pumpAndSettle();
      expect(find.text('已读那条'), findsNothing);
      expect(find.text('未读那条'), findsOneWidget);
    });
  });

  group('服务端通知合并（§6.1）', () {
    testWidgets('拉取后与本机提醒按时间倒序合并', (tester) async {
      // 通知中心自己会在 initState 里拉第一页，测试不必再拉一次——再拉一次会吃掉下一页。
      final (state, bridge) = await _mount(
        tester,
        [_local(suffix: 'x', title: '本机那条', at: 100)],
        pages: [('[${_wire('n1', at: 200)}]', null)],
      );

      expect(bridge.fetchCalls, 1);
      // 服务端那条更新，应排在本机那条前面。
      expect(state.notifications.first.id, 'n1');
      expect(state.notifications.last.id, 'local.x');
      expect(find.text('服务端 n1'), findsOneWidget);
      expect(find.text('本机那条'), findsOneWidget);
    });

    testWidgets('服务端已读不在角标里计数', (tester) async {
      final (state, _) = await _mount(
        tester,
        const [],
        pages: [('[${_wire('a', read: true)},${_wire('b', read: false)}]', null)],
      );
      expect(state.unreadNotifications.total, 1);
    });

    testWidgets('服务端不可用时保留本机提醒，不报错', (tester) async {
      // 假桥没准备页 → 返回空列表，等价于「服务端没东西」。
      final (state, _) = await _mount(tester, [_local(suffix: 'x', title: '本机那条')]);
      expect(find.text('本机那条'), findsOneWidget);
      expect(state.unreadNotifications.total, 1);
      // 服务端不可用不该让本地计数出错，也不该弹出任何错误提示。
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('标记服务端通知已读会调服务端接口', (tester) async {
      final (state, bridge) = await _mount(tester, const [], pages: [('[${_wire('n1')}]', null)]);

      await state.markNotificationRead('n1');
      await tester.pumpAndSettle();
      expect(bridge.markedRead, ['n1']);
      expect(state.unreadNotifications.total, 0);
    });

    testWidgets('分页：加载更多会追加并按 id 去重', (tester) async {
      final (state, _) = await _mount(
        tester,
        const [],
        pages: [
          ('[${_wire('a')}]', 'cursor-1'),
          // 第二页故意重复返回 a：分页边界上重复不该在列表里出现两次。
          ('[${_wire('a')},${_wire('b')}]', null),
        ],
      );
      expect(state.hasMoreNotifications, isTrue);
      expect(find.text('加载更多'), findsOneWidget);

      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      // 同一秒内按 id 升序兜底：排序必须是确定的，否则每次重建列表顺序都会抖动。
      expect(state.notifications.map((n) => n.id), ['a', 'b']);
      expect(state.hasMoreNotifications, isFalse);
      expect(find.text('加载更多'), findsNothing);
    });
  });

  group('铃铛（§6.4）', () {
    testWidgets('有未读时显示角标，无未读时不显示', (tester) async {
      RustLib.initMock(api: _Bridge());
      addTearDown(RustLib.dispose);
      final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
      addTearDown(state.dispose);
      await state.setNotifications([_local(suffix: 'a'), _local(suffix: 'b')]);
      await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(appBar: AppBar(actions: [NotificationBell(onOpen: () {})])),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);

      await state.markAllNotificationsRead();
      await tester.pumpAndSettle();
      // 角标整个隐藏，而不是显示「0」：0 也是个需要读的东西。
      expect(find.text('0'), findsNothing);
    });
  });
}
