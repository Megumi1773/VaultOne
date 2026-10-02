/// 安全体检（计划书 §5.2）的模型。与内核 `vault_core::health` 的 JSON 形态一一对应。
///
/// 打分与发现项规则**只在内核实现一处**（`crates/vault-core/src/health.rs`），
/// 这里只做反序列化与展示辅助，不重复任何扣分口径。
library;

/// 体检维度。每个维度有独立扣分上限。
enum HealthDimension {
  breach('breach'),
  weak('weak'),
  reuse('reuse'),
  stale('stale'),
  environment('environment'),
  settings('settings');

  const HealthDimension(this.wire);

  final String wire;

  static HealthDimension parse(String? value) =>
      HealthDimension.values.firstWhere((d) => d.wire == value, orElse: () => HealthDimension.breach);
}

/// 发现项分类。
enum FindingCategory {
  vault('vault'),
  breach('breach'),
  environment('environment'),
  settings('settings');

  const FindingCategory(this.wire);

  final String wire;

  static FindingCategory parse(String? value) =>
      FindingCategory.values.firstWhere((c) => c.wire == value, orElse: () => FindingCategory.vault);
}

/// 发现项严重度。声明顺序即排序权重（低 → 严重）。
enum Severity {
  low('low'),
  medium('medium'),
  high('high'),
  critical('critical');

  const Severity(this.wire);

  final String wire;

  static Severity parse(String? value) =>
      Severity.values.firstWhere((s) => s.wire == value, orElse: () => Severity.low);
}

/// 发现项可执行的动作。不带参数；需要跳转条目时用 `Finding.itemIds.first`。
enum FindingAction {
  none('none'),
  openItem('openItem'),
  openCheckup('openCheckup'),
  biometrics('biometrics'),
  autoLock('autoLock'),
  autofill('autofill'),
  privateKey('privateKey'),
  generalSettings('generalSettings'),
  systemSettings('systemSettings');

  const FindingAction(this.wire);

  final String wire;

  static FindingAction parse(String? value) =>
      FindingAction.values.firstWhere((a) => a.wire == value, orElse: () => FindingAction.none);
}

/// 泄露检测状态。
enum BreachStatus {
  notRun('notRun'),
  ok('ok'),
  unavailable('unavailable'),
  skipped('skipped');

  const BreachStatus(this.wire);

  final String wire;
}

/// 单个维度的得分情况。
class DimensionScore {
  const DimensionScore({
    required this.dimension,
    required this.cap,
    required this.deduction,
    required this.skipped,
  });

  factory DimensionScore.fromJson(Map<String, dynamic> j) => DimensionScore(
        dimension: HealthDimension.parse(j['dimension'] as String?),
        cap: (j['cap'] as num?)?.toInt() ?? 0,
        deduction: (j['deduction'] as num?)?.toInt() ?? 0,
        skipped: j['skipped'] == true,
      );

  final HealthDimension dimension;

  /// 该维度的扣分上限。
  final int cap;

  /// 本次实际扣分。
  final int deduction;

  /// 该维度本次是否被跳过（平台不支持探测、泄露检测未运行、用户主动跳过）。
  final bool skipped;
}

/// 一条发现项。
class Finding {
  const Finding({
    required this.id,
    required this.category,
    required this.severity,
    required this.title,
    required this.description,
    required this.action,
    this.itemIds = const [],
    this.count = 0,
  });

  factory Finding.fromJson(Map<String, dynamic> j) => Finding(
        id: j['id'] as String? ?? '',
        category: FindingCategory.parse(j['category'] as String?),
        severity: Severity.parse(j['severity'] as String?),
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        action: FindingAction.parse(j['action'] as String?),
        itemIds: [for (final i in (j['itemIds'] as List? ?? const [])) i as String],
        count: (j['count'] as num?)?.toInt() ?? 0,
      );

  /// 稳定 id：同一条问题在多次体检之间保持不变，忽略（snooze）因此能跨次生效。
  final String id;
  final FindingCategory category;
  final Severity severity;
  final String title;
  final String description;
  final FindingAction action;
  final List<String> itemIds;

  /// 命中数量（条目数或问题项数）。
  final int count;
}

