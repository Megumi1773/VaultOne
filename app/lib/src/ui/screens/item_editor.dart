import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/item_templates.dart';
import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';
import 'generator_page.dart';
import 'home.dart';
import 'qr_scan.dart';

class _UrlDraft {
  _UrlDraft(String url, this.match)
    : controller = TextEditingController(text: url);

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
  const ItemEditor({
    super.key,
    required this.target,
    required this.onCancel,
    required this.onSaved,
    this.initial,
  });

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

  late final _fullName = TextEditingController(
    text: d?.identity?.fullName ?? '',
  );
  late final _idEmail = TextEditingController(text: d?.identity?.email ?? '');
  late final _phone = TextEditingController(text: d?.identity?.phone ?? '');
  late final _idNumber = TextEditingController(
    text: d?.identity?.idNumber ?? '',
  );
  late final _address = TextEditingController(text: d?.identity?.address ?? '');
  late final _company = TextEditingController(text: d?.identity?.company ?? '');

  late final List<_UrlDraft> _urls = [
    for (final u in d?.urls ?? const <ItemUrl>[]) _UrlDraft(u.url, u.match),
    if (kind == ItemKind.login && (d?.urls.isEmpty ?? true))
      _UrlDraft('', UrlMatch.domain),
  ];
  late final List<_FieldDraft> _fields = [
    for (final f in d?.customFields ?? const <CustomField>[])
      _FieldDraft(f.label, f.value, f.sensitive),
  ];

  TotpConfig? _totpConfig;
  String? _totpError;
  String? _titleError;
  Strength _strength = Strength.empty;
  bool _saving = false;
  ItemTemplate? _template;
  Set<String> _templateFieldLabels = {};

  /// 已确认的标签；输入框里的未提交文本在 `_tagInput` 中。
  late final List<String> _tags = [...?d?.tags];
  final _tagInput = TextEditingController();
  late final _category = TextEditingController(text: d?.category ?? '');

