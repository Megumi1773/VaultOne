import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../../state/desktop_shell.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
import 'backup_dialog.dart';
import 'conflicts_page.dart';
import 'feedback_page.dart';
import 'item_detail.dart' show confirmDialog;

/// 设置：账户、解锁与安全、云同步与设备、数据导入、桌面托盘与快捷键、浏览器扩展、外观、诊断、关于与法律、危险操作。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 720;
    return ListView(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 40, narrow ? 16 : 36, narrow ? 16 : 40, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Title(),
                _AccountSection(),
                _KeyBackupSection(),
                _SecuritySection(),
                _SyncSection(),
                _ConflictSection(),
                _DataSection(),
                _DesktopSection(),
                _BrowserSection(),
                _AppearanceSection(),
                _DiagnosticsSection(),
                _AboutSection(),
                _DangerSection(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Title extends StatelessWidget {
  const _Title();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(context.tr(AppStrings.settings), style: context.text.headlineMedium),
      );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionLabel(title),
            const SizedBox(height: 10),
            ZoPanel(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6), child: Column(children: _divided(context, children))),
          ],
        ),
      );

  static List<Widget> _divided(BuildContext context, List<Widget> items) => [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(color: context.zo.border),
          items[i],
        ],
      ];
}

class _Row extends StatelessWidget {
  const _Row({required this.title, this.subtitle, this.trailing, this.stackOnNarrow = false});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// 窄屏时把操作控件换到标题下方。用于 SegmentedButton 这类自身较宽、无法再压缩的控件，
  /// 否则在手机宽度下会把整行挤到横向溢出。
  final bool stackOnNarrow;

  @override
  Widget build(BuildContext context) {
    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: context.text.titleMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 3),
          Text(subtitle!, style: context.text.bodySmall),
        ],
      ],
    );
    if (trailing == null) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Row(children: [Expanded(child: label)]));
    }
    final stacked = stackOnNarrow && MediaQuery.sizeOf(context).width < 720;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                const SizedBox(height: 10),
                Align(alignment: Alignment.centerLeft, child: trailing!),
              ],
            )
          : Row(
              children: [
                Expanded(child: label),
                const SizedBox(width: 16),
                trailing!,
              ],
            ),
    );
  }
}

