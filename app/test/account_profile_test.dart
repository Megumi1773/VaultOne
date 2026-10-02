import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/settings_page.dart';
import 'package:vaultone/src/ui/theme.dart';
import 'package:vaultone/src/ui/widgets/controls.dart' show ZoIconButton;

void main() {
  group('AccountProfile 解析', () {
    test('缺字段按默认值处理', () {
      final p = accountProfileFromJson(const {});
      expect(p.nickname, '');
      expect(p.avatar, '');
      expect(p.createdAt, 0);
      expect(p.inviteCode, '');
      expect(p.online, isFalse, reason: '没明说在线就按离线处理，界面会提示缓存');
    });

    test('完整字段正常解析', () {
      final p = accountProfileFromJson(const {
        'nickname': '阿澈',
        'avatar': 'https://example.com/a.png',
        'createdAt': 1700000000,
        'inviteCode': 'ABCD2345EFGH',
        'online': true,
      });
      expect(p.nickname, '阿澈');
      expect(p.avatar, 'https://example.com/a.png');
      expect(p.createdAt, 1700000000);
      expect(p.inviteCode, 'ABCD2345EFGH');
      expect(p.online, isTrue);
    });
  });

  group('账户分区展示资料', () {
    Future<void> mount(WidgetTester tester, {AccountProfile? profile}) async {
      final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
      state.profile = profile;
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: SettingsPage(initialSection: SettingsSection.account)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('没有昵称时显示占位而不是空白', (tester) async {
      await mount(tester, profile: (nickname: '', avatar: '', createdAt: 0, inviteCode: '', online: true));
      expect(find.text('未设置昵称'), findsOneWidget);
      expect(find.text('编辑资料'), findsWidgets);
    });

    testWidgets('显示昵称、注册时间与头像地址', (tester) async {
      await mount(
        tester,
        profile: (
          nickname: '阿澈',
          avatar: 'https://example.com/a.png',
          createdAt: 1700000000,
          inviteCode: 'ABCD2345EFGH',
          online: true,
        ),
      );
      expect(find.text('阿澈'), findsOneWidget);
      expect(find.textContaining('注册时间'), findsOneWidget);
      expect(find.text('https://example.com/a.png'), findsOneWidget);
      expect(find.textContaining('离线：显示的是本机缓存'), findsNothing);
    });

    testWidgets('离线时明确标注显示的是缓存', (tester) async {
      await mount(
        tester,
        profile: (nickname: '阿澈', avatar: '', createdAt: 0, inviteCode: '', online: false),
      );
      // 页面上别处也可能出现「离线」字样，这里只认资料行自己的提示。
      expect(find.textContaining('昵称 · 离线：显示的是本机缓存'), findsOneWidget,
          reason: '不能把缓存当成最新值展示');
    });

    testWidgets('资料未加载时不崩，给出占位', (tester) async {
      await mount(tester);
      expect(find.text('未设置昵称'), findsOneWidget);
    });
  });

  group('VaultApi.log 的健壮性', () {
    test('桥不可用时写日志不抛异常', () {
      // 调用点经常在 catch 里：写日志自己抛异常会把原始错误盖掉。
      expect(() => VaultApi.log('x', level: 'warn'), returnsNormally);
    });
  });

  group('邀请码展示与填写（§9）', () {
    Future<void> mount(WidgetTester tester, {AccountProfile? profile}) async {
      final state = AppState()..phase = AppPhase.unlocked..privacyAccepted = true;
      state.profile = profile;
      addTearDown(state.dispose);
      tester.view.physicalSize = const Size(1000, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        state: state,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const Scaffold(body: SettingsPage(initialSection: SettingsSection.account)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('有邀请码时展示出来，复制按钮可用', (tester) async {
      await mount(
        tester,
        profile: (nickname: '', avatar: '', createdAt: 0, inviteCode: 'ABCD2345EFGH', online: true),
      );
      expect(find.text('ABCD2345EFGH'), findsOneWidget);
      expect(find.text('尚未生成'), findsNothing);
      expect(
        tester
            .widget<ZoIconButton>(find.ancestor(
              of: find.byTooltip('复制邀请码'),
              matching: find.byType(ZoIconButton),
            ))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('没有邀请码时给出占位，复制按钮禁用', (tester) async {
      await mount(
        tester,
        profile: (nickname: '', avatar: '', createdAt: 0, inviteCode: '', online: true),
      );
      expect(find.text('尚未生成'), findsOneWidget);
      expect(
        tester
            .widget<ZoIconButton>(find.ancestor(
              of: find.byTooltip('复制邀请码'),
              matching: find.byType(ZoIconButton),
            ))
            .onPressed,
        isNull,
        reason: '没有码可复制时按钮不该能点',
      );
    });

    testWidgets('填写邀请码的对话框说明一次性不可更改', (tester) async {
      await mount(
        tester,
        profile: (nickname: '', avatar: '', createdAt: 0, inviteCode: 'ABCD2345EFGH', online: true),
      );
      await tester.tap(find.text('填写邀请码'));
      await tester.pumpAndSettle();
      expect(find.text('填写邀请人的邀请码'), findsOneWidget);
      expect(find.text('一次性绑定，绑定后不可更改。'), findsOneWidget, reason: '不可逆操作要提前说清');
    });
  });
}
