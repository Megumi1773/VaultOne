import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/models.dart';

/// Recovery Kit（F-08）：用 `pdf` 生成 A4 PDF，桌面端另存为文件，移动端通过系统分享/打印面板导出。
///
/// 文件只写到用户选择的位置，不经过任何网络或应用缓存。
abstract final class RecoveryKit {
  static Future<pw.Font> _font() async {
    // 内嵌中文字体，保证任何设备打印一致
    final data = await rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf');
    return pw.Font.ttf(data);
  }

  static Future<Uint8List> build(Enrollment e) async {
    final font = await _font();
    final mono = pw.Font.courierBold();
    const ink = PdfColor.fromInt(0xFF0A0A0A);
    const accent = PdfColor.fromInt(0xFF2563EB);
    const muted = PdfColor.fromInt(0xFF555555);
    final date = DateTime.now().toIso8601String().substring(0, 10);
    final doc = pw.Document(title: 'VaultOne Recovery Kit', author: 'VaultOne', creator: 'VaultOne');

    pw.Widget box(String label, String value, {bool code = true}) => pw.Container(
          width: double.infinity,
          margin: const pw.EdgeInsets.only(bottom: 12),
          padding: const pw.EdgeInsets.all(14),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: ink, width: 1.2), borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(label, style: pw.TextStyle(font: font, fontSize: 9, color: muted, letterSpacing: 1.2)),
            pw.SizedBox(height: 6),
            pw.Text(value, style: pw.TextStyle(font: code ? mono : font, fontSize: code ? 14 : 13, color: ink, letterSpacing: code ? 0.6 : 0)),
          ]),
        );

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(48),
      build: (ctx) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Row(children: [
          pw.Container(width: 22, height: 22, decoration: pw.BoxDecoration(color: accent, borderRadius: pw.BorderRadius.circular(5))),
          pw.SizedBox(width: 10),
          pw.Text('VaultOne', style: pw.TextStyle(font: font, fontSize: 20, fontWeight: pw.FontWeight.bold, color: ink)),
        ]),
        pw.SizedBox(height: 26),
        pw.Text('Recovery Kit · 恢复套件', style: pw.TextStyle(font: font, fontSize: 24, color: ink)),
        pw.SizedBox(height: 8),
        pw.Text(
          '这是找回你保险库的唯一凭据。VaultOne 采用零知识架构，我们无法重置你的主密码，也无法替你恢复数据。'
          '请打印或离线保存本文件，不要存放在网盘、邮箱或聊天记录中。',
          style: pw.TextStyle(font: font, fontSize: 10.5, color: muted, lineSpacing: 3),
        ),
        pw.SizedBox(height: 22),
        box('账户邮箱 / EMAIL', e.email, code: false),
        box('SECRET KEY · 设备密钥', e.secretKey),
        box('RECOVERY CODE · 恢复码', e.recoveryCode),
        box('主密码（可选，手写）/ MASTER PASSWORD', ' ', code: false),
        pw.SizedBox(height: 10),
        for (final line in [
          '在新设备登录时，需要同时输入「主密码」与「Secret Key」。',
          '忘记主密码时，可用「Secret Key + 恢复码」重设主密码；重设后此恢复码立即作废，请保存新的 Recovery Kit。',
          '账户 ID：${e.accountId}',
        ])
          pw.Bullet(text: line, style: pw.TextStyle(font: font, fontSize: 10, color: ink, lineSpacing: 2)),
        pw.Spacer(),
        pw.Divider(color: muted, thickness: 0.5),
        pw.Text('生成于 $date · 能打开你保险库的，只有你自己。', style: pw.TextStyle(font: font, fontSize: 8.5, color: muted)),
      ]),
    ));
    return doc.save();
  }

  static String get fileName => 'VaultOne-Recovery-Kit.pdf';

  /// 返回保存位置描述；用户取消时返回 null。
  static Future<String?> save(Enrollment e, {required bool Function() canContinue}) async {
    if (!canContinue()) return null;
    final bytes = await build(e);
    if (!canContinue()) return null;
    if (Platform.isAndroid || Platform.isIOS) {
      final ok = await Printing.sharePdf(bytes: bytes, filename: fileName);
      return ok ? '已通过系统面板导出' : null;
    }
    final loc = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: const [XTypeGroup(label: 'PDF', extensions: ['pdf'])],
    );
    if (loc == null || !canContinue()) return null;
    var path = loc.path;
    if (!path.toLowerCase().endsWith('.pdf')) path = '$path.pdf';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  static Future<void> printKit(Enrollment e) => Printing.layoutPdf(onLayout: (_) => build(e), name: fileName);
}