/// 时间格式化；`unix` 为空或 0 时返回空串，由调用方按当前语言显示「从未」。
String _fmtTime(int? unix) {
  if (unix == null || unix == 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 导入结果文案。`duplicates` / `skipped` 为 0 时不显示对应片段。
String _importSummaryText(
  BuildContext context, {
  required String source,
  required int added,
  required int duplicates,
  required int skipped,
}) {
  final suffix = '${duplicates > 0 ? context.trf(AppStrings.importDuplicates, {'n': duplicates}) : ''}'
      '${skipped > 0 ? context.trf(AppStrings.importSkipped, {'n': skipped}) : ''}';
  if (source.isEmpty) {
    return context.trf(AppStrings.importBackupSummary, {'added': added, 'duplicates': suffix, 'skipped': ''});
  }
  return context.trf(AppStrings.importSummary, {
    'source': source,
    'added': added,
    'duplicates': suffix,
    'skipped': '',
  });
}

/// 通用：要求输入主密码的对话框，返回输入值（取消返回 null）。
Future<String?> askMasterPassword(BuildContext context, {required String title, String? body, String confirm = ''}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => _MasterPasswordDialog(title: title, body: body, confirm: confirm),
  );
}

/// 主密码输入对话框。控制器由本 State 持有并在 [dispose] 释放：
/// 若改用 `showDialog(...).whenComplete(ctrl.dispose)`，对话框退场动画期间
/// 内部 `TextField` 仍会重建并重新监听控制器，会命中 “used after being disposed”。
class _MasterPasswordDialog extends StatefulWidget {
  const _MasterPasswordDialog({required this.title, this.body, required this.confirm});

  final String title;
  final String? body;
  final String confirm;

  @override
  State<_MasterPasswordDialog> createState() => _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends State<_MasterPasswordDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctrl.text);

  @override
  Widget build(BuildContext context) {
    final ctx = context;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: ctx.text.headlineSmall),
              if (widget.body != null) ...[
                const SizedBox(height: 8),
                Text(widget.body!, style: ctx.text.bodyMedium?.copyWith(color: ctx.zo.textMuted)),
              ],
              const SizedBox(height: 18),
              ZoTextField(
                controller: _ctrl,
                label: context.tr(AppStrings.masterPassword),
                obscure: true,
                autofocus: true,
                prefixIcon: Icons.key_rounded,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                ZoButton(label: ctx.tr(AppStrings.cancel), variant: ZoButtonVariant.ghost, onPressed: () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                ZoButton(label: widget.confirm, onPressed: _submit),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── 账户 ─────────────────────────

class _AccountSection extends StatelessWidget {
  const _AccountSection();

  /// 查看 Secret Key 是敏感操作：先在备份对话框里用「重输 Secret Key + 恢复码」做字节级核对，
  /// 核对通过后才能查看或重新导出恢复材料。仅凭主密码即可查看会让未锁定的设备成为旁路。
  Future<void> _showSecretKey(BuildContext context) => showBackupManager(context);

  Future<void> _changePassword(BuildContext context) async {
    final done = await showDialog<bool>(context: context, builder: (_) => const _ChangePasswordDialog());
    if (done == true && context.mounted) showZoMessage(context, context.tr(AppStrings.masterPasswordUpdated));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final a = state.account;
    return _Section(title: context.tr(AppStrings.sectionAccount), children: [
      _Row(title: a?.email ?? AppStrings.placeholder, subtitle: context.trf(AppStrings.accountIdLabel, {'id': a?.accountId ?? AppStrings.placeholder})),
      _Row(
        title: context.tr(AppStrings.keyDerivation),
        subtitle: a?.kdfSummary ?? AppStrings.placeholder,
        trailing: ZoTag(context.trf(AppStrings.itemCountTag, {'count': a?.itemCount ?? 0})),
      ),
      _Row(
        title: 'Secret Key',
        subtitle: context.tr(AppStrings.secretKeyRowSubtitle),
        trailing: ZoButton(label: context.tr(AppStrings.verifyAndView), dense: true, variant: ZoButtonVariant.secondary, onPressed: () => _showSecretKey(context)),
      ),
      _Row(
        title: context.tr(AppStrings.changeMasterPassword),
        subtitle: context.tr(AppStrings.changeMasterPasswordSubtitle),
        trailing: ZoButton(label: context.tr(AppStrings.labelUpdated), dense: true, variant: ZoButtonVariant.secondary, onPressed: () => _changePassword(context)),
      ),
    ]);
  }
}

/// 密钥与备份：本机备份状态 + 重新导出恢复套件 / 备份卡入口。
class _KeyBackupSection extends StatelessWidget {
  const _KeyBackupSection();

  static String _kindLabel(BuildContext context, String? kind) => switch (kind) {
        'recovery_kit' => context.tr(AppStrings.backupKindRecoveryKit),
        'backup_card' => context.tr(AppStrings.backupKindCard),
        'wljbak' => context.tr(AppStrings.backupKindWljbak),
        'csv' => context.tr(AppStrings.backupKindCsv),
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final at = state.lastBackupAt;
    final kind = state.lastBackupKind;
    final summary = at == 0
        ? context.tr(AppStrings.backupNever)
        : context.trf(AppStrings.backupLast, {'time': _fmtTime(at), 'kind': _kindLabel(context, kind)});
    return _Section(title: context.tr(AppStrings.sectionKeyBackup), children: [
      _Row(
        title: context.tr(AppStrings.backupStatus),
        subtitle: '$summary\n${context.tr(AppStrings.backupCloudNote)}',
        trailing: at == 0
            ? ZoTag(context.tr(AppStrings.backupMissing), color: context.zo.danger, icon: Icons.error_outline_rounded)
            : ZoTag(context.tr(AppStrings.backupPresent), color: context.zo.success, icon: Icons.check_circle_outline_rounded),
      ),
      _Row(
        title: context.tr(AppStrings.recoveryKitAndCard),
        subtitle: context.tr(AppStrings.recoveryKitAndCardSubtitle),
        trailing: ZoButton(label: context.tr(AppStrings.manageAction), dense: true, variant: ZoButtonVariant.secondary, onPressed: () => showBackupManager(context)),
      ),
    ]);
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _cur = TextEditingController();
  final _next = TextEditingController();
  final _next2 = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _cur.dispose();
    _next.dispose();
    _next2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_next.text.characters.length < 10) return setState(() => _error = context.tr(AppStrings.masterPasswordTooShort));
    if (VaultApi.strength(_next.text).score < 3) return setState(() => _error = context.tr(AppStrings.newPasswordTooWeak));
    if (_next.text != _next2.text) return setState(() => _error = context.tr(AppStrings.passwordMismatch));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).changePassword(_cur.text, _next.text);
      if (mounted) Navigator.pop(context, true);
    } on CoreException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.tr(AppStrings.changeMasterPassword), style: context.text.headlineSmall),
                const SizedBox(height: 18),
                ZoTextField(controller: _cur, label: context.tr(AppStrings.currentMasterPassword), obscure: true, autofocus: true),
                const SizedBox(height: 14),
                ZoTextField(controller: _next, label: context.tr(AppStrings.newMasterPassword), obscure: true, onChanged: (_) => setState(() {})),
                const SizedBox(height: 8),
                StrengthMeter(strength: VaultApi.strength(_next.text)),
                const SizedBox(height: 14),
                ZoTextField(controller: _next2, label: context.tr(AppStrings.confirmNewMasterPassword), obscure: true, error: _error, onSubmitted: (_) => _submit()),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  ZoButton(label: context.tr(AppStrings.cancel), variant: ZoButtonVariant.ghost, onPressed: _busy ? null : () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  ZoButton(label: context.tr(AppStrings.updateMasterPassword), loading: _busy, onPressed: _submit),
                ]),
              ],
            ),
          ),
        ),
      );
}

