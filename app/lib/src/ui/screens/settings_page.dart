import 'dart:async';
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
import '../../state/clipboard.dart';
import '../../state/desktop_shell.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
import 'backup_dialog.dart';
import 'conflicts_page.dart';
import 'feedback_page.dart';
import 'item_detail.dart' show confirmDialog, formatTime;
import 'import_dialog.dart';
import 'sidebar_layout.dart';
import 'taxonomy_dialog.dart';
import 'transfer_history_dialog.dart';

/// 设置页的分区。安全总览（§5.1）的宫格入口据此直接定位到对应分区，
/// 而不是把用户丢在设置页顶部自己找。
enum SettingsSection {
  account,
  keyBackup,
  security,
  sync,
  conflict,
  data,
  desktop,
  browser,
  appearance,
  sidebarLayout,
  diagnostics,
  about,
  danger,
}

/// 设置：账户、解锁与安全、云同步与设备、数据导入、桌面托盘与快捷键、浏览器扩展、外观、诊断、关于与法律、危险操作。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.initialSection});

  /// 打开时滚动到的分区；为空则停在顶部。
  final SettingsSection? initialSection;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Map<SettingsSection, GlobalKey> _anchors = {
    for (final s in SettingsSection.values) s: GlobalKey(debugLabel: s.name),
  };

  @override
  void initState() {
    super.initState();
    final target = widget.initialSection;
    if (target == null) return;
    // 分区是懒构建的，必须等首帧布局完再滚动，否则拿不到 RenderObject。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _anchors[target]?.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.05);
    });
  }

  /// 给分区挂锚点。锚点只是定位标记，不改变子树的布局与语义。
  Widget _anchor(SettingsSection section, Widget child) => KeyedSubtree(key: _anchors[section], child: child);

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 720;
    // 用 SingleChildScrollView 而不是 ListView：ListView 的懒布局会让视口外的分区没有
    // RenderObject，`initialSection` 定位到靠后的分区时会静默失效。设置页一共十几个分区，
    // 一次性布局的代价可以接受，换来的是深链始终有效。
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 40, narrow ? 16 : 36, narrow ? 16 : 40, 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Title(),
              _anchor(SettingsSection.account, const _AccountSection()),
              _anchor(SettingsSection.keyBackup, const _KeyBackupSection()),
              _anchor(SettingsSection.security, const _SecuritySection()),
              _anchor(SettingsSection.sync, const _SyncSection()),
              _anchor(SettingsSection.conflict, const _ConflictSection()),
              _anchor(SettingsSection.data, const _DataSection()),
              _anchor(SettingsSection.desktop, const _DesktopSection()),
              _anchor(SettingsSection.browser, const _BrowserSection()),
              _anchor(SettingsSection.appearance, const _AppearanceSection()),
              _anchor(SettingsSection.sidebarLayout, const _SidebarLayoutSection()),
              _anchor(SettingsSection.diagnostics, const _DiagnosticsSection()),
              _anchor(SettingsSection.about, const _AboutSection()),
              _anchor(SettingsSection.danger, const _DangerSection()),
            ],
          ),
        ),
      ),
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

/// 首页板块自定义（§3.6 / §3.11）：调整侧栏分区的顺序与显隐。
///
/// 布局存成 JSON 字符串放在本机设置里，不同步。顺序即侧栏自上而下的顺序；
/// 分组标题由布局里的 group 决定，因此拖动条目时标题会跟着走。
class _SidebarLayoutSection extends StatelessWidget {
  const _SidebarLayoutSection();

