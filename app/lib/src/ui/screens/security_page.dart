import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ffi.dart';
import '../../core/health_models.dart';
import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/controls.dart';

/// 忽略时长：7 天。够长到不打扰，又短到不会把问题永久埋掉。
const int _snoozeSeconds = 7 * 24 * 60 * 60;

/// 跑一次体检并返回报告。`withBreachCheck` 为真时先做 k-匿名泄露查询（会联网）。
typedef HealthRunner = Future<HealthReport> Function({required bool withBreachCheck});

/// 安全体检（计划书 §5.2）。
///
/// 打分与发现项规则**只在内核实现一处**（`crates/vault-core/src/health.rs`），
/// 本页只负责收集输入、展示报告与执行动作，不在 Dart 侧重算任何扣分口径。
///
/// 依赖全部由外部注入（沿用本仓库其他页面的做法）：页面因此可以脱离全局单例单测，
/// 不必启动真实保险库。
class SecurityPage extends StatefulWidget {
  const SecurityPage({
    super.key,
    required this.items,
    required this.settings,
    required this.runCheckup,
    required this.loadSnoozes,
    required this.saveSnoozes,
    required this.onOpenItem,
    this.onOpenSettings,
  });

  /// 当前条目，用于发现项下钻时显示关联条目标题。
  final List<VaultItem> items;

  /// 安全设置快照，直接交给内核的「设置项」维度。
  final Map<String, Object?> settings;

  final HealthRunner runCheckup;
  final Future<List<Snooze>> Function() loadSnoozes;
  final Future<void> Function(List<Snooze> snoozes) saveSnoozes;
  final ValueChanged<String> onOpenItem;