// ───────────────────────── 解锁与安全 ─────────────────────────

class _SecuritySection extends StatelessWidget {
  const _SecuritySection();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = state.settings;
    return _Section(title: context.tr(AppStrings.sectionSecurity), children: [
      if (state.biometricsAvailable)
        _Row(
          title: context.tr(AppStrings.biometricUnlock),
          subtitle: context.tr(AppStrings.biometricUnlockSubtitle),
          trailing: Switch(
            value: state.quickUnlockEnabled,
            onChanged: (v) async {
              try {
                await state.setQuickUnlock(v);
              } catch (e) {
                if (context.mounted) showZoMessage(context, context.tr(v ? AppStrings.biometricEnable : AppStrings.biometricDisable), error: true);
              }
            },
          ),
        ),
      _Row(
        title: context.tr(AppStrings.autoLock),
        subtitle: context.tr(AppStrings.autoLockSubtitle),
        trailing: DropdownButton<int>(
          value: s.autoLockMinutes,
          underline: const SizedBox.shrink(),
          items: [
            for (final m in const [1, 5, 10, 30])
              DropdownMenuItem(value: m, child: Text(context.trf(AppStrings.minutes, {'n': m}))),
            DropdownMenuItem(value: 0, child: Text(context.tr(AppStrings.never))),
          ],
          onChanged: (v) => state.updateSettings(s.copyWith(autoLockMinutes: v)),
        ),
      ),
      _Row(
        title: context.tr(AppStrings.lockOnMinimize),
        trailing: Switch(value: s.lockOnMinimize, onChanged: (v) => state.updateSettings(s.copyWith(lockOnMinimize: v))),
      ),
      _Row(
        title: context.tr(AppStrings.clipboardAutoClear),
        subtitle: context.tr(AppStrings.clipboardAutoClearSubtitle),
        trailing: DropdownButton<int>(
          value: s.clipboardSeconds,
          underline: const SizedBox.shrink(),
          items: [
            for (final n in const [15, 30, 60, 90])
              DropdownMenuItem(value: n, child: Text(context.trf(AppStrings.seconds, {'n': n}))),
          ],
          onChanged: (v) => state.updateSettings(s.copyWith(clipboardSeconds: v)),
        ),
      ),
    ]);
  }
}

// ───────────────────────── 云同步 ─────────────────────────

class _SyncSection extends StatefulWidget {
  const _SyncSection();

  @override
  State<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<_SyncSection> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() f, {String? ok}) async {
    setState(() => _busy = true);
    try {
      await f();
      if (ok != null && mounted) showZoMessage(context, ok);
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final remote = state.remote;
    if (remote == null) {
      return _Section(title: context.tr(AppStrings.sectionCloudAccount), children: [
        _Row(
          title: context.tr(AppStrings.cloudSetupPending),
          subtitle: context.tr(AppStrings.cloudSetupPendingBody),
        ),
      ]);
    }

    final (label, color) = switch (state.syncState) {
      SyncState.syncing => (context.tr(AppStrings.syncing), context.zo.accent),
      SyncState.error => (
        context.trf(AppStrings.syncFailed, {'reason': context.tr(state.syncError ?? '')}),
        context.zo.danger,
      ),
      SyncState.needsReconnect => (context.tr(AppStrings.sessionExpired), context.zo.warning),
      _ => (context.tr(AppStrings.autoSync), context.zo.success),
    };
    return _Section(title: context.tr(AppStrings.sectionSync), children: [
      _Row(
        title: remote.serverUrl,
        subtitle: context.trf(AppStrings.deviceSummary, {
          'device': remote.deviceName,
          'time': _fmtTime(remote.lastSyncAt),
          'pending': remote.pending,
        }),
        trailing: ZoTag(label.length > 18 ? '${label.substring(0, 18)}…' : label, color: color),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (state.syncState == SyncState.needsReconnect)
            ZoButton(
              label: context.tr(AppStrings.revalidate),
              icon: Icons.login_rounded,
              onPressed: () async {
                final reconnectedText = context.tr(AppStrings.reconnected);
                final pw = await askMasterPassword(context, title: context.tr(AppStrings.reconnectSync));
                if (pw != null && pw.isNotEmpty) await _run(() => state.reconnect(pw), ok: reconnectedText);
              },
            )
          else
            ZoButton(
              label: context.tr(AppStrings.syncNow),
              icon: Icons.sync_rounded,
              loading: _busy || state.syncState == SyncState.syncing,
              onPressed: () => _run(() async {
                final mergedText = context.trf(AppStrings.mergedItems, {'n': 0});
                final r = await state.syncNow();
                if (r != null && r.merged > 0 && mounted) {
                  showZoMessage(this.context, AppStrings.format(mergedText, {'n': r.merged}));
                }
              }),
            ),
          ZoButton(
            label: context.tr(AppStrings.deviceManagement),
            icon: Icons.devices_other_outlined,
            variant: ZoButtonVariant.secondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesPage())),
          ),
          ZoButton(
            label: context.tr(AppStrings.signOutCloudLock),
            variant: ZoButtonVariant.ghost,
            onPressed: _busy ? null : () async {
              final ok = await confirmDialog(
                context,
                title: context.tr(AppStrings.signOutCloudTitle),
                body: context.tr(AppStrings.signOutCloudBody),
                confirm: context.tr(AppStrings.signOutAndLock),
              );
              if (ok == true) await _run(state.signOut);
            },
          ),
          ZoButton(
            label: context.tr(AppStrings.securityLog),
            icon: Icons.history_rounded,
            variant: ZoButtonVariant.secondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuditLogPage())),
          ),
        ]),
      ),
    ]);
  }
}

