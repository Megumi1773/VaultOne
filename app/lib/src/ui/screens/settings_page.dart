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
import '../../state/app_state.dart';
import '../../state/clipboard.dart';
import '../../state/desktop_shell.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
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
                _SecuritySection(),
                _SyncSection(),
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
        child: Text('设置', style: context.text.headlineMedium),
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
  const _Row({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: context.text.titleMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!, style: context.text.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 16), trailing!],
          ],
        ),
      );
}

String _fmtTime(int? unix) {
  if (unix == null || unix == 0) return '从未';
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// 通用：要求输入主密码的对话框，返回输入值（取消返回 null）。
Future<String?> askMasterPassword(BuildContext context, {required String title, String? body, String confirm = '确认'}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: ctx.text.headlineSmall),
              if (body != null) ...[
                const SizedBox(height: 8),
                Text(body, style: ctx.text.bodyMedium?.copyWith(color: ctx.zo.textMuted)),
              ],
              const SizedBox(height: 18),
              ZoTextField(
                controller: ctrl,
                label: '主密码',
                obscure: true,
                autofocus: true,
                prefixIcon: Icons.key_rounded,
                onSubmitted: (v) => Navigator.pop(ctx, v),
              ),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                ZoButton(label: '取消', variant: ZoButtonVariant.ghost, onPressed: () => Navigator.pop(ctx)),
                const SizedBox(width: 8),
                ZoButton(label: confirm, onPressed: () => Navigator.pop(ctx, ctrl.text)),
              ]),
            ],
          ),
        ),
      ),
    ),
  ).whenComplete(ctrl.dispose);
}

// ───────────────────────── 账户 ─────────────────────────

class _AccountSection extends StatelessWidget {
  const _AccountSection();

  Future<void> _showSecretKey(BuildContext context) async {
    final state = AppScope.read(context);
    final pw = await askMasterPassword(context, title: '查看 Secret Key', body: '为防止旁人查看，请再次输入主密码。');
    if (pw == null || pw.isEmpty || !context.mounted) return;
    try {
      final sk = await state.revealSecretKey(pw);
      if (!context.mounted) return;
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
    } on CoreException catch (e) {
      if (context.mounted) showZoMessage(context, e.message, error: true);
    }
  }

