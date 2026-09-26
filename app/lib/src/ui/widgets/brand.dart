import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// VaultOne 标志：切角方框内是一枚保险库转盘，"1" 的竖笔贯穿其中——唯一的钥匙。
class ZoMark extends StatelessWidget {
  const ZoMark({super.key, this.size = 28, this.glow = 0});

  final double size;

  /// 0-1，解锁动效时的辉光强度
  final double glow;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(accent: c.accent, ink: c.onAccent, glow: glow)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({required this.accent, required this.ink, required this.glow});

  final Color accent;
  final Color ink;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final cut = s * 0.24;
    final body = Path()
      ..moveTo(cut, 0)
      ..lineTo(s, 0)
      ..lineTo(s, s - cut)
      ..lineTo(s - cut, s)
      ..lineTo(0, s)
      ..lineTo(0, cut)
      ..close();

    if (glow > 0) {
      canvas.drawPath(
        body,
        Paint()
          ..color = accent.withValues(alpha: 0.55 * glow)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.35 * glow),
      );
    }
    canvas.drawPath(body, Paint()..color = accent);

    final stroke = s * 0.105;
    final ring = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(Offset(s / 2, s / 2), s * 0.25, ring);

    // "1" 的竖笔：略微倾斜，贯穿上下
    final bar = Paint()
      ..color = ink
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(Offset(s * 0.56, s * 0.16), Offset(s * 0.44, s * 0.84), bar);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.accent != accent || old.glow != glow || old.ink != ink;
}

/// 字标 VaultOne：One 使用强调色。
class ZoWordmark extends StatelessWidget {
  const ZoWordmark({super.key, this.size = 20, this.showMark = true});

  final double size;
  final bool showMark;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final base = TextStyle(
      fontFamily: 'Segoe UI',
      fontFamilyFallback: const ['Microsoft YaHei UI'],
      fontSize: size,
      fontWeight: FontWeight.w800,
      letterSpacing: size * 0.02,
      color: c.text,
      height: 1,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showMark) ...[ZoMark(size: size * 1.35), SizedBox(width: size * 0.55)],
        Text.rich(
          TextSpan(children: [
            TextSpan(text: 'Vault', style: base),
            TextSpan(text: 'One', style: base.copyWith(color: c.accent)),
          ]),
        ),
      ],
    );
  }
}

/// 背景：极淡的斜向扫描线 + 角落的切角框线，带出零一式的 HUD 质感但不喧宾夺主。
class ZoBackdrop extends StatelessWidget {
  const ZoBackdrop({super.key, required this.child, this.intensity = 1});

  final Widget child;
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return CustomPaint(
      painter: _BackdropPainter(line: c.text.withValues(alpha: 0.025 * intensity), accent: c.accent.withValues(alpha: 0.5 * intensity)),
      child: child,
    );
  }
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({required this.line, required this.accent});

  final Color line;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = line
      ..strokeWidth = 1;
    const gap = 28.0;
    for (double x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
    final a = Paint()
      ..color = accent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const m = 28.0;
    const l = 36.0;
    canvas.drawPath(Path()..moveTo(m, m + l)..lineTo(m, m)..lineTo(m + l, m), a);
    canvas.drawPath(
      Path()
        ..moveTo(size.width - m, size.height - m - l)
        ..lineTo(size.width - m, size.height - m)
        ..lineTo(size.width - m - l, size.height - m),
      a,
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.line != line || old.accent != accent;
}

/// 解锁成功时的 "Rise" 扫光：一道强调色光带自下而上掠过。
class RiseSweep extends StatelessWidget {
  const RiseSweep({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    if (progress <= 0 || progress >= 1) return const SizedBox.shrink();
    final c = context.zo;
    return IgnorePointer(
      child: LayoutBuilder(builder: (context, box) {
        final y = box.maxHeight * (1 - Curves.easeInOutCubic.transform(progress));
        final fade = math.sin(progress * math.pi);
        return Stack(children: [
          Positioned(
            left: 0,
            right: 0,
            top: y - 90,
            height: 180,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    c.accent.withValues(alpha: 0),
                    c.accent.withValues(alpha: 0.16 * fade),
                    c.accent.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
          Positioned(left: 0, right: 0, top: y, height: 1.5, child: ColoredBox(color: c.accent.withValues(alpha: 0.9 * fade))),
        ]);
      }),
    );
  }
}
