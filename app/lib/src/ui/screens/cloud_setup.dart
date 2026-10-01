import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../state/app_state.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/auth_layout.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';

/// 旧本地库与未确认注册的过渡入口，不提供继续纯本地模式，也不自动删除数据。
class CloudSetupScreen extends StatefulWidget {
  const CloudSetupScreen({super.key});
  @override
  State<CloudSetupScreen> createState() => _CloudSetupScreenState();
}

class _CloudSetupScreenState extends State<CloudSetupScreen> {
  final _password = TextEditingController();
  final _secretKey = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _secretKey.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppScope.read(context);
    try {
      await state.completeCloudRegistration(
        _password.text,
        secretKey: state.hasStoredSecretKey ? null : _secretKey.text,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is CoreException ? e.message : '注册尚未完成，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backup() async {
    final state = AppScope.read(context);
    final epoch = state.sessionEpoch;
    bool active() =>
        mounted &&
        state.phase == AppPhase.cloudSetup &&
        state.sessionEpoch == epoch;
    setState(() => _busy = true);
    try {
      final bytes = await VaultApi.exportBackup();
      if (!active()) return;
      final location = await getSaveLocation(
        suggestedName: 'VaultOne-before-cloud.wljbak',
      );
      if (location == null || !active()) return;
      await File(location.path).writeAsBytes(bytes, flush: true);
      if (mounted && active()) showZoMessage(context, '加密备份已保存；恢复仍需当前账户的密钥材料');
    } catch (e) {
      if (active()) {
        setState(
          () => _error = e is CoreException ? e.message : '备份保存失败，请检查保存位置',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetDevice() async {
    final state = AppScope.read(context);
    final epoch = state.sessionEpoch;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本机数据并重新登录？'),
        content: const Text(
          '不会注销云账户。未同步的本机条目和注册草稿会永久丢失，本机保存的 Secret Key 也会删除。请先导出备份并保管恢复材料；云注册超时并不代表云账户未创建。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除本机数据'),
          ),
        ],
      ),
    );
    if (approved != true ||
        !mounted ||
        epoch != state.sessionEpoch ||
        state.phase != AppPhase.cloudSetup) {
      return;
    }
    setState(() => _busy = true);
    try {
      await state.wipeThisDevice();
    } catch (_) {
      if (mounted) setState(() => _error = '清除未完成，请重试；云账户未被注销');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pending = state.pendingAccountOperation == 'register';
    return AuthLayout(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pending ? '完成云账户注册' : '将现有保险库接入云账户',
            style: context.text.headlineMedium,
          ),
          const SizedBox(height: 14),
          Text(
            pending ? '注册材料已在本机加密保存。只有 Java 服务确认后才完成注册；重试沿用同一账户与密钥，不会重新生成。' : '新版本使用云账户。现有条目、账户标识和密钥全部保留；请使用当前主密码完成接入。若云端同邮箱属于不同账户，不会覆盖或合并。',
          ),
          const SizedBox(height: 12),
          SelectableText(
            'Java 服务：${state.settings.serverUrl}',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 20),
          if (!state.hasStoredSecretKey) ...[
            ZoTextField(
              controller: _secretKey,
              label: 'Secret Key',
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
          ],
          ZoTextField(
            controller: _password,
            label: '当前主密码',
            obscure: true,
            enabled: !_busy,
            onSubmitted: (_) => _complete(),
          ),
          if (_error ?? state.cloudSetupError case final error?) ...[
            const SizedBox(height: 12),
            Text(
              error,
              style: context.text.bodyMedium?.copyWith(
                color: context.zo.danger,
              ),
            ),
          ],
          const SizedBox(height: 20),
          ZoButton(label: '验证并完成云注册', loading: _busy, onPressed: _complete),
          const SizedBox(height: 10),
          ZoButton(
            label: '先导出本机加密备份',
            variant: ZoButtonVariant.secondary,
            onPressed: _busy ? null : _backup,
          ),
          TextButton(
            onPressed: _busy ? null : state.lock,
            child: const Text('锁定并稍后继续'),
          ),
          TextButton(
            onPressed: _busy ? null : _resetDevice,
            child: const Text('清除本机数据后重新登录'),
          ),
          const SizedBox(height: 12),
          Text(
            '密码、Secret Key 和条目明文不会上传。完成云注册后，条目仍可离线读写，联网自动同步密文。',
            style: context.text.bodySmall,
          ),
        ],
      ),
    );
  }
}