/// 设备管理：批准新设备、撤销丢失设备（F-01）。
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  late Future<List<DeviceDto>> _future = VaultApi.listDevices();

  void _reload() => setState(() => _future = VaultApi.listDevices());

  Future<void> _act(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (mounted) showZoMessage(context, ok);
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    }
    _reload();
  }

  IconData _icon(String p) => switch (p) {
        'android' || 'ios' => Icons.phone_iphone_rounded,
        'macos' => Icons.laptop_mac_rounded,
        'extension' => Icons.extension_outlined,
        _ => Icons.desktop_windows_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr(AppStrings.deviceManagement)), backgroundColor: c.bg, surfaceTintColor: Colors.transparent),
      body: FutureBuilder<List<DeviceDto>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}', style: context.text.bodyMedium));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final devices = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(context.tr(AppStrings.deviceManagementSubtitle), style: context.text.bodySmall),
              const SizedBox(height: 14),
              for (final d in devices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ZoPanel(
                    child: Row(children: [
                      Icon(_icon(d.platform), color: d.revoked ? c.textFaint : c.accent),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(child: Text(d.name, style: context.text.titleMedium, overflow: TextOverflow.ellipsis)),
                            if (d.current) ...[
                              const SizedBox(width: 8),
                              ZoTag(context.tr(AppStrings.deviceThis), color: c.accent),
                            ],
                            if (d.revoked) ...[
                              const SizedBox(width: 8),
                              ZoTag(context.tr(AppStrings.deviceRevoked), color: c.danger),
                            ],
                            if (!d.approved && !d.revoked) ...[
                              const SizedBox(width: 8),
                              ZoTag(context.tr(AppStrings.devicePending), color: c.warning),
                            ],
                          ]),
                          const SizedBox(height: 4),
                          Text(
                            context.trf(AppStrings.deviceLine, {
                              'platform': d.platform,
                              'created': _fmtTime(d.createdAt.toInt()),
                              'seen': _fmtTime(d.lastSeenAt?.toInt()),
                            }),
                            style: context.text.bodySmall,
                          ),
                        ]),
                      ),
                      if (!d.approved && !d.revoked)
                        ZoButton(
                          label: context.tr(AppStrings.approveAction),
                          dense: true,
                          onPressed: () => _act(() => VaultApi.approveDevice(d.id), context.tr(AppStrings.approvedAction)),
                        ),
                      if (!d.current && !d.revoked) ...[
                        const SizedBox(width: 8),
                        ZoButton(
                          label: context.tr(AppStrings.revokeAction),
                          dense: true,
                          variant: ZoButtonVariant.danger,
                          onPressed: () async {
                            final revokedText = context.tr(AppStrings.deviceRevoked);
                            final ok = await confirmDialog(
                              context,
                              title: context.trf(AppStrings.revokeDeviceTitle, {'name': d.name}),
                              body: context.tr(AppStrings.revokeDeviceBody),
                              confirm: context.tr(AppStrings.revokeAction),
                              danger: true,
                            );
                            if (ok == true) {
                              await _act(() => VaultApi.revokeDevice(d.id), revokedText);
                            }
                          },
                        ),
                      ],
                    ]),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 安全日志（F-09）：登录、新设备、主密码变更、恢复等事件。
class AuditLogPage extends StatelessWidget {
  const AuditLogPage({super.key});

  static const _labelKeys = <String, String>{
    'register': AppStrings.registerAccount,
    'login_ok': AppStrings.auditSignInOk,
    'login_fail': AppStrings.auditSignInFail,
    'device_added': AppStrings.auditDeviceRequest,
    'device_approved': AppStrings.auditDeviceApproved,
    'device_revoked': AppStrings.auditDeviceRevoked,
    'pwd_changed': AppStrings.auditPasswordChanged,
    'recovery_used': AppStrings.auditRecoveryUsed,
    'recovery_fail': AppStrings.auditRecoveryFail,
  };

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr(AppStrings.securityLog)), backgroundColor: c.bg, surfaceTintColor: Colors.transparent),
      body: FutureBuilder<List<AuditEventDto>>(
        future: VaultApi.auditEvents(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: snap.data!.length,
            separatorBuilder: (_, _) => Divider(color: c.border),
            itemBuilder: (context, i) {
              final e = snap.data![i];
              final bad = e.event.contains('fail') || e.event == 'recovery_used';
              return ListTile(
                leading: Icon(bad ? Icons.warning_amber_rounded : Icons.check_circle_outline, color: bad ? c.warning : c.success),
                title: Text(_labelKeys[e.event] == null ? e.event : context.tr(_labelKeys[e.event]!)),
                subtitle: Text('${_fmtTime(e.createdAt.toInt())}${e.deviceId != null ? ' · 设备 ${e.deviceId!.substring(0, 8)}' : ''}'),
              );
            },
          );
        },
      ),
    );
  }
}

