import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../state/clipboard.dart';
import '../state/scope.dart';
import '../ui/screens/unlock.dart';
import '../ui/theme.dart';
import '../ui/widgets/brand.dart';
import '../ui/widgets/controls.dart';
import '../ui/widgets/vault_widgets.dart';

/// Android 自动填充界面（由 `AutofillActivity` 以独立 Dart 入口 `autofillMain` 启动）。
///
/// 与主界面共用同一个 Rust 保险库实例（同进程），主界面已解锁时无需再次解锁。
/// - 填充：网页表单按真实域名由内核做防钓鱼匹配，推荐匹配项；应用内表单不自动匹配，由用户搜索选择；
/// - 保存：展示将要保存的用户名与站点，用户确认后加密写入（同站点同用户名则更新密码）。
class AutofillApp extends StatefulWidget {
  const AutofillApp({super.key, required this.dbPath, required this.logDir});

  final String dbPath;
  final String logDir;

  @override
  State<AutofillApp> createState() => _AutofillAppState();
}

/// 与 Kotlin `AutofillActivity` 约定的请求内容。
class AutofillRequest {
  const AutofillRequest({required this.save, this.webDomain, this.pageUrl, this.packageName, this.username, this.password});

  final bool save;
  final String? webDomain;
  final String? pageUrl;
  final String? packageName;
  final String? username;
  final String? password;

  /// 展示用的来源名称；没有来源时由调用方补当前语言的兜底文案。
  String? get source => webDomain ?? packageName;

  /// 应用内表单：从包名推测搜索词（com.taobao.taobao → taobao）
  String get searchHint {
    if (webDomain != null) return '';
    const noise = {'com', 'cn', 'org', 'net', 'android', 'app', 'apps', 'mobile', 'client', 'www'};
    final parts = (packageName ?? '').split('.').where((p) => p.length > 1 && !noise.contains(p)).toList();
    return parts.isEmpty ? '' : parts.first;
  }
}

class _AutofillAppState extends State<AutofillApp> {
  static const _channel = MethodChannel('vaultone/autofill');
  final _state = AppState();
  AutofillRequest? _request;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = (await _channel.invokeMapMethod<String, Object?>('request')) ?? const {};
    String? str(String k) => (raw[k] as String?)?.trim().isEmpty ?? true ? null : raw[k] as String;
    _request = AutofillRequest(
      save: raw['mode'] == 'save',
      webDomain: str('webDomain'),
      pageUrl: str('pageUrl'),
      packageName: str('packageName'),
      username: str('username'),
      password: str('password'),
    );
    await _state.init(widget.dbPath, widget.logDir);
    // 主界面已在同进程解锁时，状态直接为已解锁，需自行载入条目
    if (_state.phase == AppPhase.unlocked) await _state.refresh(sync: false);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: ListenableBuilder(
        listenable: _state,
        // 自动填充界面是独立引擎与独立入口，同样要跟随设置里的语言。
        builder: (context, _) => LocaleScope(
          language: _state.settings.language,
          child: MaterialApp(
          title: 'VaultOne',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          locale: _state.settings.language.locale,
          supportedLocales: [for (final l in AppStrings.supported) l.locale],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
            home: Scaffold(body: SafeArea(child: _body())),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final r = _request;
    if (r == null || _state.phase == AppPhase.loading) return const Center(child: ZoMark(size: 48));
    return switch (_state.phase) {
      AppPhase.unlocked => r.save ? _SavePage(request: r) : _PickPage(request: r),
      AppPhase.locked when _state.pendingEnrollment == null => const UnlockScreen(),
      AppPhase.error => _Message(text: _state.fatalError ?? context.tr(AppStrings.fatalOpenVaultFailed)),
      _ => _Message(text: context.tr(AppStrings.autofillSetupFirst)),
    };
  }
}

Future<void> _cancel() => const MethodChannel('vaultone/autofill').invokeMethod('cancel');

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const ZoMark(size: 40),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center, style: context.text.bodyMedium),
            const SizedBox(height: 20),
            ZoButton(
              label: context.tr(AppStrings.close),
              variant: ZoButtonVariant.secondary,
              onPressed: _cancel,
            ),
          ]),
        ),
      );
}

/// 选择要填充的登录条目。
class _PickPage extends StatefulWidget {
  const _PickPage({required this.request});

  final AutofillRequest request;

  @override
  State<_PickPage> createState() => _PickPageState();
}

class _PickPageState extends State<_PickPage> {
  late final _query = TextEditingController(text: widget.request.searchHint);
  Set<String> _matched = const {};

