import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';

/// 安全中心（F-09 本地部分）：弱密码、重复密码、两步验证覆盖、泄露检测。
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key, required this.onOpenItem});

  final ValueChanged<String> onOpenItem;

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  List<AuditFinding>? _findings;
  Map<String, int>? _breaches;
  bool _checking = false;
  String? _breachError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = await VaultApi.audit();
      if (mounted) setState(() => _findings = f);
    } on CoreException catch (e) {
      // 页面可能在审计返回前被全局锁定销毁，不再展示旧会话结果。
      if (mounted && e.code != 'session_expired') {
        setState(() => _breachError = '审计失败：${e.message}');
      }
    }
  }

  /// k-匿名查询（在 Rust 内核中执行）：每个密码只发送 SHA-1 前 5 位，并开启 Add-Padding 让响应长度不泄露信息。
  Future<void> _checkBreaches(List<VaultItem> logins) async {
    setState(() {
      _checking = true;
      _breachError = null;
    });
    try {
      final result = await VaultApi.checkBreaches([for (final i in logins) i.id]);
      if (mounted) setState(() => _breaches = result);
    } on CoreException catch (e) {
      if (mounted) setState(() => _breachError = '检测失败：${e.message}');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final state = AppScope.of(context);
    final logins = state.items.where((i) => i.data.password != null).toList();
    final findings = _findings ?? const [];
    final weak = findings.where((f) => f.weak).toList();
    final reused = findings.where((f) => f.reusedWith > 0).toList();
    final loginItems = state.items.where((i) => i.data.kind == ItemKind.login).toList();
    final with2fa = loginItems.where((i) => i.data.totp != null).length;
    final breached = _breaches?.entries.where((e) => e.value > 0).map((e) => e.key).toSet() ?? const <String>{};

    final problems = <String>{...weak.map((f) => f.itemId), ...reused.map((f) => f.itemId), ...breached};
    final score = logins.isEmpty ? 100 : ((1 - problems.length / logins.length) * 100).round().clamp(0, 100);

    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 36, 40, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('安全中心', style: context.text.headlineMedium),
                const SizedBox(height: 6),
                Text('所有分析均在本机完成。泄露检测只发送密码 SHA-1 的前 5 位，服务端无法得知你的密码。',
                    style: context.text.bodyMedium?.copyWith(color: c.textMuted)),
                const SizedBox(height: 28),
                ZoPanel(
                  padding: const EdgeInsets.all(28),
                  child: Row(
                    children: [
                      _ScoreRing(score: score),
                      const SizedBox(width: 32),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              score >= 90 ? '状态良好' : score >= 60 ? '有待加强' : '需要立即处理',
                              style: context.text.headlineSmall,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              logins.isEmpty ? '还没有带密码的条目。' : '${logins.length} 个带密码的条目中，${problems.length} 个存在风险。',
                              style: context.text.bodyMedium?.copyWith(color: c.textMuted),
                            ),
                            const SizedBox(height: 18),
                            Wrap(spacing: 10, runSpacing: 10, children: [
                              _Stat('弱密码', weak.length, c.danger),
                              _Stat('重复使用', reused.length, c.warning),
                              _Stat('已泄露', _breaches == null ? null : breached.length, c.danger),
                              _Stat('两步验证', loginItems.isEmpty ? null : with2fa, c.success, suffix: '/${loginItems.length}'),
                            ]),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ZoPanel(
                  child: Row(
                    children: [
                      Icon(Icons.travel_explore_rounded, color: c.accent, size: 22),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('泄露密码检测', style: context.text.titleMedium),
                            const SizedBox(height: 3),
                            Text(
                              _breachError ??
                                  (_breaches == null
                                      ? '对照 Have I Been Pwned 数据库（k-匿名），需要联网。'
                                      : '检测完成：${breached.length} 个条目的密码出现在公开泄露数据中。'),
                              style: context.text.bodySmall?.copyWith(color: _breachError != null ? c.danger : null),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ZoButton(
                        label: _breaches == null ? '开始检测' : '重新检测',
                        variant: ZoButtonVariant.secondary,
                        dense: true,
                        loading: _checking,
                        onPressed: logins.isEmpty ? null : () => _checkBreaches(logins),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                if (breached.isNotEmpty) ...[
                  _IssueList(
                    title: '已泄露',
                    color: c.danger,
                    description: '这些密码出现在公开泄露库中，攻击者会优先尝试，请立即更换。',
                    items: [for (final id in breached) (state.byId(id), '出现 ${_breaches![id]} 次')],
                    onOpen: widget.onOpenItem,
                  ),
                  const SizedBox(height: 20),
                ],
                if (weak.isNotEmpty) ...[
                  _IssueList(
                    title: '弱密码',
                    color: c.danger,
                    description: '容易被猜测或字典攻击破解。',
                    items: [for (final f in weak) (state.byId(f.itemId), const ['极弱', '弱', '一般', '强', '很强'][f.score])],
                    onOpen: widget.onOpenItem,
                  ),
                  const SizedBox(height: 20),
                ],
                if (reused.isNotEmpty)
                  _IssueList(
                    title: '重复使用',
                    color: c.warning,
                    description: '一个网站泄露，会连带其他网站失守。',
                    items: [for (final f in reused) (state.byId(f.itemId), '与 ${f.reusedWith} 个条目相同')],
                    onOpen: widget.onOpenItem,
                  ),
                if (_findings != null && problems.isEmpty && logins.isNotEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('没有发现问题。保持下去。', style: context.text.bodyMedium?.copyWith(color: c.success)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color, {this.suffix = ''});

  final String label;
  final int? value;
  final Color color;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final v = value;
    return Container(
      width: 124,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.text.labelMedium),
          const SizedBox(height: 4),
          Text.rich(TextSpan(children: [
            TextSpan(
              text: v == null ? '—' : '$v',
              style: monoStyle(context, size: 22, weight: FontWeight.w700, color: v != null && v > 0 && suffix.isEmpty ? color : c.text),
            ),
            if (suffix.isNotEmpty && v != null) TextSpan(text: suffix, style: monoStyle(context, size: 13, color: c.textFaint)),
          ])),
        ],
      ),
    );
  }
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
              Text('安全评分', style: context.text.labelMedium),
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

class _IssueList extends StatelessWidget {
  const _IssueList({required this.title, required this.color, required this.description, required this.items, required this.onOpen});

  final String title;
  final Color color;
  final String description;
  final List<(VaultItem?, String)> items;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          Container(width: 3, height: 14, color: color),
          const SizedBox(width: 10),
          Text(title, style: context.text.titleLarge),
          const SizedBox(width: 8),
          Text('${items.length}', style: monoStyle(context, size: 12, color: c.textFaint)),
        ]),
        const SizedBox(height: 4),
        Padding(padding: const EdgeInsets.only(left: 13), child: Text(description, style: context.text.bodySmall)),
        const SizedBox(height: 12),
        ZoPanel(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              for (final (item, note) in items)
                if (item != null)
                  Hover(
                    onTap: () => onOpen(item.id),
                    builder: (context, hover) => Container(
                      color: hover ? c.surfaceHover.withValues(alpha: 0.5) : Colors.transparent,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      child: Row(children: [
                        Monogram(title: item.data.title, size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(item.data.title, style: context.text.titleMedium?.copyWith(fontSize: 13.5)),
                            if (item.data.subtitle.isNotEmpty) Text(item.data.subtitle, style: context.text.bodySmall),
                          ]),
                        ),
                        ZoTag(note, color: color),
                        const SizedBox(width: 8),
                        Icon(Icons.chevron_right_rounded, size: 18, color: hover ? c.text : c.textFaint),
                      ]),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}
