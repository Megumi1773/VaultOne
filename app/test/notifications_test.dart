import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/notifications.dart';
import 'package:vaultone/src/rust/api/sync.dart';
import 'package:vaultone/src/rust/frb_generated.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/notifications_page.dart';
import 'package:vaultone/src/ui/theme.dart';

/// 只替换 FRB 边界：测试仍执行真实 AppState 与通知中心。
class _Bridge implements RustLibApi {
  final settings = <String, String>{};
  int setCalls = 0;

  @override
  Future<String?> crateApiVaultGetSetting({required String key}) async => settings[key];

  @override
  Future<void> crateApiVaultSetSetting({required String key, required String value}) async {
    setCalls++;
    settings[key] = value;
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
}) =>
    AppNotification(id: id, type: type, level: level, title: title, body: body, at: 1, action: action);

Future<AppState> _mount(WidgetTester tester, List<AppNotification> notes, {void Function(NotificationAction)? onAct}) async {
  final bridge = _Bridge();
  RustLib.initMock(api: bridge);
  addTearDown(RustLib.dispose);
  final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
  state.notifications = notes;
  addTearDown(state.dispose);
  tester.view.physicalSize = const Size(1000, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: state,
    child: MaterialApp(theme: buildTheme(Brightness.light), home: NotificationsPage(onAct: onAct)),
  ));
  await tester.pumpAndSettle();
  return state;
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
      final all = countUnread(notes, const {});
      expect(all.total, 4);
      expect(all.security, 1);
      expect(all.personal, 1);
      // 弹窗与服务端公告都算公告类，与内核 notify::unread_counts 同一口径。
      expect(all.announcement, 2);

      final read = countUnread(notes, {'a', 'c'});
      expect(read.total, 2);
      expect(read.security, 0);
      expect(read.announcement, 1);
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

  group('通知中心（§6.1 / §6.2）', () {
    testWidgets('空态给出说明而不是白屏', (tester) async {
      await _mount(tester, const []);
      expect(find.text('暂无通知'), findsOneWidget);
      expect(find.text('这里会出现安全提醒与官方公告。'), findsOneWidget);
    });

    testWidgets('列出通知并显示正文与动作', (tester) async {
      await _mount(tester, [
        _note(
          id: 'a',
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
      final state = await _mount(
        tester,
        [
          _note(
            id: 'a',
            title: '该备份了',
            action: const NotificationAction(kind: NotificationActionKind.route, label: '立即备份', value: 'openBackup'),
          ),
        ],
        onAct: (a) => acted = a,
      );
      expect(state.unreadNotifications.total, 1);

      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(state.isNotificationRead('a'), isTrue);
      expect(state.unreadNotifications.total, 0);
      expect(acted?.value, 'openBackup');
    });

    testWidgets('「全部标为已读」清空角标', (tester) async {
      final state = await _mount(tester, [_note(id: 'a'), _note(id: 'b')]);
      expect(state.unreadNotifications.total, 2);

      await tester.tap(find.text('全部标为已读'));
      await tester.pumpAndSettle();
      expect(state.unreadNotifications.total, 0);
    });

    testWidgets('分类筛选只留下该类别', (tester) async {
      await _mount(tester, [
        _note(id: 'a', type: NotificationType.security, title: '安全那条'),
        _note(id: 'b', type: NotificationType.personal, title: '个人那条'),
      ]);
      expect(find.text('安全那条'), findsOneWidget);
      expect(find.text('个人那条'), findsOneWidget);

      await tester.tap(find.textContaining('个人消息'));
      await tester.pumpAndSettle();
      expect(find.text('个人那条'), findsOneWidget);
      expect(find.text('安全那条'), findsNothing);
    });

    testWidgets('「仅显示未读」把已读的藏起来', (tester) async {
      final state = await _mount(tester, [_note(id: 'a', title: '已读那条'), _note(id: 'b', title: '未读那条')]);
      await state.markNotificationRead('a');
      await tester.pumpAndSettle();

      await tester.tap(find.text('仅显示未读'));
      await tester.pumpAndSettle();
      expect(find.text('已读那条'), findsNothing);
      expect(find.text('未读那条'), findsOneWidget);
    });
  });

  group('铃铛（§6.4）', () {
    testWidgets('有未读时显示角标，无未读时不显示', (tester) async {
      RustLib.initMock(api: _Bridge());
      addTearDown(RustLib.dispose);
      final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
      state.notifications = [_note(id: 'a'), _note(id: 'b')];
      addTearDown(state.dispose);
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