  /// 发现项需要用户去改设置时调用（打开设置页）。
  final VoidCallback? onOpenSettings;

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  HealthReport? _report;
  List<Snooze> _snoozes = const [];
  bool _busy = false;
  String? _error;
  String? _expanded;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _loadSnoozes();
    await _run();
  }

  Future<void> _loadSnoozes() async {
    try {
      final loaded = await widget.loadSnoozes();
      if (mounted) setState(() => _snoozes = loaded);
    } on CoreException {
      // 忽略记录读不出来不影响体检本身，按「没有忽略项」继续。
    }
  }

  Future<void> _persistSnoozes() async {
    try {
      await widget.saveSnoozes(_snoozes);
    } on CoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _run({bool withBreachCheck = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.runCheckup(withBreachCheck: withBreachCheck);
      if (mounted) setState(() => _report = report);
    } on CoreException catch (e) {
      // 页面可能在体检返回前被全局锁定销毁，不再展示旧会话结果。
      if (mounted && e.code != 'session_expired') {
        setState(() => _error = context.trf(AppStrings.auditFailed, {'reason': e.message}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snooze(Finding f) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    setState(() {
      _snoozes = [
        ..._snoozes.where((s) => s.findingId != f.id),
        Snooze(findingId: f.id, until: now + _snoozeSeconds),
      ];
    });
    _persistSnoozes();
  }

  void _unsnoozeAll() {
    setState(() => _snoozes = const []);
    _persistSnoozes();
  }

  void _act(Finding f) {
    switch (f.action) {
      case FindingAction.openItem:
        if (f.itemIds.isNotEmpty) widget.onOpenItem(f.itemIds.first);
      case FindingAction.openCheckup:
        _run(withBreachCheck: true);
      case FindingAction.generalSettings:
      case FindingAction.autoLock:
      case FindingAction.biometrics:
      case FindingAction.privateKey:
      case FindingAction.autofill:
      case FindingAction.systemSettings:
        // 系统设置只能由用户自己在操作系统里改，这里统一跳到设置页并给出说明。
        if (widget.onOpenSettings != null) {
          widget.onOpenSettings!();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr(AppStrings.healthActionSystem))),
          );
        }
      case FindingAction.none:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final report = _report;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final active = report?.activeFindings(_snoozes, now) ?? const <Finding>[];
    final activeIds = {for (final f in active) f.id};
    final snoozed = report == null ? const <Finding>[] : [
      for (final f in report.findings)
        if (!activeIds.contains(f.id)) f,
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      children: [
        Row(
          children: [
            Expanded(child: Text(context.tr(AppStrings.healthTitle), style: context.text.headlineSmall)),
            if (snoozed.isNotEmpty)
              // 一个明确动作：把忽略记录全部清掉，被隐藏的发现项立刻回来。
              // 不做「先展开再清除」的两段式——按钮文字不变却有两种行为最容易被误解。
              TextButton(
                onPressed: _unsnoozeAll,
                child: Text(context.trf(AppStrings.healthSnoozed, {'n': '${snoozed.length}'})),
              ),
            const SizedBox(width: 8),
            ZoButton(
              label: context.tr(AppStrings.healthRerun),
              icon: Icons.refresh_rounded,
              dense: true,
              onPressed: _busy ? null : () => _run(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          ZoPanel(child: Text(_error!, style: context.text.bodyMedium?.copyWith(color: c.danger))),
          const SizedBox(height: 16),
        ],
        if (report == null)
          ZoPanel(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: _busy
                  ? const CircularProgressIndicator()
                  : Text(context.trf(AppStrings.auditFailed, {'reason': '—'}), style: context.text.bodyMedium),
            ),
          )
        else ...[
          _ScoreCard(report: report, stale: report.isStale(now)),
          const SizedBox(height: 20),
          _StatsRow(report: report),
          const SizedBox(height: 20),
          _Dimensions(report: report),
          const SizedBox(height: 24),
          _Findings(
            findings: active,
            items: widget.items,
            expanded: _expanded,
            onToggle: (id) => setState(() => _expanded = _expanded == id ? null : id),
            onSnooze: _snooze,
            onAct: _act,
            onOpenItem: widget.onOpenItem,
          ),
        ],
      ],
    );
  }
}

/// 总分卡：分数环 + 最近检查时间 + 过期提示。
class _ScoreCard extends StatelessWidget {
  const _ScoreCard({required this.report, required this.stale});

  final HealthReport report;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final at = DateTime.fromMillisecondsSinceEpoch(report.checkedAt * 1000);
    final stamp = '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return ZoPanel(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _ScoreRing(score: report.score),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(context.trf(AppStrings.healthCheckedAt, {'time': stamp}), style: context.text.bodyMedium),
                const SizedBox(height: 6),
                if (stale)
                  Row(children: [
                    Icon(Icons.schedule_rounded, size: 15, color: c.warning),
                    const SizedBox(width: 6),
                    Flexible(child: Text(context.tr(AppStrings.healthExpired), style: context.text.bodySmall?.copyWith(color: c.warning))),
                  ])
                else
                  Text(context.tr(AppStrings.healthBreachLabel), style: context.text.bodySmall),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  ZoTag(_breachStatusLabel(context, report.breachStatus), color: _breachStatusColor(c, report.breachStatus)),
                  ZoTag('${context.tr(AppStrings.healthScanned)} ${report.scannedPasswords}'),
                  if (report.unreadableItems > 0)
                    ZoTag('${context.tr(AppStrings.healthUnreadable)} ${report.unreadableItems}', color: c.warning),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _breachStatusLabel(BuildContext context, BreachStatus s) => context.tr(switch (s) {
      BreachStatus.notRun => AppStrings.healthBreachNotRun,
      BreachStatus.ok => AppStrings.healthBreachOk,
      BreachStatus.unavailable => AppStrings.healthBreachUnavailable,
      BreachStatus.skipped => AppStrings.healthBreachSkipped,
    });

Color _breachStatusColor(ZoColors c, BreachStatus s) => switch (s) {
      BreachStatus.ok => c.success,
      BreachStatus.notRun => c.textMuted,
      BreachStatus.unavailable => c.warning,
      BreachStatus.skipped => c.textMuted,
    };

/// 扫描统计：已扫描密码 / 密码字段 / 不可读条目。
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    Widget cell(String label, int value, Color? color) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: context.text.labelMedium),
            const SizedBox(height: 4),
            Text('$value', style: monoStyle(context, size: 20, weight: FontWeight.w700, color: color ?? c.text)),
          ]),
        );
    return ZoPanel(
      child: Row(children: [
        cell(context.tr(AppStrings.healthScanned), report.scannedPasswords, null),
        cell(context.tr(AppStrings.healthPasswordFields), report.passwordFields, null),
        cell(
          context.tr(AppStrings.healthUnreadable),
          report.unreadableItems,
          report.unreadableItems > 0 ? c.warning : null,
        ),
      ]),
    );
  }
}

