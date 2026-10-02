import 'package:flutter_test/flutter_test.dart';
import 'package:vaultone/src/core/health_models.dart';

/// 一份与内核 `vault_core::health` 输出形态一致的样例报告。
/// 打分口径不在 Dart 侧重算，这里只验证解析与展示辅助。
const _raw = {
  'score': 76,
  'checkedAt': 1000,
  'dimensions': [
    {'dimension': 'breach', 'cap': 50, 'deduction': 0, 'skipped': true},
    {'dimension': 'weak', 'cap': 24, 'deduction': 6, 'skipped': false},
    {'dimension': 'reuse', 'cap': 20, 'deduction': 0, 'skipped': false},
    {'dimension': 'stale', 'cap': 15, 'deduction': 0, 'skipped': false},
    {'dimension': 'environment', 'cap': 30, 'deduction': 18, 'skipped': false},
    {'dimension': 'settings', 'cap': 30, 'deduction': 0, 'skipped': false},
  ],
  'findings': [
    {
      'id': 'environment.debugger',
      'category': 'environment',
      'severity': 'critical',
      'title': '检测到调试器',
      'description': '有调试器附着在本应用上。',
      'action': 'systemSettings',
      'itemIds': <String>[],
      'count': 1,
    },
    {
      'id': 'vault.weak',
      'category': 'vault',
      'severity': 'high',
      'title': '存在弱密码',
      'description': '这些密码容易被猜测。',
      'action': 'openItem',
      'itemIds': ['a', 'b'],
      'count': 2,
    },
    {
      'id': 'breach.notRun',
      'category': 'breach',
      'severity': 'medium',
      'title': '尚未运行泄露检测',
      'description': '运行后才能发现已泄露的密码。',
      'action': 'openCheckup',
      'itemIds': <String>[],
      'count': 0,
    },
  ],
  'scannedPasswords': 3,
  'passwordFields': 3,
  'unreadableItems': 1,
  'breachStatus': 'notRun',
};