  Future<void> _save(AppState state, List<SidebarEntry> next) =>
      state.updateSettings(state.settings.copyWith(sidebarLayout: encodeSidebarLayout(next)));

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final entries = resolveSidebarLayout(state.settings.sidebarLayout);
    final c = context.zo;
    return _Section(
      title: context.tr(AppStrings.sidebarLayoutTitle),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(context.tr(AppStrings.sidebarLayoutSubtitle), style: context.text.bodySmall),
        ),
        for (final (i, entry) in entries.indexed)
          _Row(
            title: entry.section.title(context),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ZoIconButton(
                  icon: Icons.keyboard_arrow_up_rounded,
                  tooltip: context.tr(AppStrings.sidebarMoveUp),
                  size: 28,
                  onPressed: i == 0 ? null : () => _save(state, moveSidebarEntry(entries, i, -1)),
                ),
                ZoIconButton(
                  icon: Icons.keyboard_arrow_down_rounded,
                  tooltip: context.tr(AppStrings.sidebarMoveDown),
                  size: 28,
                  onPressed: i == entries.length - 1 ? null : () => _save(state, moveSidebarEntry(entries, i, 1)),
                ),
                const SizedBox(width: 6),
                Switch(
                  value: entry.visible,
                  // 不允许把最后一项可见也关掉：侧栏会变成一片空白，用户没有恢复入口。
                  onChanged: !canHide(entries, entry)
                      ? null
                      : (v) => _save(state, [
                            for (final e in entries)
                              e.section == entry.section ? e.copyWith(visible: v) : e,
                          ]),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Text(context.tr(AppStrings.sidebarShow), style: context.text.bodySmall?.copyWith(color: c.textFaint)),
              const Spacer(),
              TextButton(
                onPressed: () => _save(state, defaultSidebarLayout()),
                child: Text(context.tr(AppStrings.sidebarResetLayout)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {  const _Section({required this.title, required this.children});

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

/// 导入结果文案。`updated` / `duplicates` / `skipped` 为 0 时不显示对应片段。
String _importSummaryText(
  BuildContext context, {
  required String source,
  required int added,
  int updated = 0,
  required int duplicates,
  required int skipped,
}) {
  final suffix = '${updated > 0 ? context.trf(AppStrings.importUpdated, {'n': updated}) : ''}'
      '${duplicates > 0 ? context.trf(AppStrings.importDuplicates, {'n': duplicates}) : ''}'
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

class _AccountSection extends StatefulWidget {
  const _AccountSection();

  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  @override
  void initState() {
    super.initState();
    // 进账户页时拉一次资料。**离线不报错**：内核会回退到本机缓存并置 online=false。
    // 其他错误（未解锁、桥不可用）也在这里兜住——资料只是展示信息，拉不到不该让整个账户页渲染失败。
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadProfile()));
  }

  Future<void> _loadProfile() async {
    if (!mounted) return;
    try {
      await AppScope.of(context).refreshProfile();
    } catch (e) {
      VaultApi.log('profile refresh failed: ${e is CoreException ? e.code : e.runtimeType}', level: 'warn');
    }
  }

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
    final p = state.profile;
    return _Section(title: context.tr(AppStrings.sectionAccount), children: [
      // 资料行（§8.1）：昵称 + 头像地址。离线时展示本机缓存并明确标注。
      _Row(
        title: (p?.nickname.isNotEmpty ?? false) ? p!.nickname : context.tr(AppStrings.profileNoNickname),
        subtitle: p == null
            ? context.tr(AppStrings.profileNickname)
            : '${context.tr(AppStrings.profileNickname)}'
                '${p.online ? '' : ' · ${context.tr(AppStrings.profileOffline)}'}'
                '${p.createdAt > 0 ? ' · ${context.trf(AppStrings.profileCreatedAt, {'time': formatTime(p.createdAt)})}' : ''}',
        trailing: ZoButton(
          label: context.tr(AppStrings.profileEdit),
          dense: true,
          variant: ZoButtonVariant.secondary,
          onPressed: () => _editProfile(context),
        ),
      ),
      if (p != null && p.avatar.isNotEmpty)
        _Row(title: context.tr(AppStrings.profileAvatar), subtitle: p.avatar),
      // 我的邀请码（§8.1 / §9）：一人一码、可多人使用。与「填写邀请码」是两个方向，不混用。
      _Row(
        title: context.tr(AppStrings.inviteMine),
        subtitle: (p?.inviteCode.isNotEmpty ?? false) ? p!.inviteCode : context.tr(AppStrings.inviteNone),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZoIconButton(
              icon: Icons.copy_rounded,
              tooltip: context.tr(AppStrings.inviteCopy),
              onPressed: (p?.inviteCode.isNotEmpty ?? false) ? () => _copyInvite(context, p!.inviteCode) : null,
            ),
            ZoButton(
              label: context.tr(AppStrings.inviteBind),
              dense: true,
              variant: ZoButtonVariant.secondary,
              onPressed: () => _bindInvite(context),
            ),
          ],
        ),
      ),
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

  /// 编辑资料（§8.2）。昵称与头像地址都是**全量替换**，与线协议一致。
  Future<void> _editProfile(BuildContext context) async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProfileDialog(
        nickname: state.profile?.nickname ?? '',
        avatar: state.profile?.avatar ?? '',
        save: state.updateProfile,
      ),
    );
    if (saved == true && context.mounted && state.isCurrentSession(epoch)) {
      showZoMessage(context, context.tr(AppStrings.profileSaved));
    }
  }

  /// 复制邀请码。
  ///
  /// **不按敏感内容处理**：邀请码本来就是要发给别人的，用户复制后紧接着就要粘贴到聊天窗口；
  /// 按密码那套（排除剪贴板历史 + 到期清空）反而添乱。
  Future<void> _copyInvite(BuildContext context, String code) async {
    await ClipboardService.copy(code, label: context.tr(AppStrings.inviteMine), sensitive: false, clearAfterSeconds: 0);
    if (context.mounted) showZoMessage(context, context.tr(AppStrings.inviteCopied));
  }

  /// 填写邀请人的邀请码（§9）。一次性绑定，服务端绑定后不可更改。
  Future<void> _bindInvite(BuildContext context) async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _InviteBindDialog(bind: state.bindInvite),
    );
    if (done == true && context.mounted && state.isCurrentSession(epoch)) {
      showZoMessage(context, context.tr(AppStrings.inviteBindDone));
    }
  }
}

/// 填写邀请人邀请码。格式规范化与「是否有效」的判断都在服务端
/// （`InviteCodes.normalize`），这里只收集输入。
class _InviteBindDialog extends StatefulWidget {
  const _InviteBindDialog({required this.bind});

