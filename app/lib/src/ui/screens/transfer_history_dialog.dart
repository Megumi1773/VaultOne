import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import 'item_detail.dart' show confirmDialog, formatTime;

/// 导入 / 导出历史（计划书 §3.7）。
///
/// 记录由内核在每次传输完成时写入（本机、以 Vault Key 密封、不参与同步）；这里只负责展示与清空。
class TransferHistoryDialog extends StatefulWidget {
  const TransferHistoryDialog({super.key, required this.load, required this.clear});

  final Future<List<TransferRecord>> Function() load;
  final Future<void> Function() clear;

  @override
  State<TransferHistoryDialog> createState() => _TransferHistoryDialogState();
}

class _TransferHistoryDialogState extends State<TransferHistoryDialog> {
  List<TransferRecord>? _history;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await widget.load();
    if (mounted) setState(() => _history = list);
  }

  Future<void> _clear() async {
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.transferClear),
      body: context.tr(AppStrings.transferClearConfirm),
      confirm: context.tr(AppStrings.transferClear),
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.clear();
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = _history;
    return AlertDialog(
      title: Text(context.tr(AppStrings.transferHistory)),
      content: SizedBox(
        width: 560,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.tr(AppStrings.transferHistorySubtitle), style: context.text.bodySmall),
            const SizedBox(height: 10),
            Expanded(
              child: history == null
                  ? const Center(child: CircularProgressIndicator())
                  : history.isEmpty
                      ? Center(child: Text(context.tr(AppStrings.transferNoHistory), style: context.text.bodySmall))
                      : ListView.separated(
                          itemCount: history.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: context.zo.border),
                          itemBuilder: (_, i) => _row(context, history[i]),
                        ),
            ),
          ],
        ),
      ),
      actions: [
        if (history != null && history.isNotEmpty)
          TextButton(
            onPressed: _busy ? null : _clear,
            child: Text(context.tr(AppStrings.transferClear)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr(AppStrings.close))),
      ],
    );
  }

  Widget _row(BuildContext context, TransferRecord r) {
    final c = context.zo;
    final importing = r.direction == TransferDirection.import;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            importing ? Icons.download_rounded : Icons.upload_rounded,
            size: 16,
            color: importing ? c.accent : c.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      context.tr(importing ? AppStrings.transferImport : AppStrings.exportAction),
                      style: context.text.bodyMedium,
                    ),
                    const SizedBox(width: 8),
                    ZoTag(r.format, color: c.textMuted),
                    const Spacer(),
                    Text(formatTime(r.at), style: context.text.labelSmall?.copyWith(color: c.textFaint)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  r.source.isEmpty
                      ? context.tr(AppStrings.transferNoSource)
                      : context.trf(AppStrings.transferSource, {'name': r.source}),
                  style: context.text.bodySmall?.copyWith(color: c.textMuted),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  context.trf(AppStrings.transferCounts, {
                    'added': '${r.added}',
                    'updated': '${r.updated}',
                    'duplicates': '${r.duplicates}',
                    'skipped': '${r.skipped}',
                  }),
                  style: context.text.labelSmall?.copyWith(color: c.textMuted),
                ),
                Text(
                  context.trf(AppStrings.transferBytes, {'n': '${r.bytes}'}),
                  style: context.text.labelSmall?.copyWith(color: c.textFaint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 以路由形式打开历史。
Future<void> showTransferHistory(
  BuildContext context, {
  required Future<List<TransferRecord>> Function() load,
  required Future<void> Function() clear,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => TransferHistoryDialog(load: load, clear: clear),
    );
