import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

/// 备份卡（F-08 补充）：把 Secret Key 与恢复码渲染成一张 700×900 的卡片图，默认 2x
/// （即 1400×1800 像素）。与 PDF 恢复套件互补——PDF 适合打印归档，卡图适合存进
/// 手机相册或打印成实体卡随身携带。
///
/// 卡片图是本机生成的静态图片，只写到用户选择的位置或经系统分享面板导出，不经过网络、
/// 不落应用缓存。它等价于明文凭据，导出后请按恢复套件同等级别保管。
abstract final class BackupCard {
  /// 逻辑尺寸（1x）。2x 导出即 1400×1800。
  static const Size logicalSize = Size(700, 900);

  /// 默认导出倍率。
  static const double defaultScale = 2;

  static const String _fontAsset = 'assets/fonts/NotoSansSC-Regular.ttf';

  static Future<ui.Image> render(BackupCardData data, {double scale = defaultScale}) async {
    final loader = FontLoader('BackupCardSans')..addFont(_fontData());
    await loader.load();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(scale);
    _BackupCardPainter(data).paint(canvas, logicalSize);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage((logicalSize.width * scale).round(), (logicalSize.height * scale).round());
    } finally {
      picture.dispose();
    }
  }

  static Future<Uint8List> pngBytes(BackupCardData data, {double scale = defaultScale}) async {
    final image = await render(data, scale: scale);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('备份卡编码失败');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  static Future<ByteData> _fontData() async {
    final data = await rootBundle.load(_fontAsset);
    return ByteData.view(data.buffer);
  }

  static String get fileName => 'VaultOne-备份卡.png';

  /// 返回保存位置描述；用户取消时返回 null。`canContinue` 用于锁定/会话失效后放弃写入。
  static Future<String?> save(BackupCardData data, {required bool Function() canContinue}) async {
    if (!canContinue()) return null;
    final bytes = await pngBytes(data);
    if (!canContinue()) return null;
    if (Platform.isAndroid || Platform.isIOS) {
      final ok = await Printing.sharePdf(bytes: bytes, filename: fileName);
      return ok ? '已通过系统面板导出' : null;
    }
    final loc = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const [XTypeGroup(label: 'PNG 图片', extensions: ['png'])],
    );
    if (loc == null || !canContinue()) return null;
    var path = loc.path;
    if (!path.toLowerCase().endsWith('.png')) path = '$path.png';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }
}

/// 备份卡内容。`secretKey` 应为规范形态（`V1-` 分组），由内核比对后返回。
@immutable
class BackupCardData {
  const BackupCardData({required this.email, required this.secretKey, required this.recoveryCode, required this.generatedAt});

  final String email;
  final String secretKey;
  final String recoveryCode;
  final DateTime generatedAt;
}

class _BackupCardPainter {
  _BackupCardPainter(this.data);

  final BackupCardData data;

  static const _ink = Color(0xFF0A0A0C);
  static const _muted = Color(0xFF55555E);
  static const _faint = Color(0xFF8A8A93);
  static const _paper = Color(0xFFF7F7F4);
  static const _rule = Color(0xFFD8D8D2);
  static const _accent = Color(0xFF2457E6);
  static const _family = 'BackupCardSans';
  static const _mono = 'Cascadia Mono';

  TextPainter _text(String value, {required double size, Color color = _ink, FontWeight weight = FontWeight.w400, double spacing = 0, bool mono = false, double height = 1.35}) {
    final tp = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: mono ? _mono : _family,
          fontFamilyFallback: mono ? const ['Consolas', 'SF Mono', 'monospace'] : const [_family],
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: spacing,
          height: height,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout(maxWidth: BackupCard.logicalSize.width);
    return tp;
  }

  void _draw(Canvas canvas, TextPainter tp, Offset at) => tp.paint(canvas, at);