  final Future<AccountProfile> Function(String code) bind;

  @override
  State<_InviteBindDialog> createState() => _InviteBindDialogState();
}

class _InviteBindDialogState extends State<_InviteBindDialog> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.bind(_code.text);
      if (mounted) Navigator.pop(context, true);
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(context.tr(AppStrings.inviteBindTitle)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ZoTextField(controller: _code, hint: context.tr(AppStrings.inviteBindHint)),
              const SizedBox(height: 6),
              Text(context.tr(AppStrings.inviteBindHint), style: context.text.labelSmall),
              const SizedBox(height: 10),
              Text(context.tr(AppStrings.inviteBindNote), style: context.text.bodySmall),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(context.tr(AppStrings.cancel))),
          FilledButton(onPressed: _busy ? null : _submit, child: Text(context.tr(AppStrings.save))),
        ],
      );
}

/// 资料编辑对话框。校验规则**只在服务端**（`WireValidation.profile`）：这里只做长度提示，
/// 不另写一份「昵称合法性」，否则两份规则迟早对不上。
class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.nickname, required this.avatar, required this.save});

  final String nickname;
  final String avatar;
  final Future<AccountProfile> Function({required String nickname, required String avatar}) save;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final TextEditingController _nickname = TextEditingController(text: widget.nickname);
  late final TextEditingController _avatar = TextEditingController(text: widget.avatar);
  bool _busy = false;

  @override
  void dispose() {
    _nickname.dispose();
    _avatar.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      await widget.save(nickname: _nickname.text.trim(), avatar: _avatar.text.trim());
      if (mounted) Navigator.pop(context, true);
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(context.tr(AppStrings.profileEdit)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ZoTextField(controller: _nickname, hint: context.tr(AppStrings.profileNickname)),
              const SizedBox(height: 6),
              Text(context.tr(AppStrings.profileNicknameHint), style: context.text.labelSmall),
              const SizedBox(height: 14),
              ZoTextField(controller: _avatar, hint: context.tr(AppStrings.profileAvatar)),
              const SizedBox(height: 6),
              Text(context.tr(AppStrings.profileAvatarHint), style: context.text.labelSmall),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(context.tr(AppStrings.cancel))),
          FilledButton(onPressed: _busy ? null : _submit, child: Text(context.tr(AppStrings.save))),
        ],
      );
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
      setState(() => _error = context.tr(e.message));
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
            for (final m in const [1, 3, 5, 10, 15, 30, 60])
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
        title: context.tr(AppStrings.lockOnExit),
        subtitle: context.tr(AppStrings.lockOnExitSubtitle),
        trailing: Switch(value: s.lockOnExit, onChanged: (v) => state.updateSettings(s.copyWith(lockOnExit: v))),
      ),
      _Row(
        title: context.tr(AppStrings.maskPasswords),
        subtitle: context.tr(AppStrings.maskPasswordsSubtitle),
        trailing: Switch(value: s.maskPasswords, onChanged: (v) => state.updateSettings(s.copyWith(maskPasswords: v))),
      ),
      _Row(
        title: context.tr(AppStrings.clipboardAutoClear),
        // 关掉时显示状态说明而不是「到期清空」，否则文案与开关状态自相矛盾。
        subtitle: context.tr(s.clipboardSeconds > 0 ? AppStrings.clipboardAutoClearSubtitle : AppStrings.clipboardDisabled),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 开关与延时分两个控件：关掉时延时无意义，直接禁用而不是把 0 混进选项里。
            Switch(
              value: s.clipboardSeconds > 0,
              onChanged: (on) => state.updateSettings(s.copyWith(clipboardSeconds: on ? 30 : 0)),
            ),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: s.clipboardSeconds > 0 ? s.clipboardSeconds : 30,
              underline: const SizedBox.shrink(),
              items: [
                for (final n in const [30, 60, 300])
                  DropdownMenuItem(value: n, child: Text(context.trf(AppStrings.seconds, {'n': n}))),
              ],
              onChanged: s.clipboardSeconds > 0
                  ? (v) => state.updateSettings(s.copyWith(clipboardSeconds: v))
                  : null,
            ),
          ],
        ),
      ),
      _Row(
        title: context.tr(AppStrings.screenshotProtection),
        subtitle: context.tr(
          state.screenshotProtectionSupported ? AppStrings.screenshotProtectionSubtitle : AppStrings.screenshotUnsupported,
        ),
        trailing: Switch(
          value: s.screenshotProtection,
          // 平台不支持时禁用开关，而不是让用户打开一个没有作用的选项。
          onChanged: !state.screenshotProtectionSupported
              ? null
              : (v) => state.updateSettings(s.copyWith(screenshotProtection: v)),
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
      // 先预览：让用户核对来源、警告与字段映射，再决定同名条目怎么处理。
      final decision = await showImportPreview(
        context,
        content: content,
        sourceName: file.name,
        parse: (c, {mapping}) => VaultApi.importPreview(c, mapping: mapping),
      );
      if (decision == null || !mounted || !state.isCurrentSession(epoch)) return;
      final r = await state.importItemsWith(
        content,
        mapping: decision.mapping,
        strategy: decision.strategy,
        source: file.name,
      );
      if (!mounted || !state.isCurrentSession(epoch)) return;
      final title = context.tr(AppStrings.importDone);
      final summary = _importSummaryText(
        context,
        source: _importSources[r.format] ?? r.format,
        added: r.added,
        updated: r.updated,
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
      final r = await state.importBackup(content, source: file.name);
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

  /// 标签与分类管理（§3.6）。改写规则在内核，这里只把入口与依赖接起来。
  Future<void> _manageTaxonomy() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    if (!state.isCurrentSession(epoch)) return;
    await showDialog<void>(
      context: context,
      builder: (_) => TaxonomyDialog(
        items: state.items,
        categoryTree: state.categoryTree,
        renameTag: state.renameTag,
        deleteTag: state.deleteTag,
        renameCategory: state.renameCategory,
        clearCategory: state.clearCategory,
      ),
    );
  }

  /// 导入导出历史（§3.7）。记录由内核在每次传输完成时写入，这里只读与清空。
  Future<void> _showHistory() async {
    final state = AppScope.of(context);
    if (!state.isCurrentSession(state.sessionEpoch)) return;
    await showTransferHistory(
      context,
      load: state.transferHistory,
      clear: state.clearTransferHistory,
    );
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
        _Row(
          title: context.tr(AppStrings.taxonomyManage),
          subtitle: context.tr(AppStrings.taxonomyManageSubtitle),
          trailing: ZoButton(label: context.tr(AppStrings.taxonomyManage), dense: true, variant: ZoButtonVariant.secondary, onPressed: _busy ? null : _manageTaxonomy),
        ),
        _Row(
          title: context.tr(AppStrings.transferHistory),
          subtitle: context.tr(AppStrings.transferHistorySubtitle),
          trailing: ZoButton(
            label: context.tr(AppStrings.transferHistory),
            dense: true,
            variant: ZoButtonVariant.secondary,
            onPressed: _busy ? null : _showHistory,
          ),
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