  @override
  void initState() {
    super.initState();
    _totpConfig = d?.totp;
    _strength = VaultApi.strength(_password.text);
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _username,
      _password,
      _totp,
      _notes,
      _holder,
      _number,
      _expiry,
      _cvv,
      _pin, //
      _fullName, _idEmail, _phone, _idNumber, _address, _company,
    ]) {
      c.dispose();
    }
    _tagInput.dispose();
    _category.dispose();
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
        if (_title.text.isEmpty && parsed.issuer != null) {
          _title.text = parsed.issuer!;
        }
        if (_username.text.isEmpty && parsed.account != null) {
          _username.text = parsed.account!;
        }
      });
      if (t.toLowerCase().startsWith('otpauth://')) {
        _totp.text = parsed.config.secret;
      }
    } on CoreException catch (e) {
      setState(() {
        _totpConfig = null;
        _totpError = e.message;
      });
    }
  }

  String? _opt(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text;

  Future<void> _save() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _titleError = context.tr(AppStrings.titleRequired));
      return;
    }
    if (_totpError != null) return;
    final data = ItemData(
      kind: kind,
      title: _title.text.trim(),
      urls: [
        for (final u in _urls)
          if (u.controller.text.trim().isNotEmpty)
            ItemUrl(url: u.controller.text.trim(), match: u.match),
      ],
      username: kind == ItemKind.login ? _opt(_username) : null,
      password: kind == ItemKind.login ? _opt(_password) : null,
      totp: kind == ItemKind.login ? _totpConfig : null,
      notes: _opt(_notes),
      card: kind == ItemKind.card
          ? CardData(
              cardholder: _holder.text.trim(),
              number: _number.text.trim(),
              expiry: _expiry.text.trim(),
              cvv: _cvv.text.trim(),
              pin: _pin.text.trim(),
            )
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
          if (f.label.text.trim().isNotEmpty || f.value.text.isNotEmpty)
            CustomField(
              label: f.label.text.trim(),
              value: f.value.text,
              sensitive: f.sensitive,
            ),
      ],
      favorite: d?.favorite ?? false,
      tags: _tags,
      category: _category.text.trim().isEmpty ? null : _category.text.trim(),
    );
    setState(() => _saving = true);
    try {
      final item = await AppScope.read(context)
          .save(widget.target.itemId, data);
      if (mounted) {
        showZoMessage(
          context,
          widget.target.itemId == null
              ? context.trf(AppStrings.createdItem, {'title': data.title})
              : context.tr(AppStrings.saved),
        );
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

  /// 应用模板：只预置标题和自定义字段，不覆盖用户已经填写的内容。
  void _applyTemplate(ItemTemplate template) {
    setState(() {
      _removeTemplateFields();
      _template = template;
      if (_title.text.trim().isEmpty && template.defaultTitle != null) {
        _title.text = template.defaultTitle!;
      }
      for (final field in template.fields) {
        final exists = _fields.any(
          (item) => item.label.text.trim() == field.label,
        );
        if (!exists) {
          _fields.add(_FieldDraft(field.label, '', field.sensitive));
          _templateFieldLabels.add(field.label);
        }
      }
    });
  }

  /// 回到完整字段表单；仅移除上一模板留下的空字段。
  void _clearTemplate() {
    setState(() {
      _removeTemplateFields();
      _template = null;
    });
  }

  /// 确认输入框里的标签。空白忽略；与已有标签重复（忽略大小写）时只清空输入不新增，
  /// 与内核 `normalize_tags` 的去重语义一致，避免用户看到「加了却没多出来」。
  void _commitTag() {
    final raw = _tagInput.text.trim();
    if (raw.isEmpty) return;
    setState(() {
      final exists = _tags.any((t) => t.toLowerCase() == raw.toLowerCase());
      if (!exists) _tags.add(raw);
      _tagInput.clear();
    });
  }

  void _removeTag(String tag) => setState(() => _tags.remove(tag));

  void _removeTemplateFields() {    for (var i = _fields.length - 1; i >= 0; i--) {
      final field = _fields[i];
      if (_templateFieldLabels.contains(field.label.text.trim()) &&
          field.value.text.isEmpty) {
        field.label.dispose();
        field.value.dispose();
        _fields.removeAt(i);
      }
    }
    _templateFieldLabels = {};
  }

  /// 模板未声明的分区默认隐藏；已有内容的分区强制保留，避免模板切换导致内容不可见。
  bool _shows(TemplateSection section) {
    if (_template == null) return true;
    final declared = _template!.shows(section);
    return switch (section) {
      TemplateSection.loginCredentials =>
        declared ||
            _username.text.isNotEmpty ||
            _password.text.isNotEmpty ||
            _totp.text.isNotEmpty,
      TemplateSection.website =>
        declared || _urls.any((url) => url.controller.text.trim().isNotEmpty),
      TemplateSection.card =>
        declared ||
            _holder.text.isNotEmpty ||
            _number.text.isNotEmpty ||
            _expiry.text.isNotEmpty ||
            _cvv.text.isNotEmpty ||
            _pin.text.isNotEmpty,
      TemplateSection.identity =>
        declared ||
            _fullName.text.isNotEmpty ||
            _idEmail.text.isNotEmpty ||
            _phone.text.isNotEmpty ||
            _idNumber.text.isNotEmpty ||
            _address.text.isNotEmpty ||
            _company.text.isNotEmpty,
      TemplateSection.customFields => declared || _fields.isNotEmpty,
      TemplateSection.notes => declared || _notes.text.isNotEmpty,
    };
  }

  List<Widget> _withGaps(List<Widget> groups) => [
    for (var i = 0; i < groups.length; i++) ...[if (i > 0) _gap, groups[i]],
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final isNew = widget.target.itemId == null;

    final body = <Widget>[
      ZoTextField(
        controller: _title,
        label: context.tr(AppStrings.titleLabel),
        hint: _template?.titleHint(context) ??
            switch (kind) {
              ItemKind.login => context.tr(AppStrings.hintLoginTitle),
              ItemKind.card => context.tr(AppStrings.hintCardTitle),
              ItemKind.note => context.tr(AppStrings.hintNoteTitle),
              ItemKind.identity => context.tr(AppStrings.hintIdentityTitle),
            },
        autofocus: isNew,
        error: _titleError,
        onChanged: (_) => setState(() => _titleError = null),
      ),
      if (isNew) ...[
        _gap,
        _TemplatePicker(
          templates: itemTemplatesFor(kind),
          selected: _template,
          onSelected: _applyTemplate,
          onClear: _clearTemplate,
        ),
      ],
    ];

    if (kind == ItemKind.login) {
      final groups = <Widget>[
        if (_shows(TemplateSection.loginCredentials))
          _EditGroup(
            title: context.tr(AppStrings.groupLoginCredentials),
            children: [
              ZoTextField(
                controller: _username,
                label: context.tr(AppStrings.fieldUsernameOrEmail),
                prefixIcon: Icons.person_outline_rounded,
              ),
              _gapS,
              ZoTextField(
                controller: _password,
                label: context.tr(AppStrings.fieldPassword),
                obscure: true,
                mono: true,
                prefixIcon: Icons.password_rounded,
                onChanged: (v) => setState(
                  () => _strength = VaultApi.strength(
                    v,
                    inputs: [_title.text, _username.text],
                  ),
                ),
                trailing: [
                  ZoIconButton(
                    icon: Icons.auto_awesome_outlined,
                    tooltip: context.tr(AppStrings.generateStrongPassword),
                    size: 28,
                    onPressed: _openGenerator,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              StrengthMeter(strength: _strength),
              _gapS,
              ZoTextField(
                controller: _totp,
                label: context.tr(AppStrings.fieldTotpFull),
                hint: '粘贴 otpauth:// 链接或 Base32 密钥',
                mono: true,
                prefixIcon: Icons.timer_outlined,
                error: _totpError,
                onChanged: _parseTotp,
                trailing: [
                  if (QrScanPage.supported)
                    ZoIconButton(
                      icon: Icons.qr_code_scanner_rounded,
                      tooltip: context.tr(AppStrings.scanQrCode),
                      onPressed: () async {
                        final raw = await Navigator.of(context).push<String>(
                          MaterialPageRoute(builder: (_) => const QrScanPage()),
                        );
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
                Row(
                  children: [
                    Text(context.tr(AppStrings.preview), style: context.text.labelMedium),
                    const SizedBox(width: 12),
                    TotpView(config: _totpConfig!),
                    const Spacer(),
                    Text(
                      context.trf(AppStrings.totpParams, {
                        'alg': _totpConfig!.alg,
                        'digits': _totpConfig!.digits,
                        'period': _totpConfig!.period,
                      }),
                      style: context.text.bodySmall,
                    ),
                  ],
                ),
              ],
            ],
          ),
        if (_shows(TemplateSection.website))
          _EditGroup(
            title: context.tr(AppStrings.groupWebsite),
            action: ZoButton(
              label: context.tr(AppStrings.addAction),
              icon: Icons.add_rounded,
              variant: ZoButtonVariant.ghost,
              dense: true,
              onPressed: () =>
                  setState(() => _urls.add(_UrlDraft('', UrlMatch.domain))),
            ),
            children: [
              for (var i = 0; i < _urls.length; i++) ...[
                if (i > 0) _gapS,
                Row(
                  children: [
                    Expanded(
                      child: ZoTextField(
                        controller: _urls[i].controller,
                        hint: 'https://example.com',
                        prefixIcon: Icons.link_rounded,
                        dense: true,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _MatchPicker(
                      value: _urls[i].match,
                      onChanged: (m) => setState(() => _urls[i].match = m),
                    ),
                    ZoIconButton(
                      icon: Icons.remove_circle_outline_rounded,
                      tooltip: context.tr(AppStrings.removeAction),
                      onPressed: () => setState(
                        () => _urls.removeAt(i).controller.dispose(),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
      ];
      if (groups.isNotEmpty) body.addAll([_gap, ..._withGaps(groups)]);
    }

    if (kind == ItemKind.card && _shows(TemplateSection.card)) {
      body.addAll([
        _gap,
        _EditGroup(
          title: context.tr(AppStrings.groupCardInfo),
          children: [
            ZoTextField(controller: _holder, label: context.tr(AppStrings.fieldCardholder)),
            _gapS,
            ZoTextField(
              controller: _number,
              label: context.tr(AppStrings.fieldCardNumber),
              mono: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                LengthLimitingTextInputFormatter(23),
              ],
            ),
            _gapS,
            Row(
              children: [
                Expanded(
                  child: ZoTextField(
                    controller: _expiry,
                    label: context.tr(AppStrings.fieldExpiry),
                    hint: 'MM/YY',
                    mono: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ZoTextField(
                    controller: _cvv,
                    label: context.tr(AppStrings.fieldCvv),
                    obscure: true,
                    mono: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ZoTextField(
                    controller: _pin,
                    label: AppStrings.fieldPin,
                    obscure: true,
                    mono: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ]);
    }

    if (kind == ItemKind.identity && _shows(TemplateSection.identity)) {
      body.addAll([
        _gap,
        _EditGroup(
          title: context.tr(AppStrings.sectionIdentity),
          children: [
            Row(
              children: [
                Expanded(
                  child: ZoTextField(controller: _fullName, label: context.tr(AppStrings.fieldFullName)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ZoTextField(controller: _company, label: context.tr(AppStrings.fieldCompany)),
                ),
              ],
            ),
            _gapS,
            Row(
              children: [
                Expanded(
                  child: ZoTextField(controller: _idEmail, label: context.tr(AppStrings.fieldEmail)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ZoTextField(controller: _phone, label: context.tr(AppStrings.fieldPhone)),
                ),
              ],
            ),
            _gapS,
            ZoTextField(
              controller: _idNumber,
              label: context.tr(AppStrings.fieldIdNumber),
              obscure: true,
              mono: true,
            ),
            _gapS,
            ZoTextField(controller: _address, label: context.tr(AppStrings.fieldAddress), maxLines: 2),
          ],
        ),
      ]);
    }

    if (_shows(TemplateSection.customFields)) {
      body.addAll([
        _gap,
        _EditGroup(
          title: context.tr(AppStrings.customFields),
          action: ZoButton(
            label: context.tr(AppStrings.addAction),
            icon: Icons.add_rounded,
            variant: ZoButtonVariant.ghost,
            dense: true,
            onPressed: () =>
                setState(() => _fields.add(_FieldDraft('', '', false))),
          ),
          children: [
            if (_fields.isEmpty)
              Text(
                context.tr(AppStrings.customFieldsExample),
                style: context.text.bodySmall?.copyWith(color: c.textFaint),
              ),
            for (var i = 0; i < _fields.length; i++) ...[
              if (i > 0) _gapS,
              Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: ZoTextField(
                      controller: _fields[i].label,
                      hint: context.tr(AppStrings.fieldName),
                      dense: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ZoTextField(
                      controller: _fields[i].value,
                      hint: context.tr(AppStrings.fieldValue),
                      dense: true,
                      obscure: _fields[i].sensitive,
                    ),
                  ),
                  ZoIconButton(
                    icon: _fields[i].sensitive
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    tooltip: context.tr(
                      _fields[i].sensitive ? AppStrings.sensitiveField : AppStrings.plainField,
                    ),
                    active: _fields[i].sensitive,
                    onPressed: () => setState(
                      () => _fields[i].sensitive = !_fields[i].sensitive,
                    ),
                  ),
                  ZoIconButton(
                    icon: Icons.remove_circle_outline_rounded,
                    tooltip: context.tr(AppStrings.removeAction),
                    onPressed: () => setState(() {
                      final f = _fields.removeAt(i);
                      f.label.dispose();
                      f.value.dispose();
                    }),
                  ),
                ],
              ),
            ],
          ],
        ),
      ]);
    }

    if (_shows(TemplateSection.notes)) {
      body.addAll([
        _gap,
        _EditGroup(
          title: context.tr(kind == ItemKind.note ? AppStrings.groupContent : AppStrings.fieldNotes),
          children: [
            ZoTextField(
              controller: _notes,
              maxLines: kind == ItemKind.note ? 16 : 5,
              minLines: kind == ItemKind.note ? 10 : 3,
              hint: context.tr(AppStrings.notesPlaceholder),
            ),
          ],
        ),
      ]);
    }

    // 标签与分类对所有类型都适用，放在末尾（模板不控制该分区）。
    body.addAll([
      _gap,
      _EditGroup(
        title: context.tr(AppStrings.groupTaxonomy),
        children: [
          _TagEditor(
            tags: _tags,
            controller: _tagInput,
            onCommit: _commitTag,
            onRemove: _removeTag,
          ),
          const SizedBox(height: 12),
          ZoTextField(
            key: const Key('category-input'),
            controller: _category,
            label: context.tr(AppStrings.sidebarCategories),
            hint: context.tr(AppStrings.categoryHint),
            prefixIcon: Icons.folder_outlined,
          ),
        ],
      ),
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
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.border)),
            ),
            child: Row(
              children: [
                Icon(kind.icon, size: 18, color: c.accent),
                const SizedBox(width: 10),
                Text(
                  context.trf(
                    isNew ? AppStrings.createItemTitle : AppStrings.editItemTitle,
                    {'kind': kind.title(context)},
                  ),
                  style: context.text.headlineSmall,
                ),
                const Spacer(),
                Text(
                  context.tr(AppStrings.editorShortcuts),
                  style: context.text.bodySmall?.copyWith(color: c.textFaint),
                ),
                const SizedBox(width: 16),
                ZoButton(
                  label: context.tr(AppStrings.cancel),
                  variant: ZoButtonVariant.ghost,
                  dense: true,
                  onPressed: widget.onCancel,
                ),
                const SizedBox(width: 8),
                ZoButton(
                  label: context.tr(AppStrings.save),
                  icon: Icons.check_rounded,
                  dense: true,
                  loading: _saving,
                  onPressed: _save,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: body,
                    ),
                  ),
                ),
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

class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({
    required this.templates,
    required this.selected,
    required this.onSelected,
    required this.onClear,
  });

  final List<ItemTemplate> templates;
  final ItemTemplate? selected;
  final ValueChanged<ItemTemplate> onSelected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return ZoPanel(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 32,
            child: SectionLabel(
              context.tr(AppStrings.templateSection),
              trailing: selected == null
                  ? null
                  : TextButton(
                      onPressed: onClear,
                      style: TextButton.styleFrom(
                        foregroundColor: c.textMuted,
                        textStyle: const TextStyle(fontSize: 12.5),
                      ),
                      child: Text(context.tr(AppStrings.templateAllFields)),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr(AppStrings.templateNote),
            style: context.text.bodySmall?.copyWith(color: c.textFaint),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final template in templates)
                Tooltip(
                  message: template.description(context),
                  child: ZoButton(
                    label: template.name(context),
                    icon: template.icon,
                    dense: true,
                    variant: selected?.id == template.id
                        ? ZoButtonVariant.secondary
                        : ZoButtonVariant.ghost,
                    onPressed: () => onSelected(template),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

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

/// 标签编辑器：已确认的标签逐个可删除，输入框回车或失焦即提交。
class _TagEditor extends StatelessWidget {
  const _TagEditor({
    required this.tags,
    required this.controller,
    required this.onCommit,
    required this.onRemove,
  });

  final List<String> tags;
  final TextEditingController controller;
  final VoidCallback onCommit;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final full = tags.length >= itemTagLimit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tags.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in tags)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ZoTag(tag, color: c.accent),
                    // 删除按钮紧贴标签，避免误点相邻标签。
                    ZoIconButton(
                      icon: Icons.close_rounded,
                      size: 18,
                      tooltip: context.trf(AppStrings.tagRemoveTooltip, {'tag': tag}),
                      onPressed: () => onRemove(tag),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        ZoTextField(
          key: const Key('tag-input'),
          controller: controller,
          label: context.tr(AppStrings.tagLabel),
          hint: full
              ? context.trf(AppStrings.tagLimitReached, {'count': itemTagLimit})
              : context.tr(AppStrings.tagInputHint),
          prefixIcon: Icons.local_offer_outlined,
          enabled: !full,
          trailing: [
            ZoIconButton(
              icon: Icons.add_rounded,
              size: 28,
              tooltip: context.tr(AppStrings.tagAdd),
              onPressed: full ? null : onCommit,
            ),
          ],
          onSubmitted: (_) => onCommit(),
        ),
      ],
    );
  }
}

class _MatchPicker extends StatelessWidget {  const _MatchPicker({required this.value, required this.onChanged});

  final UrlMatch value;
  final ValueChanged<UrlMatch> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return PopupMenuButton<UrlMatch>(
      tooltip: context.tr(AppStrings.urlMatchPickerLabel),
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in UrlMatch.values)
          PopupMenuItem(
            value: m,
            height: 36,
            child: Text(context.trf(AppStrings.urlMatchSuffix, {'label': m.title(context)}), style: context.text.bodyMedium),
          ),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(
              value.title(context),
              style: context.text.bodySmall?.copyWith(color: c.text),
            ),
            Icon(Icons.expand_more_rounded, size: 16, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}
