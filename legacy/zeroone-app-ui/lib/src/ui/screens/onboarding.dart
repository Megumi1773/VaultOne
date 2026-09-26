import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../state/clipboard.dart';
import '../../state/recovery_kit.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/auth_layout.dart';
import '../widgets/brand.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';

enum _Step { welcome, create, kit }

/// 首次使用：欢迎 → 创建保险库 → Recovery Kit。
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
    return AuthLayout(
      child: AnimatedSwitcher(
        duration: Zo.slow,
        switchInCurve: Zo.ease,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(a), child: child),
        ),
        child: switch (step) {
          _Step.welcome => _Welcome(key: const ValueKey('w'), onStart: () => setState(() => _step = _Step.create)),
          _Step.create => _CreateForm(key: const ValueKey('c'), onBack: () => setState(() => _step = _Step.welcome)),
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
  const _Welcome({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ZoMark(size: 56),
        const SizedBox(height: 36),
        Text('欢迎使用 ZeroOne', style: context.text.displayMedium),
        const SizedBox(height: 12),
        Text(
          '口令、账号、两步验证、密钥——\n全部在你的设备上加密，只为你一个人打开。',
          style: context.text.bodyLarge?.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: 40),
        ZoButton(label: '创建我的保险库', icon: Icons.arrow_forward_rounded, expand: true, onPressed: onStart),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: c.textFaint),
            const SizedBox(width: 6),
            Expanded(
              child: Text('离线可用。本版本数据仅保存在本机，云同步将在后续版本开启。', style: context.text.bodySmall?.copyWith(color: c.textFaint)),
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
            '点击创建后，我们会在本机生成 240-bit Secret Key 与 256-bit Vault Key，并用 Argon2id（64 MiB）派生主密钥，约需 1 秒。',
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
          label: _savedPath == null ? '下载 Recovery Kit' : '已保存 · 再次保存',
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