void main() {
  test('报告与各字段解析正确', () {
    final r = HealthReport.fromJson(_raw.cast());
    expect(r.score, 76);
    expect(r.checkedAt, 1000);
    expect(r.dimensions, hasLength(6));
    expect(r.findings, hasLength(3));
    expect(r.scannedPasswords, 3);
    expect(r.unreadableItems, 1, reason: '不可读条目如实展示，不假装扫描完整');
    expect(r.breachStatus, BreachStatus.notRun);

    final weak = r.dimensions.firstWhere((d) => d.dimension == HealthDimension.weak);
    expect(weak.cap, 24);
    expect(weak.deduction, 6);
    expect(weak.skipped, isFalse);

    final breach = r.dimensions.firstWhere((d) => d.dimension == HealthDimension.breach);
    expect(breach.skipped, isTrue, reason: '未运行泄露检测时该维度应标记跳过');
  });

  test('枚举按 wire 值解析，未知值回退默认而不是抛错', () {
    expect(HealthDimension.parse('stale'), HealthDimension.stale);
    expect(HealthDimension.parse('nope'), HealthDimension.breach);
    expect(FindingCategory.parse('breach'), FindingCategory.breach);
    expect(FindingCategory.parse(null), FindingCategory.vault);
    expect(Severity.parse('critical'), Severity.critical);
    expect(Severity.parse('nope'), Severity.low);
    expect(FindingAction.parse('openItem'), FindingAction.openItem);
    expect(FindingAction.parse(null), FindingAction.none);
  });

  test('发现项保留关联条目与动作', () {
    final r = HealthReport.fromJson(_raw.cast());
    final weak = r.findings.firstWhere((f) => f.id == 'vault.weak');
    expect(weak.itemIds, ['a', 'b']);
    expect(weak.count, 2);
    expect(weak.action, FindingAction.openItem);
    expect(weak.severity, Severity.high);

    final debug = r.findings.firstWhere((f) => f.id == 'environment.debugger');
    expect(debug.itemIds, isEmpty);
    expect(debug.category, FindingCategory.environment);
  });

  test('严重度按声明顺序可用于排序', () {
    expect(Severity.low.index, lessThan(Severity.medium.index));
    expect(Severity.medium.index, lessThan(Severity.high.index));
    expect(Severity.high.index, lessThan(Severity.critical.index));
  });

  test('报告超过 24 小时视为过期', () {
    final r = HealthReport.fromJson(_raw.cast());
    const day = 24 * 60 * 60;
    expect(r.isStale(1000), isFalse);
    expect(r.isStale(1000 + day), isFalse, reason: '正好 24 小时还不算过期');
    expect(r.isStale(1000 + day + 1), isTrue);
  });

  test('忽略只影响提示，不影响分数', () {
    final r = HealthReport.fromJson(_raw.cast());
    expect(r.activeFindings(const [], 2000), hasLength(3));

    const snoozes = [Snooze(findingId: 'vault.weak', until: 3000)];
    final active = r.activeFindings(snoozes, 2000);
    expect(active.map((f) => f.id), isNot(contains('vault.weak')));
    expect(active, hasLength(2));
    expect(r.score, 76, reason: '忽略只是暂时不提示，分数是事实');
  });

  test('忽略到期后重新出现，且不误伤其他发现项', () {
    final r = HealthReport.fromJson(_raw.cast());
    const snoozes = [
      Snooze(findingId: 'vault.weak', until: 3000),
      Snooze(findingId: 'breach.notRun', until: 1500),
    ];
    // 3000 之后全部到期。
    expect(r.activeFindings(snoozes, 3001), hasLength(3));
    // 2000 时只有 weak 仍在忽略期。
    final ids = r.activeFindings(snoozes, 2000).map((f) => f.id).toList();
    expect(ids, isNot(contains('vault.weak')));
    expect(ids, contains('breach.notRun'));
  });

  test('Snooze 可往返 JSON', () {
    const s = Snooze(findingId: 'vault.weak', until: 3000);
    expect(Snooze.fromJson(s.toJson()).findingId, 'vault.weak');
    expect(Snooze.fromJson(s.toJson()).until, 3000);
    expect(s.isActive(2999), isTrue);
    expect(s.isActive(3000), isFalse, reason: '到期时刻即失效');
  });

  test('缺字段的载荷按空值与 0 容错，不抛错', () {
    final r = HealthReport.fromJson(const {'score': 100});
    expect(r.score, 100);
    expect(r.dimensions, isEmpty);
    expect(r.findings, isEmpty);
    expect(r.breachStatus, BreachStatus.notRun);
    expect(r.unreadableItems, 0);
  });

  test('HealthOverview 一次解析报告与任务清单', () {
    final o = HealthOverview.fromJson({
      'report': _raw,
      'checklist': [
        {
          'id': 'task.autoLock',
          'title': '启用自动锁定',
          'description': '无操作一段时间后锁定。',
          'done': true,
          'action': 'autoLock',
        },
        {
          'id': 'task.noWeak',
          'title': '没有弱密码',
          'description': '容易被猜测的密码需要更换。',
          'done': false,
          'action': 'openCheckup',
        },
      ],
    });
    expect(o.report.score, 76);
    expect(o.checklist, hasLength(2));
    expect(o.doneCount, 1);
    expect(o.allDone, isFalse);
    expect(o.checklist.first.id, 'task.autoLock');
    expect(o.checklist.first.done, isTrue);
    expect(o.checklist.first.action, FindingAction.autoLock);
    expect(o.checklist.last.action, FindingAction.openCheckup);
  });

  test('HealthOverview 全完成时 allDone 为真；缺字段时按空处理', () {
    final done = HealthOverview.fromJson(const {
      'report': {'score': 100},
      'checklist': [
        {'id': 'a', 'title': 't', 'description': 'd', 'done': true, 'action': 'none'},
      ],
    });
    expect(done.doneCount, 1);
    expect(done.allDone, isTrue);

    final empty = HealthOverview.fromJson(const {});
    expect(empty.report.score, 0);
    expect(empty.checklist, isEmpty);
    expect(empty.allDone, isTrue, reason: '空清单视为没有待办');
  });
}
