import 'package:flutter/material.dart';

import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../../state/backup_card.dart';
import '../../state/clipboard.dart';
import '../../state/recovery_kit.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';

/// 密钥与备份管理：核对 Secret Key / 恢复码，重新导出恢复套件与备份卡，并显示备份状态。
///
/// 备份材料（Secret Key 与恢复码）本机不完整保存——Secret Key 在系统钥匙串、恢复码只在
/// 生成时展示。因此重新导出前必须由用户提供这两项：Secret Key 与本机保存的**逐字节**比对，
/// 恢复码只校验格式（内容正确性由服务端在真正恢复时判定，界面不谎称已校验）。
Future<void> showBackupManager(BuildContext context) => showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => const BackupManagerDialog(),
    );

class BackupManagerDialog extends StatefulWidget {
  const BackupManagerDialog({super.key});

  @override
  State<BackupManagerDialog> createState() => _BackupManagerDialogState();
}

class _BackupManagerDialogState extends State<BackupManagerDialog> {
  final _secretKey = TextEditingController();
  final _recoveryCode = TextEditingController();

  bool _verified = false;
  bool _checking = false;
  bool _busy = false;
  String? _error;
  String? _status;
  String? _secretKeyCanonical;
  String? _recoveryCodeCanonical;

  @override
  void dispose() {
    _secretKey.dispose();
    _recoveryCode.dispose();
    super.dispose();
  }

  void _invalidate() {
    if (_verified || _error != null) {
      setState(() {
        _verified = false;
        _error = null;
        _secretKeyCanonical = null;
        _recoveryCodeCanonical = null;
      });
    }
  }

