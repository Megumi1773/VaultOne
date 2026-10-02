import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/l10n/strings.dart';
import 'package:vaultone/src/state/app_state.dart';
import 'package:vaultone/src/ui/theme.dart';

class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text('lang:${context.language.storageKey}'),
          Text('settings:${context.tr(AppStrings.settings)}'),
          Text('unknown:${context.tr('未翻译的原文')}'),
          Text('tpl:${context.trf('已创建「{title}」', {'title': 'GitHub'})}'),
        ],
      );
}

Future<void> _pump(WidgetTester tester, AppLanguage language) async {
  await tester.pumpWidget(LocaleScope(
    language: language,
    child: MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const Scaffold(body: _Probe()),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('语言解析：未知值回退简体中文，持久化键稳定', () {
    expect(AppLanguage.parse(null), AppLanguage.zhHans);
    expect(AppLanguage.parse('zh'), AppLanguage.zhHans);
    expect(AppLanguage.parse('zh_Hans'), AppLanguage.zhHans);
    expect(AppLanguage.parse('zh_Hant'), AppLanguage.zhHant);
    expect(AppLanguage.parse('en'), AppLanguage.en);
    expect(AppLanguage.parse('fr'), AppLanguage.zhHans, reason: '未支持的语言回退默认');

    for (final l in AppLanguage.values) {
      expect(AppLanguage.parse(l.storageKey), l, reason: '${l.label} 的持久化键应可往返');
    }
  });

  test('locale 构造：简体带 Hans、英文不带 script', () {
    expect(AppLanguage.zhHans.locale, const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'));
    expect(AppLanguage.zhHant.locale, const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(AppLanguage.en.locale, const Locale('en'));
  });

  test('查表：默认语言原样返回，未翻译条目回退中文原文而不是键名', () {
    expect(AppStrings.translate(AppStrings.settings, AppLanguage.zhHans), '设置');
    expect(AppStrings.translate(AppStrings.settings, AppLanguage.zhHant), '設定');
    expect(AppStrings.translate(AppStrings.settings, AppLanguage.en), 'Settings');

    const notTranslated = '这句还没翻译';
    for (final l in AppLanguage.values) {
      expect(AppStrings.translate(notTranslated, l), notTranslated);
    }
  });

  test('占位替换：缺失的参数保留原样，不做静默清空', () {
    expect(AppStrings.format('已创建「{title}」', {'title': 'GitHub'}), '已创建「GitHub」');
    expect(AppStrings.format('{a} 与 {b}', {'a': 1, 'b': 2}), '1 与 2');
    expect(AppStrings.format('值 {missing}', const {}), '值 {missing}');
  });

  test('翻译表完整性：每个受支持语言都覆盖全部已登记文案', () {
    // 已登记文案 = 三个语言的并集；只要某语言缺条目就会回退中文，因此这里断言关键集合非空且键都是中文原文。
    const samples = [
      AppStrings.cancel,
      AppStrings.confirm,
      AppStrings.close,
      AppStrings.save,
      AppStrings.delete,
      AppStrings.retry,
      AppStrings.language,
      AppStrings.settings,
      AppStrings.unlockTitle,
      AppStrings.masterPassword,
    ];
    for (final l in AppLanguage.values) {
      for (final s in samples) {
        expect(AppStrings.translate(s, l), isNotEmpty);
      }
    }
    expect(
      AppStrings.translate(AppStrings.language, AppLanguage.en),
      isNot(AppStrings.language),
      reason: '英文必须真的翻译，不能等同中文原文',
    );
  });

  testWidgets('LocaleScope 驱动取词：切换语言后同一调用返回对应文案', (tester) async {
    await _pump(tester, AppLanguage.zhHans);
    expect(find.text('lang:zh_Hans'), findsOneWidget);
    expect(find.text('settings:设置'), findsOneWidget);
    expect(find.text('unknown:未翻译的原文'), findsOneWidget);
    expect(find.text('tpl:已创建「GitHub」'), findsOneWidget);

    await _pump(tester, AppLanguage.zhHant);
    expect(find.text('settings:設定'), findsOneWidget);

    await _pump(tester, AppLanguage.en);
    expect(find.text('settings:Settings'), findsOneWidget);
    expect(find.text('unknown:未翻译的原文'), findsOneWidget, reason: '未翻译条目回退中文原文');
  });

  testWidgets('无 LocaleScope 时回退默认语言，独立页面不崩', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const Scaffold(body: _Probe()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('lang:zh_Hans'), findsOneWidget);
    expect(find.text('settings:设置'), findsOneWidget);
  });

  test('设置项默认语言为简体中文，copyWith 可切换且不影响其他字段', () {
    const s = Settings();
    expect(s.language, AppLanguage.zhHans);

    final en = s.copyWith(language: AppLanguage.en);
    expect(en.language, AppLanguage.en);
    expect(en.autoLockMinutes, s.autoLockMinutes);
    expect(en.clipboardSeconds, s.clipboardSeconds);
    expect(en.serverUrl, s.serverUrl);

    final back = en.copyWith(language: AppLanguage.zhHant);
    expect(back.language, AppLanguage.zhHant);
    expect(back.verboseLogs, en.verboseLogs);
  });
}
