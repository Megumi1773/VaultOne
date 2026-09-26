import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
import 'generator_page.dart';
import 'home.dart';
import 'qr_scan.dart';

class _UrlDraft {
  _UrlDraft(String url, this.match) : controller = TextEditingController(text: url);

  final TextEditingController controller;
  UrlMatch match;
}

class _FieldDraft {
  _FieldDraft(String label, String value, this.sensitive)
      : label = TextEditingController(text: label),
        value = TextEditingController(text: value);

  final TextEditingController label;
  final TextEditingController value;
  bool sensitive;
}

/// 条目编辑器（新建与编辑共用）。Ctrl+S 保存，Esc 取消。
class ItemEditor extends StatefulWidget {
  const ItemEditor({super.key, required this.target, required this.onCancel, required this.onSaved, this.initial});

  final EditTarget target;
  final ItemData? initial;
  final VoidCallback onCancel;
  final ValueChanged<VaultItem> onSaved;

  @override
  State<ItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends State<ItemEditor> {
  late final ItemData? d = widget.initial;
  late final ItemKind kind = widget.target.kind;

  late final _title = TextEditingController(text: d?.title ?? '');
  late final _username = TextEditingController(text: d?.username ?? '');
  late final _password = TextEditingController(text: d?.password ?? '');
  late final _totp = TextEditingController(text: d?.totp?.secret ?? '');
  late final _notes = TextEditingController(text: d?.notes ?? '');

  late final _holder = TextEditingController(text: d?.card?.cardholder ?? '');
  late final _number = TextEditingController(text: d?.card?.number ?? '');
  late final _expiry = TextEditingController(text: d?.card?.expiry ?? '');
  late final _cvv = TextEditingController(text: d?.card?.cvv ?? '');
  late final _pin = TextEditingController(text: d?.card?.pin ?? '');

  late final _fullName = TextEditingController(text: d?.identity?.fullName ?? '');
  late final _idEmail = TextEditingController(text: d?.identity?.email ?? '');
  late final _phone = TextEditingController(text: d?.identity?.phone ?? '');
  late final _idNumber = TextEditingController(text: d?.identity?.idNumber ?? '');
  late final _address = TextEditingController(text: d?.identity?.address ?? '');
  late final _company = TextEditingController(text: d?.identity?.company ?? '');

  late final List<_UrlDraft> _urls = [
    for (final u in d?.urls ?? const <ItemUrl>[]) _UrlDraft(u.url, u.match),
    if (kind == ItemKind.login && (d?.urls.isEmpty ?? true)) _UrlDraft('', UrlMatch.domain),
  ];
  late final List<_FieldDraft> _fields = [for (final f in d?.customFields ?? const <CustomField>[]) _FieldDraft(f.label, f.value, f.sensitive)];

  TotpConfig? _totpConfig;
  String? _totpError;
  String? _titleError;
  Strength _strength = Strength.empty;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _totpConfig = d?.totp;
    _strength = VaultApi.strength(_password.text);
  }

  @override
  void dispose() {
    for (final c in [
      _title, _username, _password, _totp, _notes, _holder, _number, _expiry, _cvv, _pin, //
      _fullName, _idEmail, _phone, _idNumber, _address, _company,
    ]) {
      c.dispose();
    }
    for (final u in _urls) {
      u.controller.dispose();
    }
    for (final f in _fields) {
      f.label.dispose();
      f.value.dispose();
    }
    super.dispose();
  }

  void _parseTotp(String text) {
    final t = text.trim();
    if (t.isEmpty) {
      setState(() {
        _totpConfig = null;
        _totpError = null;
      });
      return;
    }
    try {
      final parsed = VaultApi.parseTotp(t);
      setState(() {
        _totpConfig = parsed.config;
        _totpError = null;
        if (_title.text.isEmpty && parsed.issuer != null) _title.text = parsed.issuer!;
        if (_username.text.isEmpty && parsed.account != null) _username.text = parsed.account!;
      });
      if (t.toLowerCase().startsWith('otpauth://')) _totp.text = parsed.config.secret;
    } on CoreException catch (e) {
      setState(() {
        _totpConfig = null;
        _totpError = e.message;
      });
    }
  }

