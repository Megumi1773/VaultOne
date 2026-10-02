import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/health_models.dart';
import 'package:vaultone/src/core/models.dart';
import 'package:vaultone/src/ui/screens/security_page.dart';
import 'package:vaultone/src/ui/screens/settings_page.dart' show SettingsSection;
import 'package:vaultone/src/ui/theme.dart';

/// 一份与内核输出形态一致的报告：一个被跳过的维度 + 三条发现项。
HealthReport _report({int score = 64}) => HealthReport(      score: score,
      checkedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      dimensions: const [
        DimensionScore(dimension: HealthDimension.breach, cap: 50, deduction: 0, skipped: true),
        DimensionScore(dimension: HealthDimension.weak, cap: 24, deduction: 6, skipped: false),
        DimensionScore(dimension: HealthDimension.reuse, cap: 20, deduction: 0, skipped: false),
        DimensionScore(dimension: HealthDimension.stale, cap: 15, deduction: 0, skipped: false),
        DimensionScore(dimension: HealthDimension.environment, cap: 30, deduction: 30, skipped: false),
        DimensionScore(dimension: HealthDimension.settings, cap: 30, deduction: 0, skipped: false),
      ],
      findings: const [
        Finding(
          id: 'environment.debugger',
          category: FindingCategory.environment,
          severity: Severity.critical,
          title: '检测到调试器',
          description: '有调试器附着在本应用上。',
          action: FindingAction.systemSettings,
        ),
        Finding(
          id: 'vault.weak',
          category: FindingCategory.vault,
          severity: Severity.high,
          title: '存在弱密码',
          description: '这些密码容易被猜测。',
          action: FindingAction.openItem,
          itemIds: ['a'],
          count: 1,
        ),
        Finding(
          id: 'breach.notRun',
          category: FindingCategory.breach,
          severity: Severity.medium,
          title: '尚未运行泄露检测',
          description: '运行后才能发现已泄露的密码。',
          action: FindingAction.openCheckup,
        ),
      ],
      scannedPasswords: 3,
      passwordFields: 3,
      unreadableItems: 2,
      breachStatus: BreachStatus.notRun,
    );

VaultItem _item(String id, String title) => VaultItem(
      id: id,
      vaultId: 'v',
      revision: 1,
      data: ItemData(kind: ItemKind.login, title: title),
    );

/// 任务清单样例：一条已完成、一条未完成（指向解锁与安全分区）。
List<ChecklistItem> _checklist() => const [
      ChecklistItem(
        id: 'task.autoLock',
        title: '启用自动锁定',
        description: '无操作一段时间后自动锁定保险库。',
        done: true,
        action: FindingAction.autoLock,
      ),
      ChecklistItem(
        id: 'task.noWeak',
        title: '没有弱密码',
        description: '容易被猜测的密码需要更换。',
        done: false,
        action: FindingAction.openCheckup,
      ),
    ];

class _Harness {
  _Harness({HealthReport? report, List<ChecklistItem>? checklist})
      : overview = HealthOverview(report: report ?? _report(), checklist: checklist ?? _checklist());

  HealthOverview overview;
  int runs = 0;
  int breachRuns = 0;
  final opened = <String>[];
  final saved = <List<Snooze>>[];
  List<Snooze> snoozes = const [];

  Future<HealthOverview> runCheckup({required bool withBreachCheck}) async {
    runs++;
    if (withBreachCheck) breachRuns++;
    return overview;
  }

  Future<List<Snooze>> loadSnoozes() async => snoozes;
  Future<void> saveSnoozes(List<Snooze> s) async {
    snoozes = s;
    saved.add(s);
  }
}