  Future<void> _changePassword(BuildContext context) async {
    final done = await showDialog<bool>(context: context, builder: (_) => const _ChangePasswordDialog());
    if (done == true && context.mounted) showZoMessage(context, '主密码已更新，其他设备同步后需使用新主密码解锁');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final a = state.account;
    return _Section(title: '账户', children: [
      _Row(title: a?.email ?? '—', subtitle: '账户 ID  ${a?.accountId ?? '—'}'),
      _Row(title: '密钥派生', subtitle: a?.kdfSummary ?? '—', trailing: ZoTag('${a?.itemCount ?? 0} 个条目')),
      _Row(
        title: 'Secret Key',
        subtitle: '保存在本机系统钥匙串中。登录新设备时需要它。',
        trailing: ZoButton(label: '查看', dense: true, variant: ZoButtonVariant.secondary, onPressed: () => _showSecretKey(context)),
      ),
      _Row(
        title: '修改主密码',
        subtitle: '只重新封装保险库密钥，条目无需重新加密，秒级完成。',
        trailing: ZoButton(label: '修改', dense: true, variant: ZoButtonVariant.secondary, onPressed: () => _changePassword(context)),
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
    if (_next.text.characters.length < 10) return setState(() => _error = '新主密码至少 10 个字符');
    if (VaultApi.strength(_next.text).score < 3) return setState(() => _error = '新主密码强度不足');
    if (_next.text != _next2.text) return setState(() => _error = '两次输入不一致');
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
                Text('修改主密码', style: context.text.headlineSmall),
                const SizedBox(height: 18),
                ZoTextField(controller: _cur, label: '当前主密码', obscure: true, autofocus: true),
                const SizedBox(height: 14),
                ZoTextField(controller: _next, label: '新主密码', obscure: true, onChanged: (_) => setState(() {})),
                const SizedBox(height: 8),
                StrengthMeter(strength: VaultApi.strength(_next.text)),
                const SizedBox(height: 14),
                ZoTextField(controller: _next2, label: '确认新主密码', obscure: true, error: _error, onSubmitted: (_) => _submit()),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  ZoButton(label: '取消', variant: ZoButtonVariant.ghost, onPressed: _busy ? null : () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  ZoButton(label: '更新主密码', loading: _busy, onPressed: _submit),
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
    return _Section(title: '解锁与安全', children: [
      if (state.biometricsAvailable)
        _Row(
          title: '生物识别解锁',
          subtitle: '使用 Windows Hello / Touch ID / Face ID / 指纹快速解锁。快速解锁密钥保存在系统钥匙串，修改主密码后自动失效。',
          trailing: Switch(
            value: state.quickUnlockEnabled,
            onChanged: (v) async {
              try {
                await state.setQuickUnlock(v);
              } catch (e) {
                if (context.mounted) showZoMessage(context, '无法${v ? '启用' : '关闭'}生物识别解锁', error: true);
              }
            },
          ),
        ),
      _Row(
        title: '自动锁定',
        subtitle: '无操作一段时间后锁定保险库并清空内存中的密钥。',
        trailing: DropdownButton<int>(
          value: s.autoLockMinutes,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 1, child: Text('1 分钟')),
            DropdownMenuItem(value: 5, child: Text('5 分钟')),
            DropdownMenuItem(value: 10, child: Text('10 分钟')),
            DropdownMenuItem(value: 30, child: Text('30 分钟')),
            DropdownMenuItem(value: 0, child: Text('从不')),
          ],
          onChanged: (v) => state.updateSettings(s.copyWith(autoLockMinutes: v)),
        ),
      ),
      _Row(
        title: '切到后台 / 最小化时锁定',
        trailing: Switch(value: s.lockOnMinimize, onChanged: (v) => state.updateSettings(s.copyWith(lockOnMinimize: v))),
      ),
      _Row(
        title: '剪贴板自动清除',
        subtitle: '复制密码后到期清空；桌面端写入时排除剪贴板历史与云同步。',
        trailing: DropdownButton<int>(
          value: s.clipboardSeconds,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: 15, child: Text('15 秒')),
            DropdownMenuItem(value: 30, child: Text('30 秒')),
            DropdownMenuItem(value: 60, child: Text('60 秒')),
            DropdownMenuItem(value: 90, child: Text('90 秒')),
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
  late final _url = TextEditingController(text: AppScope.read(context).settings.serverUrl);
  late final _device = TextEditingController(text: AppScope.read(context).defaultDeviceName);
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    _device.dispose();
    super.dispose();
  }

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
      return _Section(title: '云同步', children: [
        const _Row(
          title: '端到端加密同步（未开启）',
          subtitle: '开启后，条目在本机以 AES-256-GCM 加密后才上传；服务器只保存密文，无法读取任何内容。',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ZoTextField(controller: _url, label: '同步服务器', hint: AppConfig.defaultServerUrl, prefixIcon: Icons.dns_outlined),
            const SizedBox(height: 12),
            ZoTextField(controller: _device, label: '本设备名称', prefixIcon: Icons.devices_outlined),
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ZoButton(
                label: '开启同步',
                icon: Icons.cloud_upload_outlined,
                loading: _busy,
                onPressed: () => _run(() => state.enableSync(_url.text, _device.text), ok: '同步已开启'),
              ),
              ZoButton(
                label: '测试连接',
                variant: ZoButtonVariant.ghost,
                onPressed: _busy ? null : () => _run(() => VaultApi.pingServer(_url.text), ok: '服务器连接正常'),
              ),
            ]),
          ]),
        ),
      ]);
    }