// ───────────────────────── 外观 / 诊断 / 关于 ─────────────────────────

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = state.settings;
    return _Section(title: context.tr(AppStrings.sectionAppearance), children: [
      _Row(
        title: context.tr(AppStrings.theme),
        stackOnNarrow: true,
        trailing: SegmentedButton<ThemeModeSetting>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: ThemeModeSetting.system, label: Text(context.tr(AppStrings.themeSystem))),
            ButtonSegment(value: ThemeModeSetting.light, label: Text(context.tr(AppStrings.themeLight))),
            ButtonSegment(value: ThemeModeSetting.dark, label: Text(context.tr(AppStrings.themeDark))),
          ],
          selected: {s.themeMode},
          onSelectionChanged: (v) => state.updateSettings(s.copyWith(themeMode: v.first)),
        ),
      ),
      _Row(
        title: context.tr(AppStrings.language),
        subtitle: context.tr(AppStrings.languageSubtitle),
        stackOnNarrow: true,
        trailing: SegmentedButton<AppLanguage>(
          showSelectedIcon: false,
          segments: [
            for (final l in AppStrings.supported) ButtonSegment(value: l, label: Text(l.label)),
          ],
          selected: {s.language},
          onSelectionChanged: (v) => state.updateSettings(s.copyWith(language: v.first)),
        ),
      ),
    ]);
  }
}

const _importSources = {
  'chrome': 'Chrome / Edge',
  'firefox': 'Firefox',
  'bitwarden': 'Bitwarden',
  'lastpass': 'LastPass',
  '1password': '1Password',
  '1pif': '1Password（1PIF）',
  'csv': 'CSV',
};

class _ConflictSection extends StatelessWidget {
  const _ConflictSection();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return _Section(title: context.tr(AppStrings.sectionConflict), children: [
      _Row(
        title: context.tr(AppStrings.compareConflicts),
        subtitle: context.tr(AppStrings.compareConflictsSubtitle),
        trailing: ZoButton(
          label: context.tr(AppStrings.viewConflicts),
          dense: true,
          variant: ZoButtonVariant.secondary,
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => ConflictsPage(
              listConflicts: VaultApi.listConflicts,
              getConflict: VaultApi.getConflict,
              refreshConflict: VaultApi.refreshConflict,
              resolveConflict: (id, resolution) async {
                await VaultApi.resolveConflict(id, resolution);
                await state.refresh(sync: false);
              },
              onResolved: () => state.scheduleSync(immediate: true),
            ),
          )),
        ),
      ),
    ]);
  }
}

class _DataSection extends StatefulWidget {
  const _DataSection();

