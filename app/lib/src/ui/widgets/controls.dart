import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 悬停状态构建器。
class Hover extends StatefulWidget {
  const Hover({super.key, required this.builder, this.cursor = SystemMouseCursors.click, this.onTap});

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  final VoidCallback? onTap;

  @override
  State<Hover> createState() => _HoverState();
}

class _HoverState extends State<Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : widget.cursor,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: widget.builder(context, _hover),
      ),
    );
  }
}

enum ZoButtonVariant { primary, secondary, ghost, danger }

/// 按钮。主按钮使用切角造型与强调色，是界面中唯一"响亮"的元素。
class ZoButton extends StatefulWidget {
  const ZoButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.variant = ZoButtonVariant.primary,
    this.loading = false,
    this.expand = false,
    this.dense = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final ZoButtonVariant variant;
  final bool loading;
  final bool expand;
  final bool dense;

  @override
  State<ZoButton> createState() => _ZoButtonState();
}

class _ZoButtonState extends State<ZoButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final enabled = widget.onPressed != null && !widget.loading;
    late Color bg, fg, border;
    ShapeBorder shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
    switch (widget.variant) {
      case ZoButtonVariant.primary:
        bg = _hover ? Color.lerp(c.accent, Colors.white, 0.12)! : c.accent;
        fg = c.onAccent;
        border = Colors.transparent;
        shape = Zo.bevel(widget.dense ? 5 : Zo.cut);
      case ZoButtonVariant.secondary:
        bg = _hover ? c.surfaceHover : c.surfaceRaised;
        fg = c.text;
        border = _hover ? c.borderStrong : c.border;
      case ZoButtonVariant.ghost:
        bg = _hover ? c.surfaceHover : Colors.transparent;
        fg = _hover ? c.text : c.textMuted;
        border = Colors.transparent;
      case ZoButtonVariant.danger:
        bg = _hover ? c.danger.withValues(alpha: 0.16) : c.danger.withValues(alpha: 0.09);
        fg = c.danger;
        border = c.danger.withValues(alpha: 0.35);
    }
    if (!enabled && !widget.loading) {
      bg = widget.variant == ZoButtonVariant.primary ? c.accent.withValues(alpha: 0.35) : bg;
      fg = fg.withValues(alpha: 0.5);
    }
    if (shape is RoundedRectangleBorder) {
      shape = shape.copyWith(side: BorderSide(color: border));
    }

    final h = widget.dense ? 32.0 : 40.0;
    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading)
          SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
        else if (widget.icon != null)
          Icon(widget.icon, size: widget.dense ? 15 : 17, color: fg),
        if (widget.loading || widget.icon != null) SizedBox(width: widget.label.isEmpty ? 0 : 8),
        if (widget.label.isNotEmpty)
          Text(
            widget.label,
            style: context.text.labelLarge?.copyWith(color: fg, fontSize: widget.dense ? 12.5 : 13.5, fontWeight: FontWeight.w600),
          ),
      ],
    );

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _down = false;
      }),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: () => setState(() => _down = false),
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: _down ? 0.97 : 1,
          duration: Zo.fast,
          curve: Zo.ease,
          child: AnimatedContainer(
            duration: Zo.fast,
            height: h,
            padding: EdgeInsets.symmetric(horizontal: widget.dense ? 12 : 18),
            decoration: ShapeDecoration(color: bg, shape: shape),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 方形图标按钮。
class ZoIconButton extends StatelessWidget {
  const ZoIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = 32,
    this.active = false,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final bool active;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Tooltip(
      message: tooltip,
      child: Hover(
        onTap: onPressed,
        builder: (context, hover) => AnimatedContainer(
          duration: Zo.fast,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: active ? c.accentSoft : (hover ? c.surfaceHover : Colors.transparent),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(
            icon,
            size: size * 0.53,
            color: color ?? (active ? c.accent : (hover ? c.text : c.textMuted)),
          ),
        ),
      ),
    );
  }
}

/// 带标签的输入框。
class ZoTextField extends StatefulWidget {
  const ZoTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.obscure = false,
    this.mono = false,
    this.autofocus = false,
    this.focusNode,
    this.onSubmitted,
    this.onChanged,
    this.trailing,
    this.maxLines = 1,
    this.minLines,
    this.error,
    this.keyboardType,
    this.textInputAction,
    this.prefixIcon,
    this.enabled = true,
    this.inputFormatters,
    this.dense = false,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final bool obscure;
  final bool mono;
  final bool autofocus;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final List<Widget>? trailing;
  final int maxLines;
  final int? minLines;
  final String? error;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final IconData? prefixIcon;
  final bool enabled;
  final List<TextInputFormatter>? inputFormatters;
  final bool dense;