/// 六维得分。跳过的维度明确标注，避免用户以为「这一项没问题」。
class _Dimensions extends StatelessWidget {
  const _Dimensions({required this.report});

  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(title: context.tr(AppStrings.healthDimensionTitle)),
        const SizedBox(height: 10),
        ZoPanel(
          child: Column(children: [
            for (final d in report.dimensions)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  SizedBox(width: 104, child: Text(_dimensionLabel(context, d.dimension), style: context.text.bodyMedium)),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: d.cap == 0 ? 0 : (d.deduction / d.cap).clamp(0, 1).toDouble(),
                        minHeight: 5,
                        backgroundColor: c.border,
                        valueColor: AlwaysStoppedAnimation(d.deduction == 0 ? c.success : c.danger),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 118,
                    child: Text(
                      context.trf(AppStrings.healthDimScore, {'used': '${d.deduction}', 'cap': '${d.cap}'}),
                      textAlign: TextAlign.right,
                      style: monoStyle(context, size: 11.5, color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 62,
                    child: d.skipped
                        ? Text(context.tr(AppStrings.healthDimensionSkipped), style: context.text.labelSmall)
                        : const SizedBox.shrink(),
                  ),
                ]),
              ),
          ]),
        ),
      ],
    );
  }
}

String _dimensionLabel(BuildContext context, HealthDimension d) => context.tr(switch (d) {
      HealthDimension.breach => AppStrings.healthDimBreach,
      HealthDimension.weak => AppStrings.weakPasswords,
      HealthDimension.reuse => AppStrings.healthDimReuse,
      HealthDimension.stale => AppStrings.healthDimStale,
      HealthDimension.environment => AppStrings.healthDimEnvironment,
      HealthDimension.settings => AppStrings.healthDimSettings,
    });

String _severityLabel(BuildContext context, Severity s) => context.tr(switch (s) {
      Severity.low => AppStrings.healthSeverityLow,
      Severity.medium => AppStrings.healthSeverityMedium,
      Severity.high => AppStrings.healthSeverityHigh,
      Severity.critical => AppStrings.healthSeverityCritical,
    });

Color _severityColor(ZoColors c, Severity s) => switch (s) {
      Severity.low => c.textMuted,
      Severity.medium => c.accent,
      Severity.high => c.warning,
      Severity.critical => c.danger,
    };

/// 发现项列表。点开可下钻看关联条目，并可忽略 7 天或直接执行动作。
class _Findings extends StatelessWidget {
  const _Findings({
    required this.findings,
    required this.items,
    required this.expanded,
    required this.onToggle,
    required this.onSnooze,
    required this.onAct,
    required this.onOpenItem,
  });

  final List<Finding> findings;
  final List<VaultItem> items;
  final String? expanded;
  final ValueChanged<String> onToggle;
  final ValueChanged<Finding> onSnooze;
  final ValueChanged<Finding> onAct;
  final ValueChanged<String> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final shown = findings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(title: context.tr(AppStrings.healthFindings), count: shown.length),
        const SizedBox(height: 10),
        if (shown.isEmpty)
          ZoPanel(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(child: Text(context.tr(AppStrings.healthNoFindings), style: context.text.bodyMedium)),
          )
        else
          for (final f in shown)
            _FindingTile(
              finding: f,
              items: items,
              expanded: expanded == f.id,
              snoozed: !findings.any((a) => a.id == f.id),
              onToggle: () => onToggle(f.id),
              onSnooze: () => onSnooze(f),
              onAct: () => onAct(f),
              onOpenItem: onOpenItem,
            ),
      ],
    );
  }
}

class _FindingTile extends StatelessWidget {
  const _FindingTile({
    required this.finding,
    required this.items,
    required this.expanded,
    required this.snoozed,
    required this.onToggle,
    required this.onSnooze,
    required this.onAct,
    required this.onOpenItem,
  });