  @override
  State<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<_DataSection> {
  bool _busy = false;

  Future<void> _import() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    if (!state.isCurrentSession(epoch)) return;
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV / 1PIF', extensions: ['csv', '1pif', 'txt'], uniformTypeIdentifiers: ['public.comma-separated-values-text', 'public.plain-text', 'public.data']),
    ]);
    if (file == null || !mounted || !state.isCurrentSession(epoch)) return;
    setState(() => _busy = true);
    try {
      final content = await file.readAsString();
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final r = await state.importItems(content);
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final title = context.tr(AppStrings.importDone);
      final summary = _importSummaryText(
        context,
        source: _importSources[r.format] ?? r.format,
        added: r.added,
        duplicates: r.duplicates,
        skipped: r.skipped,
      );
      final dismiss = context.tr(AppStrings.gotIt);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(summary),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(dismiss))],
        ),
      );
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } on FormatException {
      if (mounted) showZoMessage(context, context.tr(AppStrings.notUtf8), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportBackup() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    if (!state.isCurrentSession(epoch)) return;
    setState(() => _busy = true);
    try {
      final data = await state.exportBackup();
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final loc = await getSaveLocation(
        suggestedName: 'vaultone-backup-${DateTime.now().millisecondsSinceEpoch}.wljbak',
        acceptedTypeGroups: [XTypeGroup(label: context.tr(AppStrings.vaultoneBackup), extensions: const ['wljbak'])],
      );
      if (loc == null || !mounted || !state.isCurrentSession(epoch)) return;
      await File(loc.path).writeAsBytes(data, flush: true);
      if (mounted && state.isCurrentSession(epoch)) {
        showZoMessage(context, context.trf(AppStrings.backupSaved, {'bytes': data.length, 'path': loc.path}));
      }
    } on FileSystemException {
      if (mounted && state.isCurrentSession(epoch)) {
        showZoMessage(context, context.tr(AppStrings.backupSaveFailed), error: true);
      }
    } on CoreException catch (e) {
      if (mounted && state.isCurrentSession(epoch)) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    if (!state.isCurrentSession(epoch)) return;
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.csvConfirmTitle),
      body: context.tr(AppStrings.csvConfirmBody),
      confirm: context.tr(AppStrings.stillExport),
      danger: true,
    );
    if (ok != true || !mounted || !state.isCurrentSession(epoch)) return;
    setState(() => _busy = true);
    try {
      final csv = await state.exportCsv();
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final loc = await getSaveLocation(
        suggestedName: 'vaultone-export-${DateTime.now().millisecondsSinceEpoch}.csv',
        acceptedTypeGroups: const [XTypeGroup(label: 'CSV', extensions: ['csv'])],
      );
      if (loc == null || !mounted || !state.isCurrentSession(epoch)) return;
      final saved = await File(loc.path).writeAsString(csv, flush: true);
      final bytes = await saved.length();
      if (mounted && state.isCurrentSession(epoch)) {
        showZoMessage(context, context.trf(AppStrings.csvSaved, {'bytes': bytes, 'path': loc.path}));
      }
    } on FileSystemException {
      if (mounted && state.isCurrentSession(epoch)) {
        showZoMessage(context, context.tr(AppStrings.csvSaveFailed), error: true);
      }
    } on CoreException catch (e) {
      if (mounted && state.isCurrentSession(epoch)) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importBackup() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    if (!state.isCurrentSession(epoch)) return;
    final file = await openFile(acceptedTypeGroups: [
      XTypeGroup(label: context.tr(AppStrings.vaultoneBackup), extensions: const ['wljbak'], uniformTypeIdentifiers: const ['public.data']),
    ]);
    if (file == null || !mounted || !state.isCurrentSession(epoch)) return;
    setState(() => _busy = true);
    try {
      final content = await file.readAsBytes();
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final r = await state.importBackup(content);
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final title = context.tr(AppStrings.importDone);
      final summary = _importSummaryText(
        context,
        source: '',
        added: r.added,
        duplicates: r.duplicates,
        skipped: r.skipped,
      );
      final dismiss = context.tr(AppStrings.gotIt);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(summary),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(dismiss))],
        ),
      );
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Section(title: context.tr(AppStrings.sectionData), children: [
        _Row(
          title: context.tr(AppStrings.importFromOthers),
          subtitle: context.tr(AppStrings.importFromOthersSubtitle),
          trailing: ZoButton(
            label: context.tr(_busy ? AppStrings.importing : AppStrings.chooseFile),
            dense: true,
            variant: ZoButtonVariant.secondary,
            onPressed: _busy ? null : _import,
          ),
        ),
        _Row(
          title: context.tr(AppStrings.exportEncryptedBackup),
          subtitle: context.tr(AppStrings.exportEncryptedBackupSubtitle),
          trailing: ZoButton(label: context.tr(AppStrings.exportAction), dense: true, variant: ZoButtonVariant.secondary, onPressed: _busy ? null : _exportBackup),
        ),
        _Row(
          title: context.tr(AppStrings.exportCsv),
          subtitle: context.tr(AppStrings.exportCsvSubtitle),
          trailing: ZoButton(label: context.tr(AppStrings.exportAction), dense: true, variant: ZoButtonVariant.secondary, onPressed: _busy ? null : _exportCsv),
        ),
        _Row(
          title: context.tr(AppStrings.importFromBackup),
          subtitle: context.tr(AppStrings.importFromBackupSubtitle),
          trailing: ZoButton(label: context.tr(AppStrings.chooseFile), dense: true, variant: ZoButtonVariant.secondary, onPressed: _busy ? null : _importBackup),
        ),
      ]);
}

class _DesktopSection extends StatelessWidget {
  const _DesktopSection();

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return const _AndroidAutofillSection();
    if (!DesktopShell.supported) return const SizedBox.shrink();
    final state = AppScope.of(context);
    final s = state.settings;
    return _Section(title: context.tr(AppStrings.sectionDesktop), children: [
      _Row(
        title: context.tr(AppStrings.keepInTray),
        subtitle: context.tr(AppStrings.keepInTraySubtitle),
        trailing: Switch(value: s.closeToTray, onChanged: (v) => state.updateSettings(s.copyWith(closeToTray: v))),
      ),
      _Row(
        title: context.trf(AppStrings.globalHotkey, {'combo': DesktopShell.hotKeyLabel}),
        subtitle: context.tr(AppStrings.globalHotkeySubtitle),
        trailing: Switch(value: s.globalHotkey, onChanged: (v) => state.updateSettings(s.copyWith(globalHotkey: v))),
      ),
    ]);
  }
}

class _BrowserSection extends StatefulWidget {
  const _BrowserSection();

  @override
  State<_BrowserSection> createState() => _BrowserSectionState();
}

class _BrowserSectionState extends State<_BrowserSection> {
  late Future<List<BrowserClient>> _clients = VaultApi.browserClients();

  PairingRequest? _lastPairing;

