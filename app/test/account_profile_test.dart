import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/api.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/state/scope.dart';
import 'package:vaultone/src/ui/screens/settings_page.dart';
import 'package:vaultone/src/ui/theme.dart';

void main() {
  group('AccountProfile 解析', () {
    test('缺字段按默认值处理', () {
      final p = accountProfileFromJson(const {});
      expect(p.nickname, '');
      expect(p.avatar, '');
      expect(p.createdAt, 0);
      expect(p.online, isFalse, reason: '没明说在线就按离线处理，界面会提示缓存');
    });

    test('完整字段正常解析', () {
      final p = accountProfileFromJson(const {
        'nickname': '阿澈',
        'avatar': 'https://example.com/a.png',
        'createdAt': 1700000000,
        'online': true,
      });
      expect(p.nickname, '阿澈');
      expect(p.avatar, 'https://example.com/a.png');
      expect(p.createdAt, 1700000000);
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
      await mount(tester, profile: (nickname: '', avatar: '', createdAt: 0, online: true));
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
        profile: (nickname: '阿澈', avatar: '', createdAt: 0, online: false),
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
}
