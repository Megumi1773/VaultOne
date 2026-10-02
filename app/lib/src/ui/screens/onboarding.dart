import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../state/backup_card.dart';
import '../../state/clipboard.dart';
import '../../state/recovery_kit.dart';
import '../../state/scope.dart';
import 'sign_in.dart';
import '../theme.dart';
import '../widgets/auth_layout.dart';
import '../widgets/brand.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';

enum _Step { welcome, create, signIn, cloudRecover, kit }

/// 首次使用：欢迎 →（创建保险库 | 登录已有账户 | 用 Recovery Kit 从云端恢复）→ Recovery Kit。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step _step = _Step.welcome;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final step = state.pendingEnrollment != null ? _Step.kit : _step;
    if (!state.privacyAccepted) {
      return const AuthLayout(child: _PrivacyConsent());
    }
    if (state.awaitingDeviceApproval) {
      return const AuthLayout(child: DeviceApprovalView());
    }
    return AuthLayout(
      child: AnimatedSwitcher(
        duration: Zo.slow,
        switchInCurve: Zo.ease,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a), child: child),
        ),
        child: switch (step) {
          _Step.welcome => _Welcome(
              key: const ValueKey('w'),
              onStart: () => setState(() => _step = _Step.create),
              onSignIn: () => setState(() => _step = _Step.signIn),
              onRecover: () => setState(() => _step = _Step.cloudRecover),
            ),
          _Step.create => _CreateForm(key: const ValueKey('c'), onBack: () => setState(() => _step = _Step.welcome)),
          _Step.signIn => SignInForm(key: const ValueKey('s'), onBack: () => setState(() => _step = _Step.welcome)),
          _Step.cloudRecover => CloudRecoverForm(key: const ValueKey('r'), onBack: () => setState(() => _step = _Step.welcome)),
          _Step.kit => RecoveryKitView(
              key: const ValueKey('k'),
              enrollment: state.pendingEnrollment!,
              onDone: state.finishOnboarding,
            ),
        },
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({super.key, required this.onStart, required this.onSignIn, required this.onRecover});

  final VoidCallback onStart;
  final VoidCallback onSignIn;
  final VoidCallback onRecover;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ZoMark(size: 56),
        const SizedBox(height: 36),
        Text('欢迎使用 VaultOne', style: context.text.displayMedium),
        const SizedBox(height: 12),
        Text(
          '口令、账号、两步验证、密钥——\n全部在你的设备上加密，只为你一个人打开。',
          style: context.text.bodyLarge?.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: 40),
        ZoButton(label: '注册云账户', icon: Icons.arrow_forward_rounded, expand: true, onPressed: onStart),
        const SizedBox(height: 10),
        ZoButton(label: '我已有账户，登录', icon: Icons.login_rounded, variant: ZoButtonVariant.secondary, expand: true, onPressed: onSignIn),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: onRecover,
            style: TextButton.styleFrom(foregroundColor: c.textMuted),
            child: const Text('所有设备都丢失了？用 Recovery Kit 恢复'),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: c.textFaint),
            const SizedBox(width: 6),
            Expanded(
              child: Text('账户注册与登录需要联网；密码条目在本机加密，可离线使用并自动同步。', style: context.text.bodySmall?.copyWith(color: c.textFaint)),
            ),
          ],
        ),
      ],
    );
  }
}