  void _reload() => setState(() => _clients = VaultApi.browserClients());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 配对弹窗处理完毕后刷新列表（内核写入配对信息稍晚于 UI 回应）
    final p = AppScope.of(context).pendingPairing;
    if (_lastPairing != null && p == null) {
      _clients = Future.delayed(const Duration(milliseconds: 400), VaultApi.browserClients);
    }
    _lastPairing = p;
  }

  @override
  Widget build(BuildContext context) {
    if (!DesktopShell.supported) return const SizedBox.shrink();
    final state = AppScope.of(context);
    final s = state.settings;
    return _Section(title: context.tr(AppStrings.sectionBrowser), children: [
      _Row(
        title: context.tr(AppStrings.allowBrowserExtension),
        subtitle: context.tr(AppStrings.allowBrowserExtensionSubtitle),
        trailing: Switch(value: s.browserIntegration, onChanged: (v) => state.updateSettings(s.copyWith(browserIntegration: v))),
      ),
      _Row(
        title: context.tr(AppStrings.installExtension),
        subtitle: context.tr(AppStrings.installExtensionSubtitle),
        trailing: ZoIconButton(
          icon: Icons.open_in_new_rounded,
          tooltip: AppConfig.extensionUrl,
          onPressed: () => launchUrl(Uri.parse(AppConfig.extensionUrl)),
        ),
      ),
      FutureBuilder<List<BrowserClient>>(
        future: _clients,
        builder: (context, snap) {
          final list = snap.data ?? const <BrowserClient>[];
          if (list.isEmpty) {
            return _Row(title: context.tr(AppStrings.pairedBrowsers), subtitle: context.tr(AppStrings.noneYet));
          }
          return Column(children: [
            for (final c in list)
              _Row(
                title: c.name,
                subtitle: context.trf(AppStrings.pairedAt, {
                  'created': _fmtTime(c.createdAt),
                  'used': _fmtTime(c.lastUsedAt),
                }),
                trailing: ZoButton(
                  label: context.tr(AppStrings.removeAction),
                  dense: true,
                  variant: ZoButtonVariant.secondary,
                  onPressed: () async {
                    await VaultApi.removeBrowserClient(c.id);
                    _reload();
                  },
                ),
              ),
          ]);
        },
      ),
      _Row(
        title: context.tr(AppStrings.repairConnection),
        subtitle: context.tr(AppStrings.repairConnectionSubtitle),
        trailing: ZoButton(
          label: context.tr(AppStrings.reregister),
          dense: true,
          variant: ZoButtonVariant.secondary,
          onPressed: () async {
            try {
              await VaultApi.registerNativeHost();
              if (context.mounted) showZoMessage(context, context.tr(AppStrings.reregistered));
            } on CoreException catch (e) {
              if (context.mounted) showZoMessage(context, e.message, error: true);
            }
            _reload();
          },
        ),
      ),
    ]);
  }
}

/// Android：引导用户把 VaultOne 设为系统自动填充服务（`MainActivity` 的 `vaultone/platform` 通道）。
class _AndroidAutofillSection extends StatefulWidget {
  const _AndroidAutofillSection();

  @override
  State<_AndroidAutofillSection> createState() => _AndroidAutofillSectionState();
}

class _AndroidAutofillSectionState extends State<_AndroidAutofillSection> with WidgetsBindingObserver {
  static const _channel = MethodChannel('vaultone/platform');
  bool _supported = false;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 从系统设置返回时刷新状态
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final supported = await _channel.invokeMethod<bool>('autofillSupported') ?? false;
    final enabled = await _channel.invokeMethod<bool>('autofillEnabled') ?? false;
    if (!mounted) return;
    setState(() {
      _supported = supported;
      _enabled = enabled;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    return _Section(title: context.tr(AppStrings.sectionAutofill), children: [
      _Row(
        title: context.tr(_enabled ? AppStrings.autofillEnabled : AppStrings.autofillEnable),
        subtitle: context.tr(AppStrings.autofillSubtitle),
        trailing: _enabled
            ? ZoTag(context.tr(AppStrings.enabledTag))
            : ZoButton(
                label: context.tr(AppStrings.openSettings),
                dense: true,
                variant: ZoButtonVariant.secondary,
                onPressed: () => _channel.invokeMethod('openAutofillSettings'),
              ),
      ),
    ]);
  }
}

class _DiagnosticsSection extends StatelessWidget {
  const _DiagnosticsSection();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final s = state.settings;
    return _Section(title: context.tr(AppStrings.sectionDiagnostics), children: [
      _Row(
        title: context.tr(AppStrings.verboseLogs),
        subtitle: context.tr(AppStrings.verboseLogsSubtitle),
        trailing: Switch(value: s.verboseLogs, onChanged: (v) => state.updateSettings(s.copyWith(verboseLogs: v))),
      ),
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
        _Row(
          title: context.tr(AppStrings.logFile),
          subtitle: context.tr(AppStrings.logFileSubtitle),
          trailing: ZoButton(
            label: context.tr(AppStrings.openFolder),
            dense: true,
            variant: ZoButtonVariant.secondary,
            onPressed: () => _openLogsDir(context),
          ),
        ),
    ]);
  }

