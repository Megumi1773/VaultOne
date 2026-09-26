import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
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
    if (state.awaitingDeviceApproval) {
      return const AuthLayout(child: DeviceApprovalView());
    }
    if (!state.privacyAccepted) {
      return const AuthLayout(child: _PrivacyConsent());
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
        ZoButton(label: '创建我的保险库', icon: Icons.arrow_forward_rounded, expand: true, onPressed: onStart),
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
              child: Text('离线可用：数据默认只保存在本机，可随时开启端到端加密同步。', style: context.text.bodySmall?.copyWith(color: c.textFaint)),
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
          ZoButton(label: _busy ? '正在生成密钥…' : '创建保险库', loading: _busy, expand: true, onPressed: _submit),
          const SizedBox(height: 16),
          Text(
            '点击创建后，我们会在本机生成 240-bit Secret Key 与 256-bit Vault Key，并用 Argon2id（64 MiB，32 字节随机盐）派生主密钥，约需 1 秒。',
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
  bool _saved = false;
  bool _confirmed = false;
  bool _busy = false;
  String? _savedPath;

  Future<void> _save() async {
    try {
      final path = await RecoveryKit.save(widget.enrollment);
      if (path != null) {
        setState(() {
          _saved = true;
          _savedPath = path;
        });
      }
    } catch (e) {
      if (mounted) showZoMessage(context, '保存失败：$e', error: true);
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
        _KeyBlock(label: 'Secret Key', value: e.secretKey, onCopied: () => setState(() => _saved = true)),
        const SizedBox(height: 12),
        _KeyBlock(label: 'Recovery Code', value: e.recoveryCode, onCopied: () => setState(() => _saved = true)),
        const SizedBox(height: 20),
        ZoButton(
          label: _savedPath == null ? '保存 Recovery Kit（PDF）' : '已保存 · 再次保存',
          icon: _savedPath == null ? Icons.download_rounded : Icons.check_rounded,
          variant: ZoButtonVariant.secondary,
          expand: true,
          onPressed: _save,
        ),
        if (_savedPath != null) ...[
          const SizedBox(height: 8),
          Text(_savedPath!, style: context.text.bodySmall?.copyWith(color: c.textFaint), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 20),
        Hover(
          onTap: _saved ? () => setState(() => _confirmed = !_confirmed) : null,
          builder: (context, _) => Row(
            children: [
              Checkbox(value: _confirmed, onChanged: _saved ? (v) => setState(() => _confirmed = v ?? false) : null),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '我已妥善保存 Recovery Kit，并理解丢失后无人能帮我恢复数据。',
                  style: context.text.bodyMedium?.copyWith(color: _saved ? c.text : c.textFaint),
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

class _KeyBlock extends StatelessWidget {
  const _KeyBlock({required this.label, required this.value, required this.onCopied});

  final String label;
  final String value;
  final VoidCallback onCopied;

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
                  onCopied();
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
        point(Icons.lock_outline_rounded, '数据只在本机加密', '保险库内容以 AES-256-GCM 加密存储在本机；开启同步后服务器也只收到密文。'),
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