    final (label, color) = switch (state.syncState) {
      SyncState.syncing => ('同步中…', context.zo.accent),
      SyncState.error => ('同步失败：${state.syncError ?? ''}', context.zo.danger),
      SyncState.needsReconnect => ('登录已过期，请重新验证', context.zo.warning),
      _ => ('已同步', context.zo.success),
    };
    return _Section(title: '云同步', children: [
      _Row(
        title: remote.serverUrl,
        subtitle: '本设备：${remote.deviceName} · 上次同步 ${_fmtTime(remote.lastSyncAt)} · 待上传 ${remote.pending}',
        trailing: ZoTag(label.length > 18 ? '${label.substring(0, 18)}…' : label, color: color),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (state.syncState == SyncState.needsReconnect)
            ZoButton(
              label: '重新验证',
              icon: Icons.login_rounded,
              onPressed: () async {
                final pw = await askMasterPassword(context, title: '重新连接同步服务');
                if (pw != null && pw.isNotEmpty) await _run(() => state.reconnect(pw), ok: '已重新连接');
              },
            )
          else
            ZoButton(
              label: '立即同步',
              icon: Icons.sync_rounded,
              loading: state.syncState == SyncState.syncing,
              onPressed: () => _run(() async {
                final r = await state.syncNow();
                if (r != null && r.merged > 0 && mounted) showZoMessage(this.context, '已合并 ${r.merged} 个在多台设备上同时修改的条目');
              }),
            ),
          ZoButton(
            label: '设备管理',
            icon: Icons.devices_other_outlined,
            variant: ZoButtonVariant.secondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicesPage())),
          ),
          ZoButton(
            label: '安全日志',
            icon: Icons.history_rounded,
            variant: ZoButtonVariant.secondary,
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuditLogPage())),
          ),
          ZoButton(
            label: '关闭同步',
            variant: ZoButtonVariant.ghost,
            onPressed: () async {
              final ok = await confirmDialog(context, title: '关闭云同步？', body: '本机数据保留；本设备将从同步服务登出。', confirm: '关闭同步');
              if (ok == true) await _run(state.disableSync, ok: '已关闭同步');
            },
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
      appBar: AppBar(title: const Text('设备管理'), backgroundColor: c.bg, surfaceTintColor: Colors.transparent),
      body: FutureBuilder<List<DeviceDto>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('${snap.error}', style: context.text.bodyMedium));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final devices = snap.data!;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('新设备登录需经邮件验证码或在此批准。撤销后该设备会话立即失效。', style: context.text.bodySmall),
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
                            if (d.current) ...[const SizedBox(width: 8), ZoTag('本机', color: c.accent)],
                            if (d.revoked) ...[const SizedBox(width: 8), ZoTag('已撤销', color: c.danger)],
                            if (!d.approved && !d.revoked) ...[const SizedBox(width: 8), ZoTag('待批准', color: c.warning)],
                          ]),
                          const SizedBox(height: 4),
                          Text('${d.platform} · 添加于 ${_fmtTime(d.createdAt.toInt())} · 最近活跃 ${_fmtTime(d.lastSeenAt?.toInt())}',
                              style: context.text.bodySmall),
                        ]),
                      ),
                      if (!d.approved && !d.revoked)
                        ZoButton(label: '批准', dense: true, onPressed: () => _act(() => VaultApi.approveDevice(d.id), '已批准')),
                      if (!d.current && !d.revoked) ...[
                        const SizedBox(width: 8),
                        ZoButton(
                          label: '撤销',
                          dense: true,
                          variant: ZoButtonVariant.danger,
                          onPressed: () async {
                            final ok = await confirmDialog(context,
                                title: '撤销设备「${d.name}」？', body: '该设备将被立即登出且无法再同步。', confirm: '撤销', danger: true);
                            if (ok == true) await _act(() => VaultApi.revokeDevice(d.id), '已撤销');
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

  static const _labels = {
    'register': '注册账户',
    'login_ok': '登录成功',
    'login_fail': '登录失败',
    'device_added': '新设备请求登录',
    'device_approved': '设备已批准',
    'device_revoked': '设备已撤销',
    'pwd_changed': '主密码已修改',
    'recovery_used': '使用 Recovery Kit 恢复',
    'recovery_fail': '恢复码验证失败',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Scaffold(
      appBar: AppBar(title: const Text('安全日志'), backgroundColor: c.bg, surfaceTintColor: Colors.transparent),
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
                title: Text(_labels[e.event] ?? e.event),
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
    return _Section(title: '外观', children: [
      _Row(
        title: '主题',
        trailing: SegmentedButton<ThemeModeSetting>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ThemeModeSetting.system, label: Text('跟随系统')),
            ButtonSegment(value: ThemeModeSetting.light, label: Text('浅色')),
            ButtonSegment(value: ThemeModeSetting.dark, label: Text('深色')),
          ],
          selected: {s.themeMode},
          onSelectionChanged: (v) => state.updateSettings(s.copyWith(themeMode: v.first)),
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

class _DataSection extends StatefulWidget {
  const _DataSection();

  @override
  State<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<_DataSection> {
  bool _busy = false;

  Future<void> _import() async {
    final state = AppScope.of(context);
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV / 1PIF', extensions: ['csv', '1pif', 'txt'], uniformTypeIdentifiers: ['public.comma-separated-values-text', 'public.plain-text', 'public.data']),
    ]);
    if (file == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final r = await state.importItems(await file.readAsString());
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Text(
            '来源：${_importSources[r.format] ?? r.format}\n'
            '新增 ${r.added} 条${r.duplicates > 0 ? '，${r.duplicates} 条与现有条目重复已跳过' : ''}'
            '${r.skipped > 0 ? '，${r.skipped} 条无法识别' : ''}。\n\n'
            '导出文件是明文，请立即从磁盘和回收站中彻底删除。',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
        ),
      );
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } on FormatException {
      if (mounted) showZoMessage(context, '文件不是 UTF-8 文本，请用原软件重新导出为 CSV', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Section(title: '数据', children: [
        _Row(
          title: '从其他密码管理器导入',
          subtitle: '支持 Chrome / Edge / Firefox / Bitwarden / LastPass / 1Password 导出的 CSV 与 1PIF。文件只在本机解析，随即加密入库；重复条目自动跳过。',
          trailing: ZoButton(label: _busy ? '导入中…' : '选择文件', dense: true, variant: ZoButtonVariant.secondary, onPressed: _busy ? null : _import),
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
    return _Section(title: '桌面', children: [
      _Row(
        title: '关闭窗口时保留在系统托盘',
        subtitle: '关闭后仍可通过托盘图标或快捷键唤起；从托盘菜单选择「退出」才会结束程序。',
        trailing: Switch(value: s.closeToTray, onChanged: (v) => state.updateSettings(s.copyWith(closeToTray: v))),
      ),
      _Row(
        title: '全局快捷键  ${DesktopShell.hotKeyLabel}',
        subtitle: '在任何程序中按下即可唤起 VaultOne 并聚焦搜索框。',
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
    return _Section(title: '浏览器扩展', children: [
      _Row(
        title: '允许浏览器扩展连接',
        subtitle: '扩展通过本机 Native Messaging 向 VaultOne 请求凭据，只会拿到与当前网站严格匹配的那一条；解密全部在本应用内完成。',
        trailing: Switch(value: s.browserIntegration, onChanged: (v) => state.updateSettings(s.copyWith(browserIntegration: v))),
      ),
      _Row(
        title: '安装扩展',
        subtitle: '支持 Chrome、Edge、Brave 等 Chromium 内核浏览器。安装后点击扩展图标完成配对。',
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
          if (list.isEmpty) return const _Row(title: '已配对的浏览器', subtitle: '暂无');
          return Column(children: [
            for (final c in list)
              _Row(
                title: c.name,
                subtitle: '配对于 ${_fmtTime(c.createdAt)} · 最近使用 ${_fmtTime(c.lastUsedAt)}',
                trailing: ZoButton(
                  label: '移除',
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
        title: '修复连接',
        subtitle: '扩展提示"未找到 VaultOne 桌面端"时，重新向浏览器登记连接器。',
        trailing: ZoButton(
          label: '重新登记',
          dense: true,
          variant: ZoButtonVariant.secondary,
          onPressed: () async {
            try {
              await VaultApi.registerNativeHost();
              if (context.mounted) showZoMessage(context, '已登记，请重启浏览器后重试');
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
    return _Section(title: '自动填充', children: [
      _Row(
        title: _enabled ? 'VaultOne 已是系统自动填充服务' : '将 VaultOne 设为自动填充服务',
        subtitle: '在应用和浏览器的登录框中选择「用 VaultOne 填充」。网页只推荐与当前域名严格匹配的条目；登录后可一键保存新密码。',
        trailing: _enabled
            ? const ZoTag('已启用')
            : ZoButton(label: '去设置', dense: true, variant: ZoButtonVariant.secondary, onPressed: () => _channel.invokeMethod('openAutofillSettings')),
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
    return _Section(title: '诊断', children: [
      _Row(
        title: '详细日志（诊断模式）',
        subtitle: '日志只含事件类型、错误码与耗时，绝不包含密码、条目内容或邮箱。重启应用后生效。',
        trailing: Switch(value: s.verboseLogs, onChanged: (v) => state.updateSettings(s.copyWith(verboseLogs: v))),
      ),
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
        _Row(
          title: '日志文件',
          subtitle: '反馈问题时可附上日志文件。',
          trailing: ZoButton(
            label: '打开目录',
            dense: true,
            variant: ZoButtonVariant.secondary,
            onPressed: () async {
              final dir = await getApplicationSupportDirectory();
              await launchUrl(Uri.file('${dir.path}${Platform.pathSeparator}logs'));
            },
          ),
        ),
    ]);
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
    return _Section(title: '关于', children: [
      FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) => _Row(
          title: 'VaultOne ${snap.data?.version ?? ''}',
          subtitle: '构建 ${snap.data?.buildNumber ?? '-'} · 加密内核开源（AGPL-3.0）',
        ),
      ),
      link('隐私政策', AppConfig.privacyPolicyUrl),
      link('用户协议', AppConfig.termsUrl),
      link('源代码与安全白皮书', AppConfig.sourceUrl),
      _Row(
        title: '开源许可',
        trailing: ZoIconButton(
          icon: Icons.chevron_right_rounded,
          tooltip: '查看第三方开源许可',
          onPressed: () => showLicensePage(context: context, applicationName: 'VaultOne'),
        ),
      ),
      _Row(
        title: '联系支持',
        subtitle: AppConfig.supportEmail,
        trailing: ZoIconButton(
          icon: Icons.mail_outline_rounded,
          tooltip: '发送邮件',
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
    return _Section(title: '危险操作', children: [
      _Row(
        title: '清除本机数据',
        subtitle: '删除本机保险库与钥匙串中的 Secret Key。已开启同步的数据仍保存在云端。',
        trailing: ZoButton(
          label: '清除',
          dense: true,
          variant: ZoButtonVariant.danger,
          onPressed: () async {
            final msg = state.remote == null ? '本机数据未开启同步，清除后将永久丢失且无法恢复！' : '可随时用主密码 + Secret Key 重新登录恢复。';
            final ok = await confirmDialog(context, title: '清除本机数据？', body: msg, confirm: '清除', danger: true);
            if (ok == true) await state.wipeThisDevice();
          },
        ),
      ),
      if (state.remote != null)
        _Row(
          title: '注销云端账户',
          subtitle: '永久删除云端的全部密文、设备与日志（个人信息保护法 / GDPR 删除权）。本机数据保留。',
          trailing: ZoButton(
            label: '注销',
            dense: true,
            variant: ZoButtonVariant.danger,
            onPressed: () async {
              final pw = await askMasterPassword(context, title: '注销云端账户', body: '此操作不可撤销。请输入主密码确认。', confirm: '永久注销');
              if (pw == null || pw.isEmpty || !context.mounted) return;
              try {
                await state.deleteCloudAccount(pw);
                if (context.mounted) showZoMessage(context, '云端账户已注销');
              } on CoreException catch (e) {
                if (context.mounted) showZoMessage(context, e.message, error: true);
              }
            },
          ),
        ),
    ]);
  }
}