class _CreateForm extends StatefulWidget {
  const _CreateForm({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<_CreateForm> createState() => _CreateFormState();
}

class _CreateFormState extends State<_CreateForm> {
  final _email = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  Strength _strength = Strength.empty;
  String? _emailError;
  String? _pwError;
  String? _pw2Error;
  bool _busy = false;
  int _shake = 0;

  @override
  void dispose() {
    _email.dispose();
    _pw.dispose();
    _pw2.dispose();
    super.dispose();
  }

  void _onPasswordChanged(String v) {
    setState(() {
      _strength = VaultApi.strength(v, inputs: [_email.text]);
      _pwError = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final pw = _pw.text;
    setState(() {
      _emailError = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email) ? null : '请输入有效的邮箱地址';
      _pwError = pw.characters.length < 10
          ? '主密码至少 10 个字符'
          : (_strength.score < 3 ? '强度不足：试试 4 个以上随机单词组成的短语' : null);
      _pw2Error = _pw2.text != pw ? '两次输入不一致' : null;
    });
    if (_emailError != null || _pwError != null || _pw2Error != null) {
      setState(() => _shake++);
      return;
    }
    setState(() => _busy = true);
    try {
      await AppScope.read(context).createAccount(email, pw);
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Shake(
      trigger: _shake,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZoButton(label: '返回', icon: Icons.arrow_back_rounded, variant: ZoButtonVariant.ghost, dense: true, onPressed: _busy ? null : widget.onBack),
          const SizedBox(height: 24),
          const AuthHeader(
            eyebrow: 'Step 01 / 02',
            title: '设置主密码',
            subtitle: '主密码是你唯一需要记住的密码。它从不离开这台设备，我们也无法帮你找回。',
          ),
          ZoTextField(
            controller: _email,
            label: '邮箱',
            hint: 'you@example.com',
            prefixIcon: Icons.alternate_email_rounded,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofocus: true,
            error: _emailError,
            onChanged: (_) => setState(() => _emailError = null),
          ),
          const SizedBox(height: 18),
          ZoTextField(
            controller: _pw,
            label: '主密码',
            hint: '至少 10 个字符，推荐使用口令短语',
            obscure: true,
            prefixIcon: Icons.key_rounded,
            textInputAction: TextInputAction.next,
            error: _pwError,
            onChanged: _onPasswordChanged,
          ),
          const SizedBox(height: 10),
          StrengthMeter(strength: _strength),
          if (_strength.warning != null) ...[
            const SizedBox(height: 6),
            Text(_strength.warning!, style: context.text.bodySmall?.copyWith(color: c.warning)),
          ],
          const SizedBox(height: 18),
          ZoTextField(
            controller: _pw2,
            label: '确认主密码',
            obscure: true,
            prefixIcon: Icons.key_rounded,
            error: _pw2Error,
            onChanged: (_) => setState(() => _pw2Error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 28),
          ZoButton(label: _busy ? '正在注册云账户…' : '注册账户', loading: _busy, expand: true, onPressed: _submit),
          const SizedBox(height: 16),
          Text(
            '密钥在本机生成，主密码和 Secret Key 不会发送给服务端。只有 Java 服务确认注册后才完成建号；网络失败会保留加密注册草稿供重试。',
            style: context.text.bodySmall?.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }
}

/// Recovery Kit 展示页：必须保存（或逐项复制）并勾选确认后才能进入保险库。
class RecoveryKitView extends StatefulWidget {
  const RecoveryKitView({super.key, required this.enrollment, required this.onDone, this.title = '保存你的 Recovery Kit'});

  final Enrollment enrollment;
  final Future<void> Function() onDone;
  final String title;

  @override
  State<RecoveryKitView> createState() => _RecoveryKitViewState();
}

class _RecoveryKitViewState extends State<RecoveryKitView> {
  final _confirm = TextEditingController();

  bool _confirmed = false;
  bool _verified = false;
  bool _checking = false;
  bool _busy = false;
  String? _checkError;
  String? _savedPath;
  String? _verifiedKey;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    bool canContinue() => mounted && epoch == state.sessionEpoch;
    try {
      final path = await RecoveryKit.save(widget.enrollment, canContinue: canContinue);
      if (path != null && canContinue()) {
        await state.recordBackup('recovery_kit');
        if (!canContinue()) return;
        setState(() {
          _savedPath = path;
        });
      }
    } catch (_) {
      if (mounted && canContinue()) showZoMessage(context, '保存失败，请检查目录权限与可用空间。', error: true);
    }
  }

  /// 导出 700×900 / 2x 的备份卡图（PNG）。与 PDF 互补：卡图适合存相册或打印成实体卡。
  Future<void> _saveCard() async {
    final state = AppScope.of(context);
    final epoch = state.sessionEpoch;
    bool canContinue() => mounted && epoch == state.sessionEpoch;
    setState(() => _busy = true);
    try {
      final path = await BackupCard.save(
        BackupCardData(
          email: widget.enrollment.email,
          secretKey: _verifiedKey ?? widget.enrollment.secretKey,
          recoveryCode: widget.enrollment.recoveryCode,
          generatedAt: DateTime.now(),
        ),
        canContinue: canContinue,
      );
      if (path != null && canContinue()) {
        await state.recordBackup('backup_card');
        if (!mounted || epoch != state.sessionEpoch) return;
        showZoMessage(context, '备份卡已保存到 $path');
      }
    } catch (_) {
      if (mounted && canContinue()) showZoMessage(context, '备份卡导出失败，请检查目录权限与可用空间。', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 字节级二次确认：重输的 Secret Key 必须与本机保存的解析后 30 字节完全一致。
  Future<void> _verify() async {
    final state = AppScope.read(context);
    final epoch = state.sessionEpoch;
    setState(() {
      _checking = true;
      _checkError = null;
    });
    try {
      final canonical = await state.confirmSecretKey(_confirm.text);
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() {
        _verified = true;
        _verifiedKey = canonical;
      });
    } on CoreException catch (e) {
      if (!mounted || epoch != state.sessionEpoch) return;
      setState(() {
        _verified = false;
        _verifiedKey = null;
        _checkError = switch (e.code) {
          'secret_key_mismatch' => '与本机保存的 Secret Key 不一致。请对照恢复套件逐组核对，注意易混字符 I/L/O 与数字 1/0。',
          'locked' || 'session_expired' => '保险库已锁定，请解锁后重试。',
          _ => '核对未完成，请稍后重试。',
        };
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _done() async {
    setState(() => _busy = true);
    try {
      await widget.onDone();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final e = widget.enrollment;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AuthHeader(
          eyebrow: 'Step 02 / 02',
          title: widget.title,
          subtitle: '换新设备或忘记主密码时，这是找回保险库的唯一方式。请打印或离线保存，不要存放在网盘或聊天记录里。',
        ),
        _KeyBlock(label: 'Secret Key', value: e.secretKey),
        const SizedBox(height: 12),
        _KeyBlock(label: 'Recovery Code', value: e.recoveryCode),
        const SizedBox(height: 20),
        ZoButton(
          label: _savedPath == null ? '保存 Recovery Kit（PDF）' : '已保存 · 再次保存',
          icon: _savedPath == null ? Icons.download_rounded : Icons.check_rounded,
          variant: ZoButtonVariant.secondary,
          expand: true,
          onPressed: _save,
        ),
        const SizedBox(height: 8),
        ZoButton(
          label: '导出备份卡（PNG · 700×900）',
          icon: Icons.image_outlined,
          variant: ZoButtonVariant.ghost,
          expand: true,
          onPressed: _busy ? null : _saveCard,
        ),
        if (_savedPath != null) ...[
          const SizedBox(height: 8),
          Text(_savedPath!, style: context.text.bodySmall?.copyWith(color: c.textFaint), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 20),
        _VerifyBlock(
          controller: _confirm,
          verified: _verified,
          checking: _checking,
          error: _checkError,
          onVerify: _verify,
          onChanged: () {
            if (_verified || _checkError != null) {
              setState(() {
                _verified = false;
                _verifiedKey = null;
                _checkError = null;
              });
            }
          },
        ),
        const SizedBox(height: 14),
        Hover(
          onTap: _verified ? () => setState(() => _confirmed = !_confirmed) : null,
          builder: (context, _) => Row(
            children: [
              Checkbox(value: _confirmed, onChanged: _verified ? (v) => setState(() => _confirmed = v ?? false) : null),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '我已妥善保存 Recovery Kit 与备份卡，并理解丢失后无人能帮我恢复数据。',
                  style: context.text.bodyMedium?.copyWith(color: _verified ? c.text : c.textFaint),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ZoButton(
          label: '进入保险库',
          icon: Icons.arrow_forward_rounded,
          expand: true,
          loading: _busy,
          onPressed: _confirmed ? _done : null,
        ),
      ],
    );
  }
}

/// 逐字节二次确认区块：重输 Secret Key 与本机保存的比对，通过后才允许勾选确认。
class _VerifyBlock extends StatelessWidget {
  const _VerifyBlock({
    required this.controller,
    required this.verified,
    required this.checking,
    required this.error,
    required this.onVerify,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool verified;
  final bool checking;
  final String? error;
  final Future<void> Function() onVerify;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final ok = verified;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: ShapeDecoration(
        color: c.surfaceRaised,
        shape: BeveledRectangleBorder(
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), bottomRight: Radius.circular(10)),
          side: BorderSide(color: ok ? c.success : c.borderStrong),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ok ? Icons.verified_rounded : Icons.spellcheck_rounded, size: 16, color: ok ? c.success : c.accent),
              const SizedBox(width: 8),
              Text('逐字节核对 Secret Key', style: context.text.labelSmall?.copyWith(color: ok ? c.success : c.accent)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '请把刚保存的 Secret Key 重新输入或粘贴一次。系统会逐字节比对（大小写、连字符与 I/L/O 的写法差异不影响结果），确认你手上的副本与本机一致。',
            style: context.text.bodySmall?.copyWith(color: c.textFaint),
          ),
          const SizedBox(height: 12),
          ZoTextField(
            controller: controller,
            label: '重新输入 Secret Key',
            hint: 'V1-XXXXXX-XXXXXX-…',
            mono: true,
            enabled: !ok,
            error: error,
            onChanged: (_) => onChanged(),
            onSubmitted: (_) => onVerify(),
          ),
          const SizedBox(height: 10),
          if (ok)
            Row(children: [
              Icon(Icons.check_circle_rounded, size: 16, color: c.success),
              const SizedBox(width: 6),
              Expanded(
                child: Text('与本机保存的 Secret Key 逐字节一致。', style: context.text.bodyMedium?.copyWith(color: c.success)),
              ),
            ])
          else
            ZoButton(
              label: '核对',
              icon: Icons.check_rounded,
              dense: true,
              loading: checking,
              onPressed: checking ? null : onVerify,
            ),
        ],
      ),
    );
  }
}

class _KeyBlock extends StatelessWidget {
  const _KeyBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      decoration: ShapeDecoration(
        color: c.surfaceRaised,
        shape: BeveledRectangleBorder(
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(10), bottomRight: Radius.circular(10)),
          side: BorderSide(color: c.borderStrong),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label.toUpperCase(), style: context.text.labelSmall?.copyWith(color: c.accent)),
              const Spacer(),
              ZoIconButton(
                icon: Icons.copy_rounded,
                tooltip: '复制',
                size: 28,
                onPressed: () {
                  ClipboardService.copy(value, label: label, clearAfterSeconds: 60);
                  showZoMessage(context, '$label 已复制，60 秒后自动清空剪贴板');
                },
              ),
            ],
          ),
          SelectableText(value, style: monoStyle(context, size: 15, weight: FontWeight.w600, spacing: 0.8)),
        ],
      ),
    );
  }
}


/// 首次启动隐私同意（个人信息保护法第 13/14 条；国内应用商店上架要求）。
class _PrivacyConsent extends StatelessWidget {
  const _PrivacyConsent();

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final state = AppScope.read(context);
    Widget point(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: c.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: context.text.titleMedium),
                const SizedBox(height: 2),
                Text(body, style: context.text.bodySmall),
              ]),
            ),
          ]),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AuthHeader(eyebrow: 'Privacy', title: '隐私保护说明', subtitle: '在开始使用前，请阅读并同意《隐私政策》与《用户协议》。'),
        point(Icons.lock_outline_rounded, '数据只在本机加密', '保险库内容在本机加密存储，云同步也只发送密文；账户和在线业务由 Java 服务处理。'),
        point(Icons.alternate_email_rounded, '我们收集的最少信息', '仅在你开启云同步时收集邮箱（用于登录与安全通知）与设备名称。'),
        point(Icons.block_rounded, '不做的事', '不接入任何第三方统计、广告或推送 SDK；不读取通讯录、位置等无关权限。'),
        point(Icons.fingerprint_rounded, '生物识别', '指纹/面容仅由系统验证，VaultOne 无法获取任何生物特征数据；需你单独开启。'),
        const SizedBox(height: 6),
        Wrap(spacing: 4, children: [
          TextButton(onPressed: () => launchUrl(Uri.parse(AppConfig.privacyPolicyUrl)), child: const Text('《隐私政策》')),
          TextButton(onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl)), child: const Text('《用户协议》')),
        ]),
        const SizedBox(height: 16),
        ZoButton(label: '同意并继续', expand: true, onPressed: state.acceptPrivacy),
        const SizedBox(height: 8),
        ZoButton(label: '不同意并退出', variant: ZoButtonVariant.ghost, expand: true, onPressed: () => SystemNavigator.pop()),
      ],
    );
  }
}
