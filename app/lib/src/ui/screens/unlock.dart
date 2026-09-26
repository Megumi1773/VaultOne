import 'package:flutter/material.dart';

import '../../core/ffi.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/auth_layout.dart';
import '../widgets/brand.dart';
import '../widgets/controls.dart';
import 'onboarding.dart';

/// 解锁页。成功后由根组件播放 Rise 扫光过场。
class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key});

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _pw = TextEditingController();
  final _sk = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _recover = false;
  String? _error;
  int _shake = 0;

  @override
  void initState() {
    super.initState();
    // 已启用生物识别时，进入解锁页自动弹出系统验证
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && AppScope.read(context).quickUnlockEnabled) _biometric();
    });
  }

  Future<void> _biometric() async {
    final state = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.unlockWithBiometrics();
    } on CoreException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // 用户取消或系统不可用：回退到主密码
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    _sk.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final state = AppScope.read(context);
    if (_pw.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.unlock(_pw.text, secretKey: state.hasStoredSecretKey ? null : _sk.text);
    } on CoreException catch (e) {
      _pw.clear();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
        _shake++;
      });
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final c = context.zo;
    if (_recover) {
      return _RecoverFlow(onCancel: () => setState(() => _recover = false));
    }
    return AuthLayout(
      child: Shake(
        trigger: _shake,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _busy ? 1 : 0),
              duration: Zo.slow,
              builder: (context, g, _) => ZoMark(size: 52, glow: g),
            ),
            const SizedBox(height: 32),
            Text('欢迎回来', style: context.text.displayMedium),
            const SizedBox(height: 8),
            Text('输入主密码以解锁保险库', style: context.text.bodyLarge?.copyWith(color: c.textMuted)),
            const SizedBox(height: 32),
            if (!state.hasStoredSecretKey) ...[
              ZoTextField(
                controller: _sk,
                label: 'Secret Key',
                hint: 'V1-XXXXXX-XXXXXX-…',
                mono: true,
                prefixIcon: Icons.vpn_key_outlined,
              ),
              const SizedBox(height: 6),
              Text('本设备未保存 Secret Key，请从 Recovery Kit 中输入。', style: context.text.bodySmall),
              const SizedBox(height: 18),
            ],
            ZoTextField(
              controller: _pw,
              focusNode: _focus,
              label: '主密码',
              obscure: true,
              autofocus: true,
              prefixIcon: Icons.key_rounded,
              enabled: !_busy,
              error: _error,
              onSubmitted: (_) => _unlock(),
            ),
            const SizedBox(height: 22),
            ZoButton(label: _busy ? '正在解锁…' : '解锁', icon: Icons.lock_open_rounded, expand: true, loading: _busy, onPressed: _unlock),
            if (state.quickUnlockEnabled) ...[
              const SizedBox(height: 10),
              ZoButton(
                label: '使用生物识别解锁',
                icon: Icons.fingerprint_rounded,
                variant: ZoButtonVariant.secondary,
                expand: true,
                onPressed: _busy ? null : _biometric,
              ),
            ],
            const SizedBox(height: 18),
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => setState(() => _recover = true),
                style: TextButton.styleFrom(foregroundColor: c.textMuted),
                child: const Text('忘记主密码？使用 Recovery Kit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 使用 Recovery Code 重设主密码。
class _RecoverFlow extends StatefulWidget {
  const _RecoverFlow({required this.onCancel});

  final VoidCallback onCancel;

  @override
  State<_RecoverFlow> createState() => _RecoverFlowState();
}

class _RecoverFlowState extends State<_RecoverFlow> {
  final _sk = TextEditingController();
  final _rc = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool _busy = false;
  String? _error;
  int _shake = 0;

  @override
  void dispose() {
    for (final c in [_sk, _rc, _pw, _pw2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final state = AppScope.read(context);
    if (_pw.text.characters.length < 10) {
      setState(() {
        _error = '新主密码至少 10 个字符';
        _shake++;
      });
      return;
    }
    if (_pw.text != _pw2.text) {
      setState(() {
        _error = '两次输入的新主密码不一致';
        _shake++;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.recover(_rc.text, _pw.text, secretKey: state.hasStoredSecretKey ? null : _sk.text);
    } on CoreException catch (e) {
      setState(() {
        _error = e.message;
        _shake++;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pending = state.pendingEnrollment;
    if (pending != null) {
      return AuthLayout(
        child: RecoveryKitView(
          enrollment: pending,
          title: '恢复成功 · 保存新的 Recovery Kit',
          onDone: state.finishOnboarding,
        ),
      );
    }
    return AuthLayout(
      child: Shake(
        trigger: _shake,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ZoButton(label: '返回解锁', icon: Icons.arrow_back_rounded, variant: ZoButtonVariant.ghost, dense: true, onPressed: widget.onCancel),
            const SizedBox(height: 24),
            const AuthHeader(
              eyebrow: 'Recovery',
              title: '使用 Recovery Kit 恢复',
              subtitle: '输入恢复码并设置新的主密码。恢复后旧恢复码立即作废，你会拿到一份新的 Recovery Kit。',
            ),
            if (!state.hasStoredSecretKey) ...[
              ZoTextField(controller: _sk, label: 'Secret Key', hint: 'V1-…', mono: true),
              const SizedBox(height: 16),
            ],
            ZoTextField(controller: _rc, label: 'Recovery Code', hint: 'R1-XXXX-XXXX-…', mono: true, autofocus: true),
            const SizedBox(height: 16),
            ZoTextField(controller: _pw, label: '新主密码', obscure: true),
            const SizedBox(height: 16),
            ZoTextField(controller: _pw2, label: '确认新主密码', obscure: true, onSubmitted: (_) => _submit()),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: context.text.bodySmall?.copyWith(color: context.zo.danger)),
            ],
            const SizedBox(height: 24),
            ZoButton(label: '重设主密码', expand: true, loading: _busy, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}

/// 启动失败时的兜底页。
class FatalScreen extends StatelessWidget {
  const FatalScreen({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: context.zo.danger, size: 36),
          const SizedBox(height: 18),
          Text('无法打开保险库', style: context.text.headlineMedium),
          const SizedBox(height: 10),
          SelectableText(message, style: context.text.bodyMedium?.copyWith(color: context.zo.textMuted)),
          const SizedBox(height: 18),
          Text('数据文件未被修改。请将以上信息反馈给我们。', style: context.text.bodySmall),
        ],
      ),
    );
  }
}
