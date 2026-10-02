import 'package:flutter/material.dart';

import '../../core/ffi.dart';
import '../../core/import_models.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/controls.dart';

/// 导入预览结果：用户确认后要用的映射与策略；取消则为 null。
typedef ImportDecision = ({ColumnMapping mapping, ImportStrategy strategy});

/// 解析并展示导入预览，让用户在入库前核对来源、警告、样例数据与字段映射（计划书 §3.7）。
///
/// 返回用户确认的映射与策略；取消返回 null。**解析规则全在内核**，这里只负责展示与选择。
Future<ImportDecision?> showImportPreview(
  BuildContext context, {
  required String content,
  required String sourceName,
  required Future<ImportPreview> Function(String content, {ColumnMapping? mapping}) parse,
}) =>
    showDialog<ImportDecision>(
      context: context,
      builder: (_) => _ImportPreviewDialog(content: content, sourceName: sourceName, parse: parse),
    );

class _ImportPreviewDialog extends StatefulWidget {
  const _ImportPreviewDialog({required this.content, required this.sourceName, required this.parse});

  final String content;
  final String sourceName;
  final Future<ImportPreview> Function(String content, {ColumnMapping? mapping}) parse;

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  ImportPreview? _preview;
  ColumnMapping? _mapping;
  ImportStrategy _strategy = ImportStrategy.skip;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  /// 重新解析。改映射后必须回到内核重算，而不是在 Dart 里另写一套列取值逻辑。
  Future<void> _load(ColumnMapping? mapping) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await widget.parse(widget.content, mapping: mapping);
      if (!mounted) return;
      setState(() {
        _preview = p;
        _mapping = p.mapping;
      });
    } on CoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remap(ImportField field, int? column) {
    final next = (_mapping ?? const ColumnMapping({})).withField(field, column);
    setState(() => _mapping = next);
    _load(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final p = _preview;
    return AlertDialog(
      title: Text(context.tr(AppStrings.importPreviewTitle)),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.trf(AppStrings.importPreviewSource, {'source': widget.sourceName}),
                style: context.text.bodySmall,
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Text(_error!, style: context.text.bodyMedium?.copyWith(color: c.danger))
              else if (p == null)
                const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
              else ...[
                Text(
                  context.trf(AppStrings.importPreviewCounts, {
                    'rows': '${p.totalRows}',
                    'items': '${p.importable}',
                    'skipped': '${p.skipped}',
                  }),
                  style: context.text.bodyMedium,
                ),
                if (p.importable == 0) ...[
                  const SizedBox(height: 8),
                  Text(context.tr(AppStrings.importPreviewEmpty), style: context.text.bodySmall?.copyWith(color: c.warning)),
                ],
                if (p.warnings.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(context.tr(AppStrings.importPreviewWarnings), style: context.text.titleMedium),
                  const SizedBox(height: 6),
                  for (final w in p.warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(Icons.info_outline_rounded, size: 14, color: c.warning),
                        const SizedBox(width: 6),
                        Expanded(child: Text(w, style: context.text.bodySmall)),
                      ]),
                    ),
                ],
                if (p.canMapColumns) ...[
                  const SizedBox(height: 14),
                  Text(context.tr(AppStrings.importPreviewMapping), style: context.text.titleMedium),
                  const SizedBox(height: 6),
                  for (final f in ImportField.values) _mappingRow(context, f, p),
                ],
                const SizedBox(height: 14),
                Text(context.tr(AppStrings.importPreviewStrategy), style: context.text.titleMedium),
                const SizedBox(height: 6),
                // 用 ListTile + 图标而不是 RadioListTile：后者的 groupValue/onChanged 已废弃，
                // 换成 RadioGroup 祖先在这套布局里没有生效，选中态不会变。显式写法行为可控。
                for (final s in ImportStrategy.values)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _strategy == s ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: _strategy == s ? context.zo.accent : context.zo.textFaint,
                    ),
                    title: Text(_strategyLabel(context, s), style: context.text.bodyMedium),
                    onTap: () => setState(() => _strategy = s),
                  ),
                if (p.sampleRows.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    context.trf(AppStrings.importPreviewTruncated, {'n': '${p.sampleRows.length}'}),
                    style: context.text.labelSmall,
                  ),
                  const SizedBox(height: 6),
                  _sampleTable(context, p),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr(AppStrings.cancel))),
        FilledButton(
          onPressed: p == null || _busy || p.importable == 0
              ? null
              : () => Navigator.pop(context, (mapping: _mapping ?? const ColumnMapping({}), strategy: _strategy)),
          child: Text(context.tr(AppStrings.importPreviewConfirm)),
        ),
      ],
    );
  }

  Widget _mappingRow(BuildContext context, ImportField field, ImportPreview p) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 108, child: Text(_fieldLabel(context, field), style: context.text.bodyMedium)),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButton<int?>(
            isExpanded: true,
            value: _mapping?[field],
            underline: const SizedBox.shrink(),
            items: [
              DropdownMenuItem<int?>(value: null, child: Text(context.tr(AppStrings.importPreviewUnmapped))),
              for (final (i, header) in p.headers.indexed)
                DropdownMenuItem<int?>(
                  value: i,
                  child: Text(
                    '${context.trf(AppStrings.importPreviewColumn, {'n': '${i + 1}'})} · $header',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy ? null : (v) => _remap(field, v),
          ),
        ),
      ]),
    );
  }

  /// 样例表只展示原始列，**不展示解析后的密码**：预览的目的是核对列对应关系，不是看明文。
  Widget _sampleTable(BuildContext context, ImportPreview p) {
    final c = context.zo;
    return ZoPanel(
      padding: const EdgeInsets.all(8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              for (final h in p.headers)
                SizedBox(
                  width: 120,
                  child: Text(h, style: context.text.labelSmall, overflow: TextOverflow.ellipsis),
                ),
            ]),
            const SizedBox(height: 4),
            for (final row in p.sampleRows.take(5))
              Row(children: [
                for (var i = 0; i < p.headers.length; i++)
                  SizedBox(
                    width: 120,
                    child: Text(
                      i < row.length ? row[i] : '',
                      style: context.text.bodySmall?.copyWith(color: c.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ]),
          ],
        ),
      ),
    );
  }
}

String _strategyLabel(BuildContext context, ImportStrategy s) => context.tr(switch (s) {
      ImportStrategy.skip => AppStrings.importStrategySkip,
      ImportStrategy.overwrite => AppStrings.importStrategyOverwrite,
      ImportStrategy.keepBoth => AppStrings.importStrategyKeepBoth,
    });

/// 字段标签复用既有文案表常量，不再新造一套字段名。
String _fieldLabel(BuildContext context, ImportField f) => context.tr(switch (f) {
      ImportField.title => AppStrings.titleLabel,
      ImportField.url => AppStrings.fieldWebsite,
      ImportField.username => AppStrings.fieldUsername,
      ImportField.password => AppStrings.fieldPassword,
      ImportField.totp => AppStrings.twoFactorCoverage,
      ImportField.notes => AppStrings.fieldNotes,
      ImportField.favorite => AppStrings.sectionFavorites,
      ImportField.category => AppStrings.sidebarCategories,
      ImportField.tags => AppStrings.tagLabel,
      ImportField.kind => AppStrings.conflictFieldKind,
      ImportField.fields => AppStrings.customFields,
    });