  String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text;

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _titleError = '请输入标题');
      return;
    }
    if (_totpError != null) return;
    final data = ItemData(
      kind: kind,
      title: _title.text.trim(),
      urls: [
        for (final u in _urls)
          if (u.controller.text.trim().isNotEmpty) ItemUrl(url: u.controller.text.trim(), match: u.match),
      ],
      username: kind == ItemKind.login ? _opt(_username) : null,
      password: kind == ItemKind.login ? _opt(_password) : null,
      totp: kind == ItemKind.login ? _totpConfig : null,
      notes: _opt(_notes),
      card: kind == ItemKind.card
          ? CardData(cardholder: _holder.text.trim(), number: _number.text.trim(), expiry: _expiry.text.trim(), cvv: _cvv.text.trim(), pin: _pin.text.trim())
          : null,
      identity: kind == ItemKind.identity
          ? IdentityData(
              fullName: _fullName.text.trim(),
              email: _idEmail.text.trim(),
              phone: _phone.text.trim(),
              idNumber: _idNumber.text.trim(),
              address: _address.text.trim(),
              company: _company.text.trim(),
            )
          : null,
      customFields: [
        for (final f in _fields)
          if (f.label.text.trim().isNotEmpty || f.value.text.isNotEmpty) CustomField(label: f.label.text.trim(), value: f.value.text, sensitive: f.sensitive),
      ],
      favorite: d?.favorite ?? false,
    );
    setState(() => _saving = true);
    try {
      final item = await AppScope.read(context).save(widget.target.itemId, data);
      if (mounted) {
        showZoMessage(context, widget.target.itemId == null ? '已创建「${data.title}」' : '已保存');
        widget.onSaved(item);
      }
    } on CoreException catch (e) {
      if (mounted) showZoMessage(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openGenerator() async {
    final value = await showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => const GeneratorDialog(),
    );
    if (value != null) {
      _password.text = value;
      setState(() => _strength = VaultApi.strength(value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final isNew = widget.target.itemId == null;

    final body = <Widget>[
      ZoTextField(
        controller: _title,
        label: '标题',
        hint: switch (kind) { ItemKind.login => '例如：GitHub', ItemKind.card => '例如：招商银行信用卡', ItemKind.note => '例如：服务器备忘', ItemKind.identity => '例如：本人' },
        autofocus: isNew,
        error: _titleError,
        onChanged: (_) => setState(() => _titleError = null),
      ),
    ];

    if (kind == ItemKind.login) {
      body.addAll([
        _gap,
        _EditGroup(title: '登录凭据', children: [
          ZoTextField(controller: _username, label: '用户名 / 邮箱', prefixIcon: Icons.person_outline_rounded),
          _gapS,
          ZoTextField(
            controller: _password,
            label: '密码',
            obscure: true,
            mono: true,
            prefixIcon: Icons.password_rounded,
            onChanged: (v) => setState(() => _strength = VaultApi.strength(v, inputs: [_title.text, _username.text])),
            trailing: [ZoIconButton(icon: Icons.auto_awesome_outlined, tooltip: '生成强密码', size: 28, onPressed: _openGenerator)],
          ),
          const SizedBox(height: 8),
          StrengthMeter(strength: _strength),
          _gapS,
          ZoTextField(
            controller: _totp,
            label: '两步验证（TOTP）',
            hint: '粘贴 otpauth:// 链接或 Base32 密钥',
            mono: true,
            prefixIcon: Icons.timer_outlined,
            error: _totpError,
            onChanged: _parseTotp,
            trailing: [
              if (QrScanPage.supported)
                ZoIconButton(
                  icon: Icons.qr_code_scanner_rounded,
                  tooltip: '扫描二维码',
                  onPressed: () async {
                    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
                    if (raw != null) {
                      _totp.text = raw;
                      _parseTotp(raw);
                    }
                  },
                ),
            ],
          ),
          if (_totpConfig != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              Text('预览', style: context.text.labelMedium),
              const SizedBox(width: 12),
              TotpView(config: _totpConfig!),
              const Spacer(),
              Text('${_totpConfig!.alg} · ${_totpConfig!.digits} 位 · ${_totpConfig!.period}s', style: context.text.bodySmall),
            ]),
          ],
        ]),
        _gap,
        _EditGroup(
          title: '网站',
          action: ZoButton(
            label: '添加',
            icon: Icons.add_rounded,
            variant: ZoButtonVariant.ghost,
            dense: true,
            onPressed: () => setState(() => _urls.add(_UrlDraft('', UrlMatch.domain))),
          ),
          children: [
            for (var i = 0; i < _urls.length; i++) ...[
              if (i > 0) _gapS,
              Row(children: [
                Expanded(child: ZoTextField(controller: _urls[i].controller, hint: 'https://example.com', prefixIcon: Icons.link_rounded, dense: true)),
                const SizedBox(width: 8),
                _MatchPicker(value: _urls[i].match, onChanged: (m) => setState(() => _urls[i].match = m)),
                ZoIconButton(
                  icon: Icons.remove_circle_outline_rounded,
                  tooltip: '移除',
                  onPressed: () => setState(() => _urls.removeAt(i).controller.dispose()),
                ),
              ]),
            ],
          ],
        ),
      ]);
    }

    if (kind == ItemKind.card) {
      body.addAll([
        _gap,
        _EditGroup(title: '卡片信息', children: [
          ZoTextField(controller: _holder, label: '持卡人'),
          _gapS,
          ZoTextField(
            controller: _number,
            label: '卡号',
            mono: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')), LengthLimitingTextInputFormatter(23)],
          ),
          _gapS,
          Row(children: [
            Expanded(child: ZoTextField(controller: _expiry, label: '有效期', hint: 'MM/YY', mono: true)),
            const SizedBox(width: 12),
            Expanded(child: ZoTextField(controller: _cvv, label: '安全码', obscure: true, mono: true)),
            const SizedBox(width: 12),
            Expanded(child: ZoTextField(controller: _pin, label: 'PIN', obscure: true, mono: true)),
          ]),
        ]),
      ]);
    }

    if (kind == ItemKind.identity) {
      body.addAll([
        _gap,
        _EditGroup(title: '身份信息', children: [
          Row(children: [
            Expanded(child: ZoTextField(controller: _fullName, label: '姓名')),
            const SizedBox(width: 12),
            Expanded(child: ZoTextField(controller: _company, label: '公司')),
          ]),
          _gapS,
          Row(children: [
            Expanded(child: ZoTextField(controller: _idEmail, label: '邮箱')),
            const SizedBox(width: 12),
            Expanded(child: ZoTextField(controller: _phone, label: '电话')),
          ]),
          _gapS,
          ZoTextField(controller: _idNumber, label: '证件号', obscure: true, mono: true),
          _gapS,
          ZoTextField(controller: _address, label: '地址', maxLines: 2),
        ]),
      ]);
    }

    body.addAll([
      _gap,
      _EditGroup(
        title: '自定义字段',
        action: ZoButton(
          label: '添加',
          icon: Icons.add_rounded,
          variant: ZoButtonVariant.ghost,
          dense: true,
          onPressed: () => setState(() => _fields.add(_FieldDraft('', '', false))),
        ),
        children: [
          if (_fields.isEmpty) Text('例如：安全问题、U 盾编号、API Key', style: context.text.bodySmall?.copyWith(color: c.textFaint)),
          for (var i = 0; i < _fields.length; i++) ...[
            if (i > 0) _gapS,
            Row(children: [
              SizedBox(width: 150, child: ZoTextField(controller: _fields[i].label, hint: '名称', dense: true)),
              const SizedBox(width: 8),
              Expanded(child: ZoTextField(controller: _fields[i].value, hint: '值', dense: true, obscure: _fields[i].sensitive)),
              ZoIconButton(
                icon: _fields[i].sensitive ? Icons.lock_rounded : Icons.lock_open_rounded,
                tooltip: _fields[i].sensitive ? '敏感字段（默认隐藏）' : '普通字段',
                active: _fields[i].sensitive,
                onPressed: () => setState(() => _fields[i].sensitive = !_fields[i].sensitive),
              ),
              ZoIconButton(
                icon: Icons.remove_circle_outline_rounded,
                tooltip: '移除',
                onPressed: () => setState(() {
                  final f = _fields.removeAt(i);
                  f.label.dispose();
                  f.value.dispose();
                }),
              ),
            ]),
          ],
        ],
      ),
      _gap,
      _EditGroup(title: kind == ItemKind.note ? '内容' : '备注', children: [
        ZoTextField(controller: _notes, maxLines: kind == ItemKind.note ? 16 : 5, minLines: kind == ItemKind.note ? 10 : 3, hint: '仅你可见，端到端加密'),
      ]),
    ]);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(32, 22, 24, 18),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
            child: Row(
              children: [
                Icon(kind.icon, size: 18, color: c.accent),
                const SizedBox(width: 10),
                Text(isNew ? '新建${kind.label}' : '编辑${kind.label}', style: context.text.headlineSmall),
                const Spacer(),
                Text('Ctrl+S 保存 · Esc 取消', style: context.text.bodySmall?.copyWith(color: c.textFaint)),
                const SizedBox(width: 16),
                ZoButton(label: '取消', variant: ZoButtonVariant.ghost, dense: true, onPressed: widget.onCancel),
                const SizedBox(width: 8),
                ZoButton(label: '保存', icon: Icons.check_rounded, dense: true, loading: _saving, onPressed: _save),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
              children: [
                Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: body))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

const _gap = SizedBox(height: 20);
const _gapS = SizedBox(height: 14);

class _EditGroup extends StatelessWidget {
  const _EditGroup({required this.title, required this.children, this.action});

  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ZoPanel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 32, child: SectionLabel(title, trailing: action)),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _MatchPicker extends StatelessWidget {
  const _MatchPicker({required this.value, required this.onChanged});

  final UrlMatch value;
  final ValueChanged<UrlMatch> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return PopupMenuButton<UrlMatch>(
      tooltip: '匹配方式（自动填充时使用）',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in UrlMatch.values)
          PopupMenuItem(value: m, height: 36, child: Text('${m.label}匹配', style: context.text.bodyMedium)),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(border: Border.all(color: c.border), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Text(value.label, style: context.text.bodySmall?.copyWith(color: c.text)),
          Icon(Icons.expand_more_rounded, size: 16, color: c.textMuted),
        ]),
      ),
    );
  }
}
