import 'package:flutter/material.dart';

/// ZeroOne 设计令牌。
///
/// 调性：墨黑底 + Rising Yellow 强调色；切角几何（BeveledRectangleBorder）只用于
/// 强调元素（主按钮、徽标、选中态），其余表面使用细描边与克制的圆角，保持安静。
@immutable
class ZoColors extends ThemeExtension<ZoColors> {
  const ZoColors({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceHover,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.danger,
    required this.success,
    required this.warning,
    required this.digit,
    required this.symbol,
  });

  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceHover;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color danger;
  final Color success;
  final Color warning;

  /// 密码着色：数字
  final Color digit;

  /// 密码着色：符号
  final Color symbol;

  static const dark = ZoColors(
    bg: Color(0xFF09090A),
    surface: Color(0xFF101012),
    surfaceRaised: Color(0xFF16161A),
    surfaceHover: Color(0xFF1C1C21),
    border: Color(0xFF222227),
    borderStrong: Color(0xFF34343B),
    text: Color(0xFFF4F4F5),
    textMuted: Color(0xFFA1A1AA),
    textFaint: Color(0xFF63636C),
    accent: Color(0xFFFFD60A),
    onAccent: Color(0xFF0A0A0A),
    accentSoft: Color(0x1FFFD60A),
    danger: Color(0xFFFF4D4F),
    success: Color(0xFF3DD68C),
    warning: Color(0xFFFFA940),
    digit: Color(0xFFFFD60A),
    symbol: Color(0xFF7DD3FC),
  );

  static const light = ZoColors(
    bg: Color(0xFFF6F6F3),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFFBFBF9),
    surfaceHover: Color(0xFFF0F0EC),
    border: Color(0xFFE6E6E1),
    borderStrong: Color(0xFFD2D2CB),
    text: Color(0xFF0B0B0C),
    textMuted: Color(0xFF5B5B63),
    textFaint: Color(0xFF9A9AA2),
    accent: Color(0xFFFFCC00),
    onAccent: Color(0xFF0A0A0A),
    accentSoft: Color(0x29FFCC00),
    danger: Color(0xFFE5383B),
    success: Color(0xFF16A34A),
    warning: Color(0xFFD97706),
    digit: Color(0xFFB45309),
    symbol: Color(0xFF0369A1),
  );

  @override
  ZoColors copyWith() => this;

  @override
  ZoColors lerp(ThemeExtension<ZoColors>? other, double t) {
    if (other is! ZoColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ZoColors(
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      surfaceHover: l(surfaceHover, other.surfaceHover),
      border: l(border, other.border),
      borderStrong: l(borderStrong, other.borderStrong),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      textFaint: l(textFaint, other.textFaint),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      danger: l(danger, other.danger),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      digit: l(digit, other.digit),
      symbol: l(symbol, other.symbol),
    );
  }
}

extension ZoThemeX on BuildContext {
  ZoColors get zo => Theme.of(this).extension<ZoColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

/// 间距与圆角
abstract final class Zo {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;

  static const double radius = 10;
  static const double radiusLg = 14;

  /// 切角尺寸
  static const double cut = 7;

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration medium = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 420);
  static const Curve ease = Cubic(0.2, 0.8, 0.2, 1);

  static const String mono = 'Cascadia Mono';
  static const List<String> monoFallback = ['Consolas', 'SF Mono', 'Menlo', 'Roboto Mono', 'monospace'];

  static BeveledRectangleBorder bevel([double cut = Zo.cut]) =>
      BeveledRectangleBorder(borderRadius: BorderRadius.only(topLeft: Radius.circular(cut), bottomRight: Radius.circular(cut)));
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? ZoColors.dark : ZoColors.light;
  final base = ThemeData(brightness: brightness, useMaterial3: true);
  const family = 'Microsoft YaHei UI';
  const fallback = ['Segoe UI', 'PingFang SC', 'Noto Sans SC', 'sans-serif'];

  TextStyle t(double size, FontWeight w, Color color, {double spacing = 0, double height = 1.35}) => TextStyle(
        fontFamily: family,
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: w,
        color: color,
        letterSpacing: spacing,
        height: height,
      );

  final textTheme = TextTheme(
    displayLarge: t(44, FontWeight.w700, c.text, spacing: -1.2, height: 1.1),
    displayMedium: t(34, FontWeight.w700, c.text, spacing: -0.8, height: 1.15),
    headlineMedium: t(24, FontWeight.w600, c.text, spacing: -0.4, height: 1.2),
    headlineSmall: t(20, FontWeight.w600, c.text, spacing: -0.2),
    titleLarge: t(17, FontWeight.w600, c.text),
    titleMedium: t(14.5, FontWeight.w600, c.text),
    titleSmall: t(13, FontWeight.w600, c.textMuted),
    bodyLarge: t(15, FontWeight.w400, c.text, height: 1.5),
    bodyMedium: t(13.5, FontWeight.w400, c.text, height: 1.5),
    bodySmall: t(12, FontWeight.w400, c.textMuted, height: 1.45),
    labelLarge: t(13.5, FontWeight.w600, c.text),
    labelMedium: t(12, FontWeight.w500, c.textMuted, spacing: 0.2),
    labelSmall: t(10.5, FontWeight.w600, c.textFaint, spacing: 1.2),
  );

  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: brightness,
  ).copyWith(
    primary: c.accent,
    onPrimary: c.onAccent,
    surface: c.surface,
    onSurface: c.text,
    error: c.danger,
    outline: c.border,
    outlineVariant: c.border,
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bg,
    textTheme: textTheme,
    extensions: [c],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.surfaceHover,
    focusColor: c.accentSoft,
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.28),
      selectionHandleColor: c.accent,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        border: Border.all(color: c.borderStrong),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: textTheme.bodySmall?.copyWith(color: c.text),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStateProperty.all(c.borderStrong),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.accent,
      inactiveTrackColor: c.border,
      thumbColor: c.accent,
      overlayColor: c.accentSoft,
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 0),
      valueIndicatorColor: c.surfaceRaised,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onAccent : c.textMuted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.surfaceHover),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.borderStrong),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : Colors.transparent),
      checkColor: WidgetStateProperty.all(c.onAccent),
      side: BorderSide(color: c.borderStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Zo.radiusLg),
        side: BorderSide(color: c.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Zo.radius), side: BorderSide(color: c.borderStrong)),
      textStyle: textTheme.bodyMedium,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.border),
  );
}

TextStyle monoStyle(BuildContext context, {double size = 14, Color? color, FontWeight weight = FontWeight.w500, double spacing = 0.4}) =>
    TextStyle(
      fontFamily: Zo.mono,
      fontFamilyFallback: Zo.monoFallback,
      fontSize: size,
      fontWeight: weight,
      color: color ?? context.zo.text,
      letterSpacing: spacing,
      height: 1.4,
    );
