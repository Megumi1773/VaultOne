import 'package:flutter/material.dart';

import '../../core/ffi.dart';
import '../../core/models.dart';
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
        _status = 'Secret Key 与本机保存的逐字节一致；恢复码格式有效。';
      });
    } on CoreException catch (e) {
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() {
        _verified = false;
        _error = switch (e.code) {
          'secret_key_mismatch' => 'Secret Key 与本机保存的不一致。请对照恢复套件逐组核对，注意易混字符 I/L/O 与数字 1/0。',
          'invalid_input' => '恢复码格式不正确，应为 R1- 开头、13 组 Crockford Base32。',
          'locked' || 'session_expired' => '保险库已锁定，请解锁后重试。',
          _ => '核对未完成，请稍后重试。',
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
      );
      if (path == null || !canContinue()) return;
      await state.recordBackup('recovery_kit');
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() => _status = '恢复套件已保存到 $path');
    } catch (_) {
      if (mounted && canContinue()) setState(() => _error = '保存失败，请检查目录权限与可用空间。');
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
      );
      if (path == null || !canContinue()) return;
      await state.recordBackup('backup_card');
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() => _status = '备份卡已保存到 $path');
    } catch (_) {
      if (mounted && canContinue()) setState(() => _error = '备份卡导出失败，请检查目录权限与可用空间。');
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
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final state = AppScope.of(context);
    return AlertDialog(
      title: const Text('密钥与备份'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusRow(
                label: '最近本机备份',
                value: state.lastBackupAt == 0 ? '从未记录' : '${_fmtDay(state.lastBackupAt)}（${_kindLabel(state.lastBackupKind)}）',
              ),
              _StatusRow(
                label: '云端备份历史',
                value: '暂无（服务端备份记录端点未实现）',
                faint: true,
              ),
              const SizedBox(height: 10),
              Text(
                '本机只保存「最近一次导出」这一事实，不保存文件路径与内容。恢复套件与备份卡都可以在这里重新导出；'
                '为避免他人趁保险库未锁定时拿到凭据，重新导出前需要你重新提供恢复材料。',
                style: context.text.bodySmall?.copyWith(color: c.textFaint),
              ),
              const SizedBox(height: 18),
              SectionLabel('恢复材料核对'),
              const SizedBox(height: 8),
              ZoTextField(
                controller: _secretKey,
                label: 'Secret Key',
                hint: 'V1-XXXXXX-XXXXXX-…',
                mono: true,
                enabled: !_verified,
                onChanged: (_) => _invalidate(),
              ),
              const SizedBox(height: 10),
              ZoTextField(
                controller: _recoveryCode,
                label: 'Recovery Code',
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
                  Expanded(child: Text(_status ?? '核对通过', style: context.text.bodySmall?.copyWith(color: c.success))),
                ]),
              ] else ...[
                const SizedBox(height: 12),
                ZoButton(label: '核对', icon: Icons.spellcheck_rounded, dense: true, loading: _checking, onPressed: _checking ? null : _verify),
              ],
              const SizedBox(height: 18),
              SectionLabel('重新导出'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ZoButton(
                    label: '恢复套件（PDF）',
                    icon: Icons.picture_as_pdf_outlined,
                    dense: true,
                    variant: ZoButtonVariant.secondary,
                    onPressed: _verified && !_busy ? _saveKit : null,
                  ),
                  ZoButton(
                    label: '备份卡（PNG 700×900）',
                    icon: Icons.image_outlined,
                    dense: true,
                    variant: ZoButtonVariant.secondary,
                    onPressed: _verified && !_busy ? _saveCard : null,
                  ),
                  ZoButton(
                    label: '查看 Secret Key',
                    icon: Icons.visibility_outlined,
                    dense: true,
                    variant: ZoButtonVariant.ghost,
                    onPressed: _verified ? _revealSecretKey : null,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '恢复套件与备份卡都等价于明文凭据，导出后请按同等级别保管：打印或存入离线介质，不要放进网盘、邮箱或聊天记录。',
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
      actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('关闭'))],
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

String _kindLabel(String? kind) => switch (kind) {
      'recovery_kit' => '恢复套件 PDF',
      'backup_card' => '备份卡 PNG',
      'wljbak' => '加密备份 .wljbak',
      'csv' => '明文 CSV',
      null => '未记录',
      _ => kind,
    };