  /// 在系统文件管理器中打开日志目录。
  ///
  /// 目录 URL 必须以分隔符结尾，否则 Windows 的 ShellExecuteW 会把它当成普通文件，
  /// 既可能打不开、也可能让 shell 长时间阻塞在平台线程上（表现为界面无响应）。
  /// 因此这里显式构造目录形式的 file URL，并保证一定有结尾分隔符。
  Future<void> _openLogsDir(BuildContext context) async {
    try {
      final dir = await getApplicationSupportDirectory();
      var path = '${dir.path}${Platform.pathSeparator}logs';
      if (!path.endsWith(Platform.pathSeparator)) path = '$path${Platform.pathSeparator}';
      final uri = Uri.file(path);
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
        showZoMessage(
          context,
          context.trf(AppStrings.logDirFailed, {'path': '${dir.path}${Platform.pathSeparator}logs'}),
          error: true,
        );
      }
    } catch (_) {
      if (context.mounted) showZoMessage(context, context.tr(AppStrings.logDirFailedGeneric), error: true);
    }
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    Widget link(String title, String url) => _Row(
          title: title,
          trailing: ZoIconButton(icon: Icons.open_in_new_rounded, tooltip: url, onPressed: () => launchUrl(Uri.parse(url))),
        );
    return _Section(title: context.tr(AppStrings.sectionAbout), children: [
      FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) => _Row(
          title: 'VaultOne ${snap.data?.version ?? ''}',
          subtitle: context.trf(AppStrings.buildInfo, {'build': snap.data?.buildNumber ?? '-'}),
        ),
      ),
      link(context.tr(AppStrings.privacyPolicyLink), AppConfig.privacyPolicyUrl),
      link(context.tr(AppStrings.termsLink), AppConfig.termsUrl),
      link(context.tr(AppStrings.sourceAndWhitepaper), AppConfig.sourceUrl),
      _Row(
        title: context.tr(AppStrings.openSourceLicenses),
        trailing: ZoIconButton(
          icon: Icons.chevron_right_rounded,
          tooltip: context.tr(AppStrings.viewLicenses),
          onPressed: () => showLicensePage(context: context, applicationName: 'VaultOne'),
        ),
      ),
      _Row(
        title: context.tr(AppStrings.feedback),
        subtitle: context.tr(AppStrings.feedbackSubtitle),
        trailing: ZoButton(
          label: context.tr(AppStrings.openFeedback),
          dense: true,
          variant: ZoButtonVariant.secondary,
          onPressed: () {
            final state = AppScope.of(context);
            final epoch = state.sessionEpoch;
            if (!state.isCurrentSession(epoch)) return;
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => FeedbackPage(
                newId: state.newFeedbackId,
                submit: state.submitFeedback,
                list: state.listFeedback,
                get: state.getFeedback,
                canContinue: () => state.isCurrentSession(epoch),
                accountId: state.accountId,
              ),
            ));
          },
        ),
      ),
      _Row(
        title: context.tr(AppStrings.contactSupport),
        subtitle: AppConfig.supportEmail,
        trailing: ZoIconButton(
          icon: Icons.mail_outline_rounded,
          tooltip: context.tr(AppStrings.sendEmail),
          onPressed: () => launchUrl(Uri(scheme: 'mailto', path: AppConfig.supportEmail)),
        ),
      ),
    ]);
  }
}

class _DangerSection extends StatelessWidget {
  const _DangerSection();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return _Section(title: context.tr(AppStrings.sectionDanger), children: [
      _Row(
        title: context.tr(AppStrings.wipeLocalData),
        subtitle: context.tr(AppStrings.wipeLocalDataSubtitle),
        trailing: ZoButton(
          label: context.tr(AppStrings.delete),
          dense: true,
          variant: ZoButtonVariant.danger,
          onPressed: () async {
            final ok = await confirmDialog(
              context,
              title: context.tr(AppStrings.wipeConfirmTitle),
              body: context.tr(AppStrings.wipeConfirmBody),
              confirm: context.tr(AppStrings.delete),
              danger: true,
            );
            if (ok == true) await state.wipeThisDevice();
          },
        ),
      ),
      if (state.remote != null)
        _Row(
          title: context.tr(AppStrings.deleteCloudAccount),
          subtitle: context.tr(AppStrings.deleteCloudAccountSubtitle),
          trailing: ZoButton(
            label: context.tr(AppStrings.deleteAccountAction),
            dense: true,
            variant: ZoButtonVariant.danger,
            onPressed: () async {
              final pw = await askMasterPassword(
                context,
                title: context.tr(AppStrings.deleteCloudAccount),
                body: context.tr(AppStrings.deleteCloudAccountBody),
                confirm: context.tr(AppStrings.deletePermanently),
              );
              if (pw == null || pw.isEmpty || !context.mounted) return;
              try {
                await state.deleteCloudAccount(pw);
                if (context.mounted) showZoMessage(context, context.tr(AppStrings.cloudAccountDeleted));
              } on CoreException catch (e) {
                if (context.mounted) showZoMessage(context, e.message, error: true);
              }
            },
          ),
        ),
    ]);
  }
}
