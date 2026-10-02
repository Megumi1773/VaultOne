import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/ffi.dart';
import '../../l10n/strings.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/auth_layout.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';

/// 新设备登录已有账户（F-01）：邮箱 + 主密码 + Secret Key，主密码经 SRP-6a 验证、从不上传。
class SignInForm extends StatefulWidget {
  const SignInForm({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<SignInForm> {
  late final _server = TextEditingController(text: AppConfig.defaultServerUrl);
  late final _device = TextEditingController(text: AppScope.read(context).defaultDeviceName);
  final _email = TextEditingController();
  final _sk = TextEditingController();
  final _pw = TextEditingController();
  bool _busy = false;
  bool _advanced = false;
  String? _error;
  int _shake = 0;

  @override
  void dispose() {
    for (final c in [_server, _device, _email, _sk, _pw]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_email.text.trim().isEmpty || _sk.text.trim().isEmpty || _pw.text.isEmpty) {
      setState(() {
        _error = context.tr(AppStrings.fillAllFields);
        _shake++;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = AppConfig.allowCustomServer ? _server.text : AppConfig.defaultServerUrl;
      await AppScope.read(context).signIn(server, _email.text, _pw.text, _sk.text, _device.text);
    } on CoreException catch (e) {
      _pw.clear();
      // 只记录稳定错误码，不记录可能含用户数据的消息体或凭据。
      VaultApi.log('signIn failed: ${e.code}', level: 'error');
      if (mounted) {
        setState(() {
          _error = context.tr(e.message);
          _shake++;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shake(
      trigger: _shake,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZoButton(
            label: context.tr(AppStrings.back),
            icon: Icons.arrow_back_rounded,
            variant: ZoButtonVariant.ghost,
            dense: true,
            onPressed: _busy ? null : widget.onBack,
          ),
          const SizedBox(height: 24),
          AuthHeader(
            eyebrow: AppStrings.signInEyebrow,
            title: context.tr(AppStrings.signInTitle),
            subtitle: context.tr(AppStrings.signInSubtitle),
          ),
          ZoTextField(controller: _email, label: context.tr(AppStrings.fieldEmail), prefixIcon: Icons.alternate_email_rounded, keyboardType: TextInputType.emailAddress, autofocus: true),
          const SizedBox(height: 16),
          ZoTextField(controller: _sk, label: AppStrings.secretKeyLabel, hint: 'V1-XXXXXX-XXXXXX-…', mono: true, prefixIcon: Icons.vpn_key_outlined),
          const SizedBox(height: 16),
          ZoTextField(controller: _pw, label: context.tr(AppStrings.masterPassword), obscure: true, prefixIcon: Icons.key_rounded, onSubmitted: (_) => _submit()),
          // 错误是表单级的（可能是服务器地址、网络或凭据问题），不能挂在密码字段下，
          // 否则任何失败都像「主密码错」。
          if (_error case final message?) ...[
            const SizedBox(height: 12),
            Text(message, style: context.text.bodySmall?.copyWith(color: context.zo.danger)),
          ],
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: () => setState(() => _advanced = !_advanced),
            icon: Icon(_advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
            label: Text(context.tr(AppStrings.deviceNameLabel)),
          ),
          if (_advanced) ...[
            if (AppConfig.allowCustomServer) ...[
              ZoTextField(controller: _server, label: context.tr(AppStrings.syncServerLabel), hint: AppConfig.defaultServerUrl, prefixIcon: Icons.dns_outlined),
              const SizedBox(height: 12),
            ],
            ZoTextField(controller: _device, label: context.tr(AppStrings.thisDeviceName), prefixIcon: Icons.devices_outlined),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 16),
          ZoButton(label: _busy ? context.tr(AppStrings.verifying) : context.tr(AppStrings.sectionLogin), icon: Icons.login_rounded, expand: true, loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}

/// 新设备等待批准：输入邮件验证码，或在已登录设备上批准（自动轮询）。
class DeviceApprovalView extends StatefulWidget {
  const DeviceApprovalView({super.key});

  @override
  State<DeviceApprovalView> createState() => _DeviceApprovalViewState();
}

class _DeviceApprovalViewState extends State<DeviceApprovalView> {
  final _code = TextEditingController();
  Timer? _poll;
  bool _polling = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_busy || _polling || !mounted) return;
      _polling = true;
      try {
        await AppScope.read(context).pollDeviceApproved();
      } on CoreException catch (e) {
        if (mounted) setState(() => _error = context.tr(e.message));
      } finally {
        _polling = false;
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy || _polling) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).verifyDevice(_code.text.trim());
    } on CoreException catch (e) {
      if (mounted) setState(() => _error = context.tr(e.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AuthHeader(
          eyebrow: AppStrings.newDeviceEyebrow,
          title: context.tr(AppStrings.verifyDeviceTitle),
          subtitle: context.tr(AppStrings.verifyDeviceSubtitle),
        ),
        ZoTextField(
          controller: _code,
          label: context.tr(AppStrings.emailCodeLabel),
          hint: context.tr(AppStrings.emailCodeHint),
          mono: true,
          autofocus: true,
          keyboardType: TextInputType.number,
          prefixIcon: Icons.mark_email_read_outlined,
          error: _error,
          onSubmitted: (_) => _verify(),
        ),
        const SizedBox(height: 20),
        ZoButton(label: context.tr(AppStrings.verifyAndContinue), expand: true, loading: _busy, onPressed: _verify),
        const SizedBox(height: 16),
        Row(children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.textFaint)),
          const SizedBox(width: 10),
          Expanded(child: Text(context.tr(AppStrings.waitingApproval), style: context.text.bodySmall)),
        ]),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: AppScope.read(context).cancelDeviceApproval,
            style: TextButton.styleFrom(foregroundColor: c.textMuted),
            child: Text(context.tr(AppStrings.cancelSignIn)),
          ),
        ),
      ],
    );
  }
}

/// 所有设备丢失：Recovery Kit（Secret Key + 恢复码）从云端恢复并设置新主密码（F-08 / B-07）。
class CloudRecoverForm extends StatefulWidget {
  const CloudRecoverForm({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  State<CloudRecoverForm> createState() => _CloudRecoverFormState();
}

class _CloudRecoverFormState extends State<CloudRecoverForm> {
  late final _server = TextEditingController(text: AppConfig.defaultServerUrl);
  late final _device = TextEditingController(text: AppScope.read(context).defaultDeviceName);
  final _email = TextEditingController();
  final _sk = TextEditingController();
  final _rc = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;
  String? _error;
  int _shake = 0;

  @override
  void dispose() {
    for (final c in [_server, _device, _email, _sk, _rc, _pw, _pw2]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fail(String msg) => setState(() {
        _error = msg;
        _shake++;
      });

  Future<void> _submit() async {
    if (_busy) return;
    if (_pw.text.characters.length < 10) return _fail(context.tr(AppStrings.newPasswordTooShort));
    if (_pw.text != _pw2.text) return _fail(context.tr(AppStrings.newPasswordMismatch));
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = AppConfig.allowCustomServer ? _server.text : AppConfig.defaultServerUrl;
      await AppScope.read(context).recoverFromServer(server, _email.text, _rc.text, _sk.text, _pw.text, _device.text);
    } on CoreException catch (e) {
      if (mounted) _fail(context.tr(e.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shake(
      trigger: _shake,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZoButton(
            label: context.tr(AppStrings.back),
            icon: Icons.arrow_back_rounded,
            variant: ZoButtonVariant.ghost,
            dense: true,
            onPressed: _busy ? null : widget.onBack,
          ),
          const SizedBox(height: 24),
          AuthHeader(
            eyebrow: AppStrings.recoverEyebrow,
            title: context.tr(AppStrings.recoverAccountTitle),
            subtitle: context.tr(AppStrings.recoverAccountSubtitle),
          ),
          ZoTextField(controller: _email, label: context.tr(AppStrings.fieldEmail), prefixIcon: Icons.alternate_email_rounded, keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 14),
          ZoTextField(controller: _sk, label: AppStrings.secretKeyLabel, hint: 'V1-…', mono: true),
          const SizedBox(height: 14),
          ZoTextField(controller: _rc, label: AppStrings.recoveryCodeLabel, hint: 'R1-XXXX-XXXX-…', mono: true),
          const SizedBox(height: 14),
          ZoTextField(controller: _pw, label: context.tr(AppStrings.newMasterPassword), obscure: true, onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          StrengthMeter(strength: VaultApi.strength(_pw.text)),
          const SizedBox(height: 14),
          ZoTextField(controller: _pw2, label: context.tr(AppStrings.confirmNewMasterPassword), obscure: true, error: _error, onSubmitted: (_) => _submit()),
          const SizedBox(height: 14),
          ZoTextField(controller: _device, label: context.tr(AppStrings.thisDeviceName), prefixIcon: Icons.devices_outlined),
          const SizedBox(height: 24),
          ZoButton(label: context.tr(AppStrings.recoverAccountAction), expand: true, loading: _busy, onPressed: _submit),
        ],
      ),
    );
  }
}