  @override
  void initState() {
    super.initState();
    final url = widget.request.pageUrl;
    if (url != null) {
      VaultApi.matchItems(url).then((ids) {
        if (mounted) setState(() => _matched = ids.toSet());
      });
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _fill(VaultItem item) async {
    final state = AppScope.read(context);
    final totp = item.data.totp;
    if (totp != null) {
      // 两步验证码通常在下一步输入，填充时顺带复制
      await ClipboardService.copy(
        VaultApi.totp(totp).code,
        label: context.tr(AppStrings.fieldTotp),
        clearAfterSeconds: state.settings.clipboardSeconds,
      );
    }
    await const MethodChannel('vaultone/autofill').invokeMethod('fill', {
      'username': item.data.username ?? '',
      'password': item.data.password ?? '',
      'title': item.data.title,
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final q = _query.text.trim().toLowerCase();
    final logins = state.items.where((i) => i.data.kind == ItemKind.login).toList();
    final matched = logins.where((i) => _matched.contains(i.id)).toList();
    final others = logins.where((i) => !_matched.contains(i.id) && (q.isEmpty || i.data.searchText.contains(q))).toList()
      ..sort((a, b) => a.data.title.toLowerCase().compareTo(b.data.title.toLowerCase()));

    Widget tile(VaultItem i) => ListTile(
          leading: Icon(i.data.kind.icon, color: context.zo.textMuted),
          title: Text(i.data.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            i.data.username ?? context.tr(AppStrings.autofillNoUsername),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: i.data.totp != null ? Icon(Icons.timer_outlined, size: 18, color: context.zo.textFaint) : null,
          onTap: () => _fill(i),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text(
                context.trf(AppStrings.autofillFillTo, {
                  'source': widget.request.source ?? context.tr(AppStrings.autofillUnknownApp),
                }),
                style: context.text.titleLarge,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: context.tr(AppStrings.cancel),
              onPressed: _cancel,
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ZoTextField(
            controller: _query,
            hint: context.tr(AppStrings.searchItemsHint),
            prefixIcon: Icons.search_rounded,
            onChanged: (_) => setState(() {}),
          ),
        ),
        Expanded(
          child: ListView(children: [
            if (matched.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: SectionLabel(context.tr(AppStrings.autofillMatchedSite)),
              ),
              for (final i in matched) tile(i),
            ],
            if (widget.request.webDomain == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  context.tr(AppStrings.autofillAppNoMatch),
                  style: context.text.bodySmall,
                ),
              ),
            if (others.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: SectionLabel(
                  context.tr(
                    matched.isEmpty ? AppStrings.autofillAllLogins : AppStrings.autofillOtherItems,
                  ),
                ),
              ),
              for (final i in others) tile(i),
            ],
            if (matched.isEmpty && others.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text(context.tr(AppStrings.autofillNoLogins))),
              ),
          ]),
        ),
      ],
    );
  }
}

/// 确认保存新凭据（或更新已有条目的密码）。
class _SavePage extends StatefulWidget {
  const _SavePage({required this.request});

  final AutofillRequest request;

  @override
  State<_SavePage> createState() => _SavePageState();
}

class _SavePageState extends State<_SavePage> {
  VaultItem? _existing;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final url = widget.request.pageUrl;
    if (url != null) {
      final state = AppScope.read(context);
      VaultApi.matchItems(url).then((ids) {
        final hit = state.items.where((i) => ids.contains(i.id) && (i.data.username ?? '') == (widget.request.username ?? ''));
        if (mounted) setState(() => _existing = hit.isEmpty ? null : hit.first);
      });
    }
  }

  Future<void> _save() async {
    final state = AppScope.read(context);
    final r = widget.request;
    setState(() => _busy = true);
    try {
      final existing = _existing;
      if (existing != null) {
        await state.save(existing.id, existing.data.copyWith(password: r.password));
      } else {
        await state.save(
          null,
          ItemData(
            kind: ItemKind.login,
            title: r.source ?? context.tr(AppStrings.autofillUnknownApp),
            urls: [if (r.pageUrl != null) ItemUrl(url: r.pageUrl!)],
            username: r.username,
            password: r.password,
          ),
        );
      }
      await const MethodChannel('vaultone/autofill').invokeMethod('done');
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showZoMessage(context, context.tr(AppStrings.autofillSaveFailed), error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final update = _existing != null;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: ZoMark(size: 40)),
          const SizedBox(height: 20),
          Text(
            update
                ? context.trf(AppStrings.autofillUpdatePassword, {'title': _existing!.data.title})
                : context.tr(AppStrings.autofillSaveToVault),
            textAlign: TextAlign.center,
            style: context.text.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '${r.username ?? context.tr(AppStrings.autofillNoUsername)} · '
            '${r.source ?? context.tr(AppStrings.autofillUnknownApp)}',
            textAlign: TextAlign.center,
            style: context.text.bodyMedium?.copyWith(color: context.zo.textMuted),
          ),
          const SizedBox(height: 28),
          ZoButton(
            label: context.tr(update ? AppStrings.autofillUpdate : AppStrings.save),
            loading: _busy,
            onPressed: _save,
          ),
          const SizedBox(height: 8),
          ZoButton(
            label: context.tr(AppStrings.autofillDontSave),
            variant: ZoButtonVariant.ghost,
            onPressed: _cancel,
          ),
        ],
      ),
    );
  }
}
