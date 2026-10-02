import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../l10n/strings.dart';
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
        Text(context.tr(AppStrings.onboardWelcomeTitle), style: context.text.displayMedium),
        const SizedBox(height: 12),
        Text(
          context.tr(AppStrings.onboardWelcomeBody),
          style: context.text.bodyLarge?.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: 40),
        ZoButton(label: context.tr(AppStrings.onboardRegister), icon: Icons.arrow_forward_rounded, expand: true, onPressed: onStart),
        const SizedBox(height: 10),
        ZoButton(label: context.tr(AppStrings.onboardHaveAccount), icon: Icons.login_rounded, variant: ZoButtonVariant.secondary, expand: true, onPressed: onSignIn),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: onRecover,
            style: TextButton.styleFrom(foregroundColor: c.textMuted),
            child: Text(context.tr(AppStrings.onboardAllDevicesLost)),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: c.textFaint),
            const SizedBox(width: 6),
            Expanded(
              child: Text(context.tr(AppStrings.onboardNetworkNote), style: context.text.bodySmall?.copyWith(color: c.textFaint)),
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
      _emailError = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email) ? null : context.tr(AppStrings.invalidEmail);
      _pwError = pw.characters.length < 10
          ? context.tr(AppStrings.masterPasswordTooShort)
          : (_strength.score < 3 ? context.tr(AppStrings.passwordTooWeak) : null);
      _pw2Error = _pw2.text != pw ? context.tr(AppStrings.passwordMismatch) : null;
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
          ZoButton(label: context.tr(AppStrings.back), icon: Icons.arrow_back_rounded, variant: ZoButtonVariant.ghost, dense: true, onPressed: _busy ? null : widget.onBack),
          const SizedBox(height: 24),
          AuthHeader(
            eyebrow: AppStrings.onboardStepOne,
            title: context.tr(AppStrings.onboardSetMasterPassword),
            subtitle: context.tr(AppStrings.onboardSetMasterPasswordBody),
          ),
          ZoTextField(
            controller: _email,
            label: context.tr(AppStrings.emailLabel),
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
            label: context.tr(AppStrings.masterPassword),
            hint: context.tr(AppStrings.masterPasswordHint),
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
            label: context.tr(AppStrings.confirmMasterPassword),
            obscure: true,
            prefixIcon: Icons.key_rounded,
            error: _pw2Error,
            onChanged: (_) => setState(() => _pw2Error = null),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 28),
          ZoButton(label: _busy ? context.tr(AppStrings.registering) : context.tr(AppStrings.registerAccount), loading: _busy, expand: true, onPressed: _submit),
          const SizedBox(height: 16),
          Text(
            context.tr(AppStrings.onboardKeyLocalNote),
            style: context.text.bodySmall?.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }
}

/// Recovery Kit 展示页：必须保存（或逐项复制）并勾选确认后才能进入保险库。
class RecoveryKitView extends StatefulWidget {
  const RecoveryKitView({super.key, required this.enrollment, required this.onDone, this.title});

  final Enrollment enrollment;
  final Future<void> Function() onDone;
  /// 为空时使用当前语言下的默认标题。
  final String? title;

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
          eyebrow: AppStrings.onboardStepTwo,
          title: widget.title ?? context.tr(AppStrings.saveRecoveryKitTitle),
          subtitle: context.tr(AppStrings.recoveryKitSubtitle),
        ),
        _KeyBlock(label: AppStrings.secretKeyLabel, value: e.secretKey),
        const SizedBox(height: 12),
        _KeyBlock(label: AppStrings.recoveryCodeLabel, value: e.recoveryCode),
        const SizedBox(height: 20),
        ZoButton(
          label: _savedPath == null ? context.tr(AppStrings.saveRecoveryKitPdf) : context.tr(AppStrings.saveRecoveryKitAgain),
          icon: _savedPath == null ? Icons.download_rounded : Icons.check_rounded,
          variant: ZoButtonVariant.secondary,
          expand: true,
          onPressed: _save,
        ),
        const SizedBox(height: 8),
        ZoButton(
          label: context.tr(AppStrings.exportBackupCard),
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
                  context.tr(AppStrings.savedRecoveryKitAck),
                  style: context.text.bodyMedium?.copyWith(color: _verified ? c.text : c.textFaint),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ZoButton(
          label: context.tr(AppStrings.enterVault),
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
              Text(context.tr(AppStrings.verifySecretKeyTitle), style: context.text.labelSmall?.copyWith(color: ok ? c.success : c.accent)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(AppStrings.verifySecretKeyBody),
            style: context.text.bodySmall?.copyWith(color: c.textFaint),
          ),
          const SizedBox(height: 12),
          ZoTextField(
            controller: controller,
            label: context.tr(AppStrings.reenterSecretKey),
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
                child: Text(context.tr(AppStrings.verifyOk), style: context.text.bodyMedium?.copyWith(color: c.success)),
              ),
            ])
          else
            ZoButton(
              label: context.tr(AppStrings.verifyAction),
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
                  showZoMessage(context, context.trf(AppStrings.kitCopyToast, {'label': label}));
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
        AuthHeader(eyebrow: AppStrings.privacyEyebrow, title: context.tr(AppStrings.privacyTitle), subtitle: context.tr(AppStrings.privacySubtitle)),
        point(Icons.lock_outline_rounded, context.tr(AppStrings.privacyLocalOnly), context.tr(AppStrings.privacyLocalOnlyBody)),
        point(Icons.alternate_email_rounded, context.tr(AppStrings.privacyMinimalData), context.tr(AppStrings.privacyMinimalDataBody)),
        point(Icons.block_rounded, context.tr(AppStrings.privacyNeverDo), context.tr(AppStrings.privacyNeverDoBody)),
        point(Icons.fingerprint_rounded, context.tr(AppStrings.privacyBiometrics), context.tr(AppStrings.privacyBiometricsBody)),
        const SizedBox(height: 6),
        Wrap(spacing: 4, children: [
          TextButton(onPressed: () => launchUrl(Uri.parse(AppConfig.privacyPolicyUrl)), child: Text(context.tr(AppStrings.privacyPolicy))),
          TextButton(onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl)), child: Text(context.tr(AppStrings.termsOfService))),
        ]),
        const SizedBox(height: 16),
        ZoButton(label: context.tr(AppStrings.agreeAndContinue), expand: true, onPressed: state.acceptPrivacy),
        const SizedBox(height: 8),
        ZoButton(label: context.tr(AppStrings.disagreeAndExit), variant: ZoButtonVariant.ghost, expand: true, onPressed: () => SystemNavigator.pop()),
      ],
    );
  }
}