  final Finding finding;
  final List<VaultItem> items;
  final bool expanded;
  final bool snoozed;
  final VoidCallback onToggle;
  final VoidCallback onSnooze;
  final VoidCallback onAct;
  final ValueChanged<String> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final color = _severityColor(c, finding.severity);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ZoPanel(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(width: 3, height: 30, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(child: Text(finding.title, style: context.text.titleMedium)),
                    if (finding.count > 0) ...[
                      const SizedBox(width: 8),
                      Text('${finding.count}', style: monoStyle(context, size: 12, color: c.textFaint)),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(finding.description, style: context.text.bodySmall),
                ]),
              ),
              const SizedBox(width: 8),
              ZoTag(_severityLabel(context, finding.severity), color: color),
              if (finding.itemIds.isNotEmpty)
                ZoIconButton(
                  icon: expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  tooltip: context.tr(AppStrings.healthFindings),
                  size: 28,
                  onPressed: onToggle,
                ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              if (finding.action != FindingAction.none)
                ZoButton(
                  label: _actionLabel(context, finding.action),
                  icon: _actionIcon(finding.action),
                  dense: true,
                  onPressed: onAct,
                ),
              if (!snoozed)
                TextButton(onPressed: onSnooze, child: Text(context.tr(AppStrings.healthSnooze))),
            ]),
            if (expanded && finding.itemIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(color: c.border, height: 1),
              const SizedBox(height: 8),
              // 下钻：把关联条目直接列在这里，不必先跳走再自己找。
              for (final id in finding.itemIds)
                Builder(builder: (context) {
                  VaultItem? found;
                  for (final i in items) {
                    if (i.id == id) {
                      found = i;
                      break;
                    }
                  }
                  final item = found;
                  if (item == null) return const SizedBox.shrink();
                  return Hover(
                    onTap: () => onOpenItem(id),
                    builder: (context, hover) => Container(
                      color: hover ? c.surfaceHover.withValues(alpha: 0.5) : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                      child: Row(children: [
                        Monogram(title: item.data.title, size: 26),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.data.title,
                            overflow: TextOverflow.ellipsis,
                            style: context.text.bodyMedium,
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, size: 17, color: hover ? c.text : c.textFaint),
                      ]),
                    ),
                  );
                }),
            ],
          ],
        ),
      ),
    );
  }
}

String _actionLabel(BuildContext context, FindingAction a) => context.tr(switch (a) {
      FindingAction.openItem => AppStrings.healthOpenItem,
      FindingAction.openCheckup => AppStrings.healthActionRun,
      FindingAction.biometrics => AppStrings.healthActionEnable,
      FindingAction.autoLock => AppStrings.autoLock,
      FindingAction.autofill => AppStrings.autofillEnable,
      FindingAction.privateKey => AppStrings.viewSecretKey,
      FindingAction.generalSettings => AppStrings.healthActionGeneral,
      FindingAction.systemSettings => AppStrings.healthActionSystem,
      FindingAction.none => AppStrings.healthFindings,
    });

IconData _actionIcon(FindingAction a) => switch (a) {
      FindingAction.openItem => Icons.open_in_new_rounded,
      FindingAction.openCheckup => Icons.play_arrow_rounded,
      FindingAction.biometrics => Icons.fingerprint_rounded,
      FindingAction.autoLock => Icons.lock_clock_rounded,
      FindingAction.autofill => Icons.edit_note_rounded,
      FindingAction.privateKey => Icons.key_rounded,
      FindingAction.generalSettings => Icons.tune_rounded,
      FindingAction.systemSettings => Icons.settings_rounded,
      FindingAction.none => Icons.info_outline_rounded,
    };

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) => Row(children: [
        Text(title, style: context.text.titleLarge),
        if (count != null) ...[
          const SizedBox(width: 8),
          Text('$count', style: monoStyle(context, size: 12, color: context.zo.textFaint)),
        ],
      ]);
}

class _ScoreRing extends StatelessWidget {
  const _ScoreRing({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final color = score >= 90 ? c.success : score >= 60 ? c.accent : c.danger;
    return SizedBox.square(
      dimension: 132,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: score / 100),
        duration: const Duration(milliseconds: 900),
        curve: Zo.ease,
        builder: (context, v, _) => CustomPaint(
          painter: _ArcPainter(v, color, c.border),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${(v * 100).round()}', style: monoStyle(context, size: 38, weight: FontWeight.w700, spacing: -1)),
              Text(context.tr(AppStrings.healthScore), style: context.text.labelMedium),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.v, this.color, this.track);

  final double v;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final rect = (Offset.zero & size).deflate(stroke);
    const start = math.pi * 0.75;
    const sweep = math.pi * 1.5;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, p..color = track);
    canvas.drawArc(rect, start, sweep * v, false, p..color = color);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.v != v || old.color != color;
}
