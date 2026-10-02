import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/models.dart';
import '../l10n/strings.dart';

/// Recovery Kit（F-08）：用 `pdf` 生成 A4 PDF，桌面端另存为文件，移动端通过系统分享/打印面板导出。
///
/// 文件只写到用户选择的位置，不经过任何网络或应用缓存。
///
/// PDF 的文字在生成时固化，不随界面语言在运行时切换，因此入口接收 [language]：
/// 同一份材料按所选语言渲染文案，并内嵌对应字体（简中与英文用 Noto Sans SC，
/// 繁中用 Noto Sans TC）。
abstract final class RecoveryKit {
  /// 内嵌字体，保证任何设备打印一致。字体是子集化的，见 `tools/subset_font.py`。
  static Future<pw.Font> _font(AppLanguage language) async {
    final asset = language == AppLanguage.zhHant
        ? 'assets/fonts/NotoSansTC-Regular.ttf'
        : 'assets/fonts/NotoSansSC-Regular.ttf';
    return pw.Font.ttf(await rootBundle.load(asset));
  }

  static String _t(AppLanguage language, String source) =>
      AppStrings.translate(source, language);

  static Future<Uint8List> build(Enrollment e, {AppLanguage language = AppStrings.defaultLanguage}) async {
    final font = await _font(language);
    // 不引用 `pw.Font.courierBold()`：内置 Type1 字体不支持 Unicode，
    // 标签里的「·」等字符会让整份文档生成失败。密钥值用内嵌字体加宽松字距呈现。
    final mono = font;
    const ink = PdfColor.fromInt(0xFF0A0A0A);
    const accent = PdfColor.fromInt(0xFF2563EB);
    const muted = PdfColor.fromInt(0xFF555555);
    final date = DateTime.now().toIso8601String().substring(0, 10);
    String t(String source) => _t(language, source);
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
          pw.Text(AppStrings.appName, style: pw.TextStyle(font: font, fontSize: 20, fontWeight: pw.FontWeight.bold, color: ink)),
        ]),
        pw.SizedBox(height: 26),
        pw.Text(t(AppStrings.kitDocTitle), style: pw.TextStyle(font: font, fontSize: 24, color: ink)),
        pw.SizedBox(height: 8),
        pw.Text(
          t(AppStrings.kitLead),
          style: pw.TextStyle(font: font, fontSize: 10.5, color: muted, lineSpacing: 3),
        ),
        pw.SizedBox(height: 22),
        box(t(AppStrings.docEmailLabel), e.email, code: false),
        box(t(AppStrings.docSecretKeyLabel), e.secretKey),
        box(t(AppStrings.docRecoveryCodeLabel), e.recoveryCode),
        box(t(AppStrings.docMasterPasswordLabel), ' ', code: false),
        pw.SizedBox(height: 10),
        for (final line in [
          t(AppStrings.docLoginNeedsBoth),
          t(AppStrings.kitResetHint),
          AppStrings.format(t(AppStrings.kitAccountId), {'id': e.accountId}),
        ])
          pw.Bullet(text: line, style: pw.TextStyle(font: font, fontSize: 10, color: ink, lineSpacing: 2)),
        pw.Spacer(),
        pw.Divider(color: muted, thickness: 0.5),
        pw.Text(
          AppStrings.format(t(AppStrings.docGeneratedFooter), {'date': date}),
          style: pw.TextStyle(font: font, fontSize: 8.5, color: muted),
        ),
      ]),
    ));
    return doc.save();
  }

  static String fileName(AppLanguage language) => AppStrings.translate(AppStrings.kitFileName, language);

  /// 返回保存位置描述；用户取消时返回 null。
  static Future<String?> save(Enrollment e, {required bool Function() canContinue, AppLanguage language = AppStrings.defaultLanguage}) async {
    if (!canContinue()) return null;
    final bytes = await build(e, language: language);
    if (!canContinue()) return null;
    final name = fileName(language);
    if (Platform.isAndroid || Platform.isIOS) {
      final ok = await Printing.sharePdf(bytes: bytes, filename: name);
      return ok ? _t(language, AppStrings.docExportedViaPanel) : null;
    }
    final loc = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        XTypeGroup(label: _t(language, AppStrings.kitTypeGroup), extensions: const ['pdf']),
      ],
    );
    if (loc == null || !canContinue()) return null;
    var path = loc.path;
    if (!path.toLowerCase().endsWith('.pdf')) path = '$path.pdf';
    await File(path).writeAsBytes(bytes, flush: true);
    return path;
  }

  static Future<void> printKit(Enrollment e, {AppLanguage language = AppStrings.defaultLanguage}) =>
      Printing.layoutPdf(onLayout: (_) => build(e, language: language), name: fileName(language));
}
