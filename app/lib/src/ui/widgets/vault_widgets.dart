import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../state/clipboard.dart';
import '../theme.dart';

/// 四段式强度条。
class StrengthMeter extends StatelessWidget {
  const StrengthMeter({super.key, required this.strength, this.showLabel = true});

  final Strength strength;
  final bool showLabel;

  static Color colorFor(BuildContext context, int score) {
    final c = context.zo;
    return switch (score) { 0 || 1 => c.danger, 2 => c.warning, 3 => c.accent, _ => c.success };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final color = colorFor(context, strength.score);
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: Zo.medium,
              curve: Zo.ease,
              height: 3,
              decoration: BoxDecoration(
                color: strength.guessesLog10 > 0 && i < math.max(1, strength.score) ? color : c.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < 3) const SizedBox(width: 4),
        ],
        if (showLabel) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 34,
            child: Text(
              strength.guessesLog10 > 0 ? strength.label : '',
              style: context.text.labelMedium?.copyWith(color: color),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ],
    );
  }
}

/// 字符着色的密码显示：字母常规色、数字强调色、符号冷色，便于逐字核对。
class PasswordText extends StatelessWidget {
  const PasswordText(this.value, {super.key, this.size = 15, this.maxLines, this.align = TextAlign.start});

  final String value;
  final double size;
  final int? maxLines;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final base = monoStyle(context, size: size);
    final spans = <TextSpan>[];
    for (final r in value.runes) {
      final ch = String.fromCharCode(r);
      final isDigit = r >= 48 && r <= 57;
      final isLetter = (r >= 65 && r <= 90) || (r >= 97 && r <= 122) || r > 127;
      spans.add(TextSpan(text: ch, style: base.copyWith(color: isDigit ? c.digit : (isLetter ? c.text : c.symbol))));
    }
    return Text.rich(TextSpan(children: spans), maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis, textAlign: align);
  }
}

/// 每秒刷新的 TOTP 视图：验证码 + 环形倒计时。
class TotpView extends StatefulWidget {
  const TotpView({super.key, required this.config, this.onCopy, this.large = false});

  final TotpConfig config;
  final void Function(String code)? onCopy;
  final bool large;

  @override
  State<TotpView> createState() => _TotpViewState();
}

class _TotpViewState extends State<TotpView> {
  Timer? _timer;
  TotpCode? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  @override
  void didUpdateWidget(TotpView old) {
    super.didUpdateWidget(old);
    if (old.config.secret != widget.config.secret) _tick();
  }

  void _tick() {
    try {
      final code = VaultApi.totp(widget.config);
      if (!mounted) return;
      if (code.code != _code?.code || code.remaining != _code?.remaining) {
        setState(() {
          _code = code;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _format(String code) {
    if (code.length == 6) return '${code.substring(0, 3)} ${code.substring(3)}';
    if (code.length == 8) return '${code.substring(0, 4)} ${code.substring(4)}';
    return code;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    if (_error != null) return Text(_error!, style: context.text.bodySmall?.copyWith(color: c.danger));
    final code = _code;
    if (code == null) return const SizedBox.shrink();
    final urgent = code.remaining <= 5;
    final ring = widget.large ? 26.0 : 20.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: Zo.medium,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(a), child: child),
          ),
          child: Text(
            _format(code.code),
            key: ValueKey(code.code),
            style: monoStyle(context, size: widget.large ? 26 : 17, weight: FontWeight.w600, spacing: 2, color: urgent ? c.danger : c.text),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox.square(
          dimension: ring,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: code.remaining / code.period),
            duration: const Duration(milliseconds: 500),
            builder: (context, v, _) => CustomPaint(painter: _RingPainter(v, urgent ? c.danger : c.accent, c.border)),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 22,
          child: Text('${code.remaining}', style: monoStyle(context, size: 11, color: urgent ? c.danger : c.textFaint)),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.value, this.color, this.track);

  final double value;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.13;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    canvas.drawArc(rect, 0, math.pi * 2, false, Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * value, false, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color;
}

/// 剪贴板倒计时提示条（全局悬浮于底部）。
class ClipboardToast extends StatelessWidget {
  const ClipboardToast({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ClipboardNotice?>(
      valueListenable: ClipboardService.notice,
      builder: (context, n, _) => AnimatedSwitcher(
        duration: Zo.medium,
        switchInCurve: Zo.ease,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(a), child: child),
        ),
        child: n == null ? const SizedBox.shrink() : _ToastBody(key: ValueKey(n.startedAt), notice: n),
      ),
    );
  }
}

class _ToastBody extends StatelessWidget {
  const _ToastBody({super.key, required this.notice});

  final ClipboardNotice notice;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final timed = notice.sensitive && notice.seconds > 0;
    return Container(
      width: 340,
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.borderStrong),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 12))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Icon(Icons.check_rounded, size: 18, color: c.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('已复制${notice.label}', style: context.text.titleMedium?.copyWith(fontSize: 13.5)),
                      if (timed)
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: notice.seconds.toDouble(), end: 0),
                          duration: Duration(seconds: notice.seconds),
                          builder: (context, v, _) => Text(
                            '${v.ceil()} 秒后从剪贴板清除 · 不进入剪贴板历史',
                            style: context.text.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
                if (timed)
                  TextButton(
                    onPressed: ClipboardService.clearNow,
                    style: TextButton.styleFrom(foregroundColor: c.textMuted, textStyle: const TextStyle(fontSize: 12.5)),
                    child: const Text('立即清除'),
                  ),
              ],
            ),
          ),
          if (timed)
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 1, end: 0),
              duration: Duration(seconds: notice.seconds),
              builder: (context, v, _) => Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(widthFactor: v, child: Container(height: 2, color: c.accent)),
              ),
            ),
        ],
      ),
    );
  }
}

/// 轻量提示（非剪贴板）。
void showZoMessage(BuildContext context, String message, {bool error = false}) {
  final c = context.zo;
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      width: math.min(380, MediaQuery.sizeOf(context).width - 32),
      elevation: 0,
      backgroundColor: c.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: error ? c.danger : c.borderStrong)),
      duration: const Duration(seconds: 3),
      content: Row(
        children: [
          Icon(error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, size: 18, color: error ? c.danger : c.accent),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: context.text.bodyMedium)),
        ],
      ),
    ),
  );
}