  @override
  State<ZoTextField> createState() => _ZoTextFieldState();
}

class _ZoTextFieldState extends State<ZoTextField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final focused = _focus.hasFocus;
    final hasError = widget.error != null;
    final borderColor = hasError ? c.danger : (focused ? c.accent : c.border);
    final style = widget.mono
        ? monoStyle(context, size: 14)
        : context.text.bodyLarge?.copyWith(fontSize: 14);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!, style: context.text.labelMedium),
          const SizedBox(height: 6),
        ],
        AnimatedContainer(
          duration: Zo.fast,
          decoration: BoxDecoration(
            color: widget.enabled ? c.surfaceRaised : c.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: focused ? 1.4 : 1),
            boxShadow: focused && !hasError ? [BoxShadow(color: c.accent.withValues(alpha: 0.12), blurRadius: 0, spreadRadius: 3)] : null,
          ),
          child: Row(
            crossAxisAlignment: widget.maxLines > 1 ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              if (widget.prefixIcon != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Icon(widget.prefixIcon, size: 16, color: focused ? c.text : c.textFaint),
                ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  obscureText: widget.obscure && !_revealed,
                  obscuringCharacter: '•',
                  enableSuggestions: !widget.obscure,
                  autocorrect: false,
                  enabled: widget.enabled,
                  maxLines: widget.obscure ? 1 : widget.maxLines,
                  minLines: widget.minLines,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  inputFormatters: widget.inputFormatters,
                  onSubmitted: widget.onSubmitted,
                  onChanged: widget.onChanged,
                  style: style,
                  cursorWidth: 1.6,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: widget.hint,
                    hintStyle: style?.copyWith(color: c.textFaint),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: widget.dense ? 9 : 12),
                  ),
                ),
              ),
              if (widget.obscure)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: ZoIconButton(
                    icon: _revealed ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    tooltip: _revealed ? '隐藏' : '显示',
                    size: 28,
                    onPressed: () => setState(() => _revealed = !_revealed),
                  ),
                ),
              if (widget.trailing != null) ...[
                ...widget.trailing!,
                const SizedBox(width: 4),
              ],
            ],
          ),
        ),
        AnimatedSize(
          duration: Zo.fast,
          child: hasError
              ? Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(widget.error!, style: context.text.bodySmall?.copyWith(color: c.danger)),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 细描边面板。
class ZoPanel extends StatelessWidget {
  const ZoPanel({super.key, required this.child, this.padding = const EdgeInsets.all(Zo.s5), this.color});

  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.surface,
        borderRadius: BorderRadius.circular(Zo.radiusLg),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }
}

/// 小节标题（大写、字距拉开）。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(text.toUpperCase(), style: context.text.labelSmall),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// 切角小标签。
class ZoTag extends StatelessWidget {
  const ZoTag(this.text, {super.key, this.color, this.icon});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final col = color ?? c.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: ShapeDecoration(
        color: col.withValues(alpha: 0.12),
        shape: Zo.bevel(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: col), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: col, height: 1.2)),
        ],
      ),
    );
  }
}

/// 根据标题生成的单字头像，颜色稳定（同标题同色）。
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.title, this.size = 36, this.icon});

  final String title;
  final double size;
  final IconData? icon;

  static const _palette = [
    Color(0xFFFFD60A),
    Color(0xFF7DD3FC),
    Color(0xFFA78BFA),
    Color(0xFF3DD68C),
    Color(0xFFFF8A65),
    Color(0xFFF472B6),
    Color(0xFF5EEAD4),
    Color(0xFFFBBF24),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final t = title.trim();
    final hash = t.codeUnits.fold<int>(7, (h, u) => (h * 31 + u) & 0x7fffffff);
    final color = _palette[hash % _palette.length];
    final letter = t.isEmpty ? '?' : String.fromCharCode(t.runes.first).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.13),
        shape: BeveledRectangleBorder(
          borderRadius: BorderRadius.only(topLeft: Radius.circular(size * 0.22), bottomRight: Radius.circular(size * 0.22)),
          side: BorderSide(color: color.withValues(alpha: 0.28)),
        ),
      ),
      child: icon != null
          ? Icon(icon, size: size * 0.46, color: color)
          : Text(
              letter,
              style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: Color.lerp(color, c.text, 0.1), height: 1),
            ),
    );
  }
}

/// 错误时左右抖动。
class Shake extends StatefulWidget {
  const Shake({super.key, required this.child, required this.trigger});

  final Widget child;

  /// 数值变化时触发一次抖动
  final int trigger;

  @override
  State<Shake> createState() => _ShakeState();
}

class _ShakeState extends State<Shake> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  @override
  void didUpdateWidget(Shake old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        final dx = math.sin(t * math.pi * 6) * 8 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: widget.child,
    );
  }
}