  Future<void> _verify() async {
    final state = AppScope.read(context);
    final epoch = state.sessionEpoch;
    setState(() {
      _checking = true;
      _error = null;
      _status = null;
    });
    try {
      final r = await state.verifyRecoveryMaterials(
        secretKey: _secretKey.text,
        recoveryCode: _recoveryCode.text,
      );
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() {
        _verified = true;
        _secretKeyCanonical = r.secretKey;
        _recoveryCodeCanonical = r.recoveryCode;
        _status = context.tr(AppStrings.keyVerifyOk);
      });
    } on CoreException catch (e) {
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() {
        _verified = false;
        _error = switch (e.code) {
          'secret_key_mismatch' => context.tr(AppStrings.keyVerifyMismatch),
          'invalid_input' => context.tr(AppStrings.recoveryCodeInvalid),
          'locked' || 'session_expired' => context.tr(AppStrings.purgeErrorLocked),
          _ => context.tr(AppStrings.verifyIncomplete),
        };
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 核对通过后组装恢复材料。`accountId` 取自当前会话，不重新生成身份。
  ({String accountId, String email, String secretKey, String recoveryCode})? _materials() {
    final state = AppScope.read(context);
    final accountId = state.accountId;
    final email = state.account?.email;
    final sk = _secretKeyCanonical;
    final rc = _recoveryCodeCanonical;
    if (accountId == null || email == null || sk == null || rc == null) return null;
    return (accountId: accountId, email: email, secretKey: sk, recoveryCode: rc);
  }

  Future<void> _saveKit() async {
    final m = _materials();
    if (m == null) return;
    final state = AppScope.read(context);
    final epoch = state.sessionEpoch;
    bool canContinue() => mounted && epoch == state.sessionEpoch;
    setState(() => _busy = true);
    try {
      final path = await RecoveryKit.save(
        Enrollment(accountId: m.accountId, email: m.email, secretKey: m.secretKey, recoveryCode: m.recoveryCode),
        canContinue: canContinue,
        language: context.language,
      );
      if (path == null || !canContinue()) return;
      await state.recordBackup('recovery_kit');
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() => _status = context.trf(AppStrings.kitSavedTo, {'path': path}));
    } catch (_) {
      if (mounted && canContinue()) setState(() => _error = context.tr(AppStrings.saveFailedDisk));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveCard() async {
    final m = _materials();
    if (m == null) return;
    final state = AppScope.read(context);
    final epoch = state.sessionEpoch;
    bool canContinue() => mounted && epoch == state.sessionEpoch;
    setState(() => _busy = true);
    try {
      final path = await BackupCard.save(
        BackupCardData(email: m.email, secretKey: m.secretKey, recoveryCode: m.recoveryCode, generatedAt: DateTime.now()),
        canContinue: canContinue,
        language: context.language,
      );
      if (path == null || !canContinue()) return;
      await state.recordBackup('backup_card');
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() => _status = context.trf(AppStrings.backupCardSavedTo, {'path': path}));
    } catch (_) {
      if (mounted && canContinue()) setState(() => _error = context.tr(AppStrings.backupCardFailed));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revealSecretKey() async {
    final sk = _secretKeyCanonical;
    if (sk == null) return;
    final state = AppScope.read(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Secret Key'),
        content: SelectableText(sk, style: monoStyle(ctx, size: 15, weight: FontWeight.w600)),
        actions: [
          TextButton(
            onPressed: () => ClipboardService.copy(sk, label: 'Secret Key', clearAfterSeconds: state.settings.clipboardSeconds),
            child: Text(context.tr(AppStrings.copy)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr(AppStrings.close)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final state = AppScope.of(context);
    return AlertDialog(
      title: Text(context.tr(AppStrings.sectionKeyBackup)),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusRow(
                label: context.tr(AppStrings.lastLocalBackup),
                value: state.lastBackupAt == 0
                    ? context.tr(AppStrings.neverRecorded)
                    : '${_fmtDay(state.lastBackupAt)}（${_kindLabel(context, state.lastBackupKind)}）',
              ),
              _StatusRow(
                label: context.tr(AppStrings.cloudBackupHistory),
                value: context.tr(AppStrings.cloudBackupHistoryNone),
                faint: true,
              ),
              const SizedBox(height: 10),
              Text(
                context.tr(AppStrings.backupManagerBody),
                style: context.text.bodySmall?.copyWith(color: c.textFaint),
              ),
              const SizedBox(height: 18),
              SectionLabel(context.tr(AppStrings.verifyMaterials)),
              const SizedBox(height: 8),
              ZoTextField(
                controller: _secretKey,
                label: AppStrings.secretKeyLabel,
                hint: 'V1-XXXXXX-XXXXXX-…',
                mono: true,
                enabled: !_verified,
                onChanged: (_) => _invalidate(),
              ),
              const SizedBox(height: 10),
              ZoTextField(
                controller: _recoveryCode,
                label: AppStrings.recoveryCodeLabel,
                hint: 'R1-XXXX-XXXX-…',
                mono: true,
                enabled: !_verified,
                onChanged: (_) => _invalidate(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: context.text.bodySmall?.copyWith(color: c.danger)),
              ],
              if (_verified) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Icon(Icons.verified_rounded, size: 16, color: c.success),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _status ?? context.tr(AppStrings.verifyPassed),
                      style: context.text.bodySmall?.copyWith(color: c.success),
                    ),
                  ),
                ]),
              ] else ...[
                const SizedBox(height: 12),
                ZoButton(
                  label: context.tr(AppStrings.verifyAction),
                  icon: Icons.spellcheck_rounded,
                  dense: true,
                  loading: _checking,
                  onPressed: _checking ? null : _verify,
                ),
              ],
              const SizedBox(height: 18),
              SectionLabel(context.tr(AppStrings.reExport)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ZoButton(
                    label: context.tr(AppStrings.recoveryKitPdfShort),
                    icon: Icons.picture_as_pdf_outlined,
                    dense: true,
                    variant: ZoButtonVariant.secondary,
                    onPressed: _verified && !_busy ? _saveKit : null,
                  ),
                  ZoButton(
                    label: context.tr(AppStrings.backupCardShort),
                    icon: Icons.image_outlined,
                    dense: true,
                    variant: ZoButtonVariant.secondary,
                    onPressed: _verified && !_busy ? _saveCard : null,
                  ),
                  ZoButton(
                    label: context.tr(AppStrings.viewSecretKey),
                    icon: Icons.visibility_outlined,
                    dense: true,
                    variant: ZoButtonVariant.ghost,
                    onPressed: _verified ? _revealSecretKey : null,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                context.tr(AppStrings.backupCredentialWarning),
                style: context.text.bodySmall?.copyWith(color: c.textFaint),
              ),
              if (_verified && _status != null && _error == null) ...[
                const SizedBox(height: 10),
                Text(_status!, style: context.text.bodySmall?.copyWith(color: c.textMuted)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.tr(AppStrings.close)),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value, this.faint = false});

  final String label;
  final String value;
  final bool faint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 96, child: Text(label, style: context.text.bodySmall?.copyWith(color: context.zo.textFaint))),
            Expanded(child: Text(value, style: context.text.bodyMedium?.copyWith(color: faint ? context.zo.textFaint : context.zo.text))),
          ],
        ),
      );
}

String _fmtDay(int unix) {
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String _kindLabel(BuildContext context, String? kind) => switch (kind) {
      'recovery_kit' => context.tr(AppStrings.backupKindRecoveryKit),
      'backup_card' => context.tr(AppStrings.backupKindCard),
      'wljbak' => context.tr(AppStrings.backupKindWljbak),
      'csv' => context.tr(AppStrings.backupKindCsv),
      _ => context.tr(AppStrings.neverRecorded),
    };