/// 一次体检的完整报告。
class HealthReport {
  const HealthReport({
    required this.score,
    required this.checkedAt,
    required this.dimensions,
    required this.findings,
    required this.scannedPasswords,
    required this.passwordFields,
    required this.unreadableItems,
    required this.breachStatus,
  });

  factory HealthReport.fromJson(Map<String, dynamic> j) => HealthReport(
        score: (j['score'] as num?)?.toInt() ?? 0,
        checkedAt: (j['checkedAt'] as num?)?.toInt() ?? 0,
        dimensions: [
          for (final d in (j['dimensions'] as List? ?? const []))
            DimensionScore.fromJson((d as Map).cast()),
        ],
        findings: [
          for (final f in (j['findings'] as List? ?? const [])) Finding.fromJson((f as Map).cast()),
        ],
        scannedPasswords: (j['scannedPasswords'] as num?)?.toInt() ?? 0,
        passwordFields: (j['passwordFields'] as num?)?.toInt() ?? 0,
        unreadableItems: (j['unreadableItems'] as num?)?.toInt() ?? 0,
        breachStatus: BreachStatus.values.firstWhere(
          (s) => s.wire == j['breachStatus'],
          orElse: () => BreachStatus.notRun,
        ),
      );

  /// 0–100。
  final int score;
  final int checkedAt;
  final List<DimensionScore> dimensions;
  final List<Finding> findings;

  /// 已扫描的密码条数。
  final int scannedPasswords;

  /// 密码字段总数。
  final int passwordFields;

  /// 解密失败、未能纳入扫描的条目数。
  final int unreadableItems;

  final BreachStatus breachStatus;

  /// 报告是否已过期（超过 24 小时）。
  bool isStale(int now) => now - checkedAt > 24 * 60 * 60;

  /// 过滤掉仍在忽略期内的发现项。
  ///
  /// 忽略不影响分数——分数是事实，忽略只是暂时不提示。
  List<Finding> activeFindings(List<Snooze> snoozes, int now) => [
        for (final f in findings)
          if (!snoozes.any((s) => s.findingId == f.id && s.isActive(now))) f,
      ];
}

/// 忽略一条发现项直到某个时刻。
class Snooze {
  const Snooze({required this.findingId, required this.until});

  factory Snooze.fromJson(Map<String, dynamic> j) => Snooze(
        findingId: j['findingId'] as String? ?? '',
        until: (j['until'] as num?)?.toInt() ?? 0,
      );

  final String findingId;

  /// 忽略到期时间（Unix 秒）。
  final int until;

  bool isActive(int now) => until > now;

  Map<String, Object?> toJson() => {'findingId': findingId, 'until': until};
}

/// 安全总览（计划书 §5.1）的任务清单项。
class ChecklistItem {
  const ChecklistItem({
    required this.id,
    required this.title,
    required this.description,
    required this.done,
    required this.action,
  });

  factory ChecklistItem.fromJson(Map<String, dynamic> j) => ChecklistItem(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        done: j['done'] == true,
        action: FindingAction.parse(j['action'] as String?),
      );

  /// 稳定 id，界面据此做跳转与测试断言。
  final String id;
  final String title;
  final String description;
  final bool done;
  final FindingAction action;
}

/// 一次体检的完整结果：健康报告 + 任务清单。
///
/// 两者由内核**同一次调用一起算出**（同一份设置快照），所以不会出现「报告用旧值、
/// 清单用新值」的不一致。
class HealthOverview {
  const HealthOverview({required this.report, required this.checklist});

  factory HealthOverview.fromJson(Map<String, dynamic> j) => HealthOverview(
        report: HealthReport.fromJson(((j['report'] as Map?) ?? const {}).cast()),
        checklist: [
          for (final t in (j['checklist'] as List? ?? const []))
            ChecklistItem.fromJson((t as Map).cast()),
        ],
      );

  final HealthReport report;
  final List<ChecklistItem> checklist;

  /// 已完成的任务数。
  int get doneCount => checklist.where((t) => t.done).length;

  /// 是否全部完成。
  bool get allDone => checklist.every((t) => t.done);
}