Future<_Harness> _mount(
  WidgetTester tester, {
  HealthReport? report,
  List<ChecklistItem>? checklist,
  void Function(SettingsSection?)? onOpenSettings,
  List<VaultItem>? items,
  _Harness? harness,
}) async {
  final h = harness ?? _Harness(report: report, checklist: checklist);
  // 页面是长列表，默认 800×600 视口只会构建首屏；放大视口让全部内容都进入构建，
  // 否则断言「发现项存在」会因懒构建而假失败。
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SecurityPage(
          items: items ?? [_item('a', 'GitHub')],
          settings: const {},
          runCheckup: h.runCheckup,
          loadSnoozes: h.loadSnoozes,
          saveSnoozes: h.saveSnoozes,
          onOpenItem: h.opened.add,
          onOpenSettings: onOpenSettings,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('展示总分、六个维度与发现项', (tester) async {
    await _mount(tester);
    expect(find.text('64'), findsOneWidget, reason: '总分');
    for (final label in ['泄露', '弱密码', '密码复用', '长期未更新', '设备环境', '设置项']) {
      expect(find.text(label), findsOneWidget, reason: '维度「$label」应展示');
    }
    expect(find.text('检测到调试器'), findsOneWidget);
    expect(find.text('存在弱密码'), findsOneWidget);
    expect(find.text('尚未运行泄露检测'), findsOneWidget);
    // 严重度标签
    expect(find.text('严重风险'), findsOneWidget);
    expect(find.text('高危'), findsOneWidget);
  });

  testWidgets('被跳过的维度明确标注，不让人误以为没问题', (tester) async {
    await _mount(tester);
    // 只有泄露维度被跳过。
    expect(find.text('本次跳过'), findsOneWidget);
  });

  testWidgets('不可读条目如实展示，不假装扫描完整', (tester) async {
    await _mount(tester);
    // 统计格与顶部标签都会出现，两处都算命中。
    expect(find.textContaining('不可读条目'), findsWidgets);
    expect(find.text('2'), findsWidgets);
  });

  testWidgets('忽略一条发现项会隐藏它并持久化', (tester) async {
    final h = await _mount(tester);
    expect(find.text('存在弱密码'), findsOneWidget);

    // 第二张卡片（弱密码）上的「忽略 7 天」。
    final snoozeButtons = find.text('忽略 7 天');
    expect(snoozeButtons, findsNWidgets(3));
    await tester.tap(snoozeButtons.at(1));
    await tester.pumpAndSettle();

    expect(find.text('存在弱密码'), findsNothing, reason: '被忽略的发现项应隐藏');
    expect(find.text('检测到调试器'), findsOneWidget, reason: '其他发现项不受影响');
    expect(h.saved, hasLength(1));
    expect(h.saved.single.single.findingId, 'vault.weak');
    expect(h.saved.single.single.isActive(DateTime.now().millisecondsSinceEpoch ~/ 1000), isTrue);
  });

  testWidgets('忽略后可以一键全部恢复', (tester) async {
    final h = await _mount(tester);
    h.snoozes = [
      Snooze(findingId: 'vault.weak', until: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600),
    ];
    // 先用占位组件卸载页面，再用同一个 harness 重新挂载：否则 Flutter 会复用
    // 原来的 State，`initState` 不再执行，读不到已有的忽略记录。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await _mount(tester, harness: h);
    expect(find.text('存在弱密码'), findsNothing);

    await tester.tap(find.textContaining('已忽略'));
    await tester.pumpAndSettle();
    expect(find.text('存在弱密码'), findsOneWidget, reason: '恢复后应重新显示');
    expect(h.saved, isNotEmpty);
    expect(h.saved.last, isEmpty, reason: '恢复即清空忽略记录');
    expect(find.textContaining('已忽略'), findsNothing, reason: '没有忽略项时不再显示该入口');
  });

  testWidgets('打开条目动作回调正确的条目 ID', (tester) async {
    final h = await _mount(tester);
    await tester.tap(find.text('打开条目'));
    await tester.pumpAndSettle();
    expect(h.opened, ['a']);
  });

  testWidgets('去运行会再跑一次体检并带泄露检测', (tester) async {
    final h = await _mount(tester);
    expect(h.runs, 1, reason: '进入页面先跑一次');
    expect(h.breachRuns, 0, reason: '首次不联网');

    // 「去运行」同时出现在泄露提示与未完成的密码类任务上，取第一个即可。
    await tester.tap(find.text('去运行').first);
    await tester.pumpAndSettle();
    expect(h.runs, 2);
    expect(h.breachRuns, 1, reason: '「去运行」应触发 k-匿名泄露查询');
  });

  testWidgets('设置类动作跳到设置页的对应分区', (tester) async {
    final targets = <SettingsSection?>[];
    await _mount(tester, onOpenSettings: targets.add);
    // 「检测到调试器」的动作是系统设置：应用内没有对应分区，停在设置页顶部。
    await tester.tap(find.text('打开系统设置'));
    await tester.pumpAndSettle();
    expect(targets, [null]);

    // 任务清单里的「启用自动锁定」已完成，没有按钮；未完成的「没有弱密码」应指向体检详情。
    expect(find.text('已完成 1 / 2'), findsOneWidget);
  });

  testWidgets('宫格入口按分区跳转，不把用户丢在设置页顶部', (tester) async {
    final targets = <SettingsSection?>[];
    await _mount(tester, onOpenSettings: targets.add);
    expect(find.text('快捷入口'), findsOneWidget);

    await tester.tap(find.text('设备管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('密钥与备份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动填充'));
    await tester.pumpAndSettle();
    expect(targets, [SettingsSection.sync, SettingsSection.keyBackup, SettingsSection.browser]);
  });

  testWidgets('任务清单的完成态与动作来自内核，未完成项才给按钮', (tester) async {
    final h = await _mount(tester);
    expect(find.text('启用自动锁定'), findsOneWidget);
    expect(find.text('没有弱密码'), findsOneWidget);
    expect(find.text('已完成 1 / 2'), findsOneWidget);
    // 已完成项不给按钮：留一个「去设置」只会让人以为还有事没做。
    // 「自动锁定」这个精确文案只出现在宫格里；任务清单里那一条的标题是「启用自动锁定」，
    // 因此这里为 1 就说明它没渲染出动作按钮。
    expect(find.text('自动锁定'), findsOneWidget, reason: '已完成项不出现动作按钮');

    final before = h.runs;
    await tester.tap(find.text('去运行').first);
    await tester.pumpAndSettle();
    expect(h.runs, before + 1, reason: '未完成的密码类任务应重新跑体检');
  });

  testWidgets('没有发现项时给出空态而不是空白', (tester) async {
    final clean = HealthReport(
      score: 100,
      checkedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      dimensions: const [DimensionScore(dimension: HealthDimension.weak, cap: 24, deduction: 0, skipped: false)],
      findings: const [],
      scannedPasswords: 1,
      passwordFields: 1,
      unreadableItems: 0,
      breachStatus: BreachStatus.ok,
    );
    await _mount(tester, report: clean);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('没有风险项。'), findsOneWidget);
  });

  testWidgets('报告过期时给出提示', (tester) async {
    final stale = HealthReport(
      score: 80,
      checkedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 25 * 60 * 60,
      dimensions: const [DimensionScore(dimension: HealthDimension.weak, cap: 24, deduction: 0, skipped: false)],
      findings: const [],
      scannedPasswords: 1,
      passwordFields: 1,
      unreadableItems: 0,
      breachStatus: BreachStatus.ok,
    );
    await _mount(tester, report: stale);
    expect(find.textContaining('报告已过期'), findsOneWidget);
  });

  testWidgets('发现项可下钻展开关联条目并跳转', (tester) async {
    final h = await _mount(tester, items: [_item('a', 'GitHub'), _item('b', 'GitLab')]);
    // 展开「存在弱密码」（有 1 个关联条目）。
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();
    expect(find.text('GitHub'), findsOneWidget, reason: '下钻应列出关联条目');

    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(h.opened, ['a']);
  });
}