  void _bevel(Canvas canvas, Rect rect, {required Color fill, Color? stroke, double cut = 12, double width = 1.2}) {
    final path = Path()
      ..moveTo(rect.left + cut, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom - cut)
      ..lineTo(rect.right - cut, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.top + cut)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    if (stroke != null) {
      canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = width..color = stroke);
    }
  }

  void paint(Canvas canvas, Size size) {
    final w = size.width;

    // 纸面 + 极淡的斜向纹理，避免大面积纯色在打印/相册里显得扁平
    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);
    final hatch = Paint()
      ..color = _ink.withValues(alpha: 0.022)
      ..strokeWidth = 1;
    for (double x = -size.height; x < w; x += 26) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), hatch);
    }

    // 顶部品牌带
    const pad = 56.0;
    final mark = Rect.fromLTWH(pad, pad, 30, 30);
    _bevel(canvas, mark, fill: _accent, cut: 7);
    canvas.drawCircle(mark.center, 7.4, (Paint()..style = PaintingStyle.stroke..strokeWidth = 3.2..color = Colors.white));
    canvas.drawLine(
      mark.center.translate(1.6, -5.4),
      mark.center.translate(-1.6, 5.4),
      (Paint()
        ..strokeWidth = 3.2
        ..color = Colors.white
        ..strokeCap = StrokeCap.square),
    );

    final word = _text('VaultOne', size: 21, weight: FontWeight.w800, spacing: 0.4);
    _draw(canvas, word, Offset(pad + 42, pad + 4));

    final badge = _text('RECOVERY KIT · 备份卡', size: 11, color: _accent, weight: FontWeight.w600, spacing: 1.6);
    _draw(canvas, badge, Offset(w - pad - badge.width, pad + 10));

    var y = pad + 58;
    canvas.drawLine(Offset(pad, y), Offset(w - pad, y), Paint()..color = _rule..strokeWidth = 1);
    y += 30;

    final title = _text('请离线保管这张卡', size: 27, weight: FontWeight.w700, spacing: -0.4);
    _draw(canvas, title, Offset(pad, y));
    y += 40;

    final lead = _wrap(
      '它是找回你保险库的唯一凭据。VaultOne 采用零知识架构，无法重置你的主密码，也无法替你恢复数据。'
      '请打印成实体卡或存入离线介质，不要放进网盘、邮箱或聊天记录。',
      size: 12.5,
      color: _muted,
      width: w - pad * 2,
      height: 1.6,
    );
    _draw(canvas, lead, Offset(pad, y));
    y += lead.height + 30;

    // Secret Key
    final skHeight = _block(canvas, y, 'SECRET KEY · 设备密钥', data.secretKey, size: 19);
    y += skHeight + 16;

    // Recovery Code
    final rcHeight = _block(canvas, y, 'RECOVERY CODE · 恢复码', data.recoveryCode, size: 19);
    y += rcHeight + 16;

    // 邮箱（非密钥，普通字体）
    final emailHeight = _block(canvas, y, '账户邮箱 / EMAIL', data.email, size: 14, mono: false);
    y += emailHeight + 16;

    // 主密码手写留白
    final blank = Rect.fromLTWH(pad, y, w - pad * 2, 62);
    _bevel(canvas, blank, fill: Colors.white.withValues(alpha: 0.6), stroke: _rule, cut: 10, width: 1);
    final blankLabel = _text('主密码（可选，手写）/ MASTER PASSWORD', size: 10, color: _faint, spacing: 1.2);
    _draw(canvas, blankLabel, Offset(pad + 18, y + 12));
    canvas.drawLine(Offset(pad + 18, y + 46), Offset(w - pad - 18, y + 46), Paint()..color = _rule..strokeWidth = 1);
    y += 62 + 26;

    // 使用说明
    for (final line in [
      '在新设备登录时，需要同时输入「主密码」与「Secret Key」。',
      '忘记主密码时，可用「Secret Key + 恢复码」重设主密码；重设后此恢复码立即作废，请保存新的恢复套件。',
    ]) {
      final dot = _text('·', size: 13, color: _accent, weight: FontWeight.w700);
      _draw(canvas, dot, Offset(pad, y));
      final body = _wrap(line, size: 11.5, color: _ink, width: w - pad * 2 - 16, height: 1.55);
      _draw(canvas, body, Offset(pad + 14, y));
      y += body.height + 8;
    }

    // 页脚
    final footY = size.height - pad - 10;
    canvas.drawLine(Offset(pad, footY - 22), Offset(w - pad, footY - 22), Paint()..color = _rule..strokeWidth = 1);
    final date = data.generatedAt.toIso8601String().substring(0, 10);
    final foot = _text('生成于 $date · 能打开你保险库的，只有你自己。', size: 10, color: _faint);
    _draw(canvas, foot, Offset(pad, footY - 14));
    final markFoot = _text('VaultOne', size: 10, color: _faint, weight: FontWeight.w700, spacing: 1.2);
    _draw(canvas, markFoot, Offset(w - pad - markFoot.width, footY - 14));
  }

  /// 绘制一个密钥块：浅底、切角描边、标签 + 等宽大字号的值（过长自动换行）。
  double _block(Canvas canvas, double top, String label, String value, {required double size, bool mono = true}) {
    const pad = 56.0;
    final w = BackupCard.logicalSize.width;
    final labelTp = _text(label, size: 10, color: _accent, weight: FontWeight.w600, spacing: 1.4);
    final valueTp = _wrap(value, size: size, weight: FontWeight.w600, spacing: mono ? 1.1 : 0, mono: mono, width: w - pad * 2 - 40, height: 1.5);
    final height = 16 + labelTp.height + 10 + valueTp.height + 20;
    final rect = Rect.fromLTWH(pad, top, w - pad * 2, height);
    _bevel(canvas, rect, fill: Colors.white.withValues(alpha: 0.72), stroke: _ink, cut: 12, width: 1.2);
    _draw(canvas, labelTp, Offset(pad + 20, top + 14));
    _draw(canvas, valueTp, Offset(pad + 20, top + 14 + labelTp.height + 10));
    return height;
  }

  TextPainter _wrap(String value, {required double size, required double width, Color color = _ink, FontWeight weight = FontWeight.w400, double spacing = 0, bool mono = false, double height = 1.35}) {
    final tp = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: mono ? _mono : _family,
          fontFamilyFallback: mono ? const ['Consolas', 'SF Mono', 'monospace'] : const [_family],
          fontSize: size,
          fontWeight: weight,
          color: color,
          letterSpacing: spacing,
          height: height,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    return tp;
  }
}
