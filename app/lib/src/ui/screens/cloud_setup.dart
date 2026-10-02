import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../l10n/strings.dart';
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
        setState(
          () => _error = e is CoreException ? e.message : context.tr(AppStrings.cloudSetupRetry),
        );
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
      if (mounted && active()) showZoMessage(context, context.tr(AppStrings.cloudBackupSaved));
    } catch (e) {
      if (active()) {
        setState(
          () => _error = e is CoreException ? e.message : context.tr(AppStrings.cloudBackupFailed),
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
        title: Text(context.tr(AppStrings.wipeAndReloginTitle)),
        content: Text(context.tr(AppStrings.wipeAndReloginBody)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr(AppStrings.cancel)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.tr(AppStrings.wipeAndReloginConfirm)),
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
      if (mounted) setState(() => _error = context.tr(AppStrings.wipeIncomplete));
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
            context.tr(pending ? AppStrings.cloudFinishTitle : AppStrings.cloudAttachTitle),
            style: context.text.headlineMedium,
          ),
          const SizedBox(height: 14),
          Text(
            context.tr(pending ? AppStrings.cloudFinishBody : AppStrings.cloudAttachBody),
          ),
          const SizedBox(height: 12),
          SelectableText(
            context.trf(AppStrings.javaServiceLabel, {'url': state.settings.serverUrl}),
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 20),
          if (!state.hasStoredSecretKey) ...[
            ZoTextField(
              controller: _secretKey,
              label: AppStrings.secretKeyLabel,
              enabled: !_busy,
            ),
            const SizedBox(height: 12),
          ],
          ZoTextField(
            controller: _password,
            label: context.tr(AppStrings.currentMasterPassword),
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
          ZoButton(label: context.tr(AppStrings.cloudVerifyAndFinish), loading: _busy, onPressed: _complete),
          const SizedBox(height: 10),
          ZoButton(
            label: context.tr(AppStrings.exportBackupFirst),
            variant: ZoButtonVariant.secondary,
            onPressed: _busy ? null : _backup,
          ),
          TextButton(
            onPressed: _busy ? null : state.lock,
            child: Text(context.tr(AppStrings.lockAndContinueLater)),
          ),
          TextButton(
            onPressed: _busy ? null : _resetDevice,
            child: Text(context.tr(AppStrings.wipeAndReloginAction)),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr(AppStrings.cloudZeroKnowledgeNote),
            style: context.text.bodySmall,
          ),
        ],
      ),
    );
  }
}
