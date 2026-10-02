import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/ffi.dart';
import '../../core/models.dart';
import '../../l10n/strings.dart';
import '../../state/clipboard.dart';
import '../../state/scope.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';

String formatTime(int epochSeconds) {
  if (epochSeconds <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class ItemDetail extends StatelessWidget {
  const ItemDetail({super.key, required this.item, required this.onEdit, required this.onDeleted, this.inTrash = false});

  final VaultItem item;
  final VoidCallback onEdit;
  final VoidCallback onDeleted;
  final bool inTrash;

  Future<void> _delete(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.moveToTrashConfirmTitle),
      body: context.trf(AppStrings.moveToTrashConfirmBody, {'title': item.data.title}),
      confirm: context.tr(AppStrings.moveToTrash),
      danger: true,
    );
    if (ok != true || !context.mounted) return;
    await AppScope.read(context).delete(item.id);
    onDeleted();
    if (context.mounted) showZoMessage(context, context.tr(AppStrings.movedToTrashTitle));
  }

  Future<void> _purge(BuildContext context) async {
    final ok = await confirmDialog(
      context,
      title: context.tr(AppStrings.purgeConfirmTitle),
      body: context.trf(AppStrings.purgeConfirmBody, {'title': item.data.title}),
      confirm: context.tr(AppStrings.purgeAction),
      danger: true,
    );
    if (ok != true || !context.mounted) return;
    try {
      await AppScope.read(context).purge(item.id);
      onDeleted();
      if (context.mounted) showZoMessage(context, context.trf(AppStrings.purgedTitle, {'title': item.data.title}));
    } on CoreException catch (e) {
      if (context.mounted) showZoMessage(context, purgeErrorMessage(context, e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final d = item.data;
    final state = AppScope.read(context);
    final seconds = AppScope.of(context).settings.clipboardSeconds;

    void copy(String value, String label, {bool sensitive = true}) =>
        ClipboardService.copy(value, label: label, sensitive: sensitive, clearAfterSeconds: seconds);

    final sections = <Widget>[];

    // 登录信息
    if (d.username != null || d.password != null || d.totp != null) {
      sections.add(_Group(children: [
        if (d.username != null) FieldRow(label: context.tr(AppStrings.fieldUsername), value: d.username!, onCopy: () => copy(d.username!, context.tr(AppStrings.fieldUsername), sensitive: false)),
        if (d.password != null)
          FieldRow(
            label: context.tr(AppStrings.fieldPassword),
            value: d.password!,
            secret: true,
            onCopy: () => copy(d.password!, context.tr(AppStrings.fieldPassword)),
            badge: _StrengthBadge(password: d.password!, inputs: [d.title, d.username ?? '']),
          ),
        if (d.totp != null)
          _TotpRow(config: d.totp!, onCopy: (code) => copy(code, context.tr(AppStrings.fieldTotp))),
      ]));
    }

    if (d.urls.isNotEmpty) {
      sections.add(_Group(children: [
        for (final u in d.urls)
          FieldRow(
            label: context.trf(AppStrings.urlFieldLabel, {'label': u.match.title(context)}),
            value: u.url,
            onCopy: () => copy(u.url, context.tr(AppStrings.fieldWebsite), sensitive: false),
            extra: ZoIconButton(
              icon: Icons.open_in_new_rounded,
              tooltip: context.tr(AppStrings.openInBrowser),
              size: 28,
              onPressed: () {
                final uri = Uri.tryParse(u.url.contains('://') ? u.url : 'https://${u.url}');
                if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) launchUrl(uri);
              },
            ),
          ),
      ]));
    }

    if (d.card != null) {
      final k = d.card!;
      sections.add(_CardVisual(card: k));
      sections.add(_Group(children: [
        if (k.cardholder.isNotEmpty) FieldRow(label: context.tr(AppStrings.fieldCardholder), value: k.cardholder, onCopy: () => copy(k.cardholder, context.tr(AppStrings.fieldCardholder), sensitive: false)),
        if (k.number.isNotEmpty) FieldRow(label: context.tr(AppStrings.fieldCardNumber), value: k.number, secret: true, mono: true, onCopy: () => copy(k.number.replaceAll(' ', ''), context.tr(AppStrings.fieldCardNumber))),
        if (k.expiry.isNotEmpty) FieldRow(label: context.tr(AppStrings.fieldExpiry), value: k.expiry, mono: true, onCopy: () => copy(k.expiry, context.tr(AppStrings.fieldExpiry), sensitive: false)),
        if (k.cvv.isNotEmpty) FieldRow(label: context.tr(AppStrings.fieldCvv), value: k.cvv, secret: true, mono: true, onCopy: () => copy(k.cvv, context.tr(AppStrings.fieldCvv))),
        if (k.pin.isNotEmpty) FieldRow(label: AppStrings.fieldPin, value: k.pin, secret: true, mono: true, onCopy: () => copy(k.pin, AppStrings.fieldPin)),
      ]));
    }

    if (d.identity != null) {
      final id = d.identity!;
      final rows = [
        (AppStrings.fieldFullName, id.fullName, false),
        (AppStrings.fieldEmail, id.email, false),
        (AppStrings.fieldPhone, id.phone, false),
        (AppStrings.fieldIdNumber, id.idNumber, true),
        (AppStrings.fieldAddress, id.address, false),
        (AppStrings.fieldCompany, id.company, false),
      ].where((r) => r.$2.isNotEmpty);
      sections.add(_Group(children: [
        for (final r in rows)
          FieldRow(
            label: context.tr(r.$1),
            value: r.$2,
            secret: r.$3,
            onCopy: () => copy(r.$2, context.tr(r.$1), sensitive: r.$3),
          ),
      ]));
    }

    if (d.customFields.isNotEmpty) {
      sections.add(_Group(children: [
        for (final f in d.customFields)
          FieldRow(
            label: f.label.isEmpty ? context.tr(AppStrings.customFields) : f.label,
            value: f.value,
            secret: f.sensitive,
            onCopy: () => copy(f.value, f.label, sensitive: f.sensitive),
          ),
      ]));
    }

    if (d.notes != null) {
      sections.add(_Group(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(context.tr(AppStrings.fieldNotes), style: context.text.labelMedium),
              const SizedBox(height: 8),
              SelectableText(d.notes!, style: context.text.bodyMedium?.copyWith(height: 1.65)),
            ],
          ),
        ),
      ]));
    }

    if (d.passwordHistory.isNotEmpty) {
      sections.add(_HistoryGroup(history: d.passwordHistory, onCopy: (p) => copy(p, context.tr(AppStrings.historyPassword))));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头部
        Container(
          padding: const EdgeInsets.fromLTRB(32, 26, 24, 22),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.border))),
          child: Row(
            children: [
              Monogram(title: d.title, size: 52, icon: d.kind == ItemKind.login ? null : d.kind.icon),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.title, style: context.text.headlineMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 6),
                    Row(children: [
                      ZoTag(d.kind.title(context), icon: d.kind.icon),
                      if (inTrash) ...[const SizedBox(width: 6), ZoTag(context.tr(AppStrings.sectionTrash), color: c.danger)],
                    ]),
                  ],
                ),
              ),
              if (inTrash) ...[
                ZoButton(
                  label: context.tr(AppStrings.restoreAction),
                  icon: Icons.restore_rounded,
                  variant: ZoButtonVariant.secondary,
                  dense: true,
                  onPressed: () async {
                    await state.restore(item.id);
                    if (context.mounted) showZoMessage(context, context.trf(AppStrings.restoredTitle, {'title': d.title}));
                  },
                ),
                const SizedBox(width: 8),
                ZoButton(
                  label: context.tr(AppStrings.purgeAction),
                  icon: Icons.delete_forever_rounded,
                  variant: ZoButtonVariant.danger,
                  dense: true,
                  onPressed: () => _purge(context),
                ),
              ] else ...[
                ZoIconButton(
                  icon: d.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  tooltip: d.favorite ? context.tr(AppStrings.unfavorite) : context.tr(AppStrings.sectionFavorites),
                  active: d.favorite,
                  onPressed: () => state.toggleFavorite(item),
                ),
                const SizedBox(width: 4),
                ZoIconButton(icon: Icons.delete_outline_rounded, tooltip: context.tr(AppStrings.moveToTrash), onPressed: () => _delete(context)),
                const SizedBox(width: 10),
                ZoButton(label: context.tr(AppStrings.editAction), icon: Icons.edit_outlined, dense: true, variant: ZoButtonVariant.secondary, onPressed: onEdit),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
            children: [
              for (final s in sections) ...[s, const SizedBox(height: 16)],
              const SizedBox(height: 8),
              Wrap(
                spacing: 24,
                runSpacing: 6,
                children: [
                  _Meta(context.tr(AppStrings.labelCreated), formatTime(d.createdAt)),
                  _Meta(context.tr(AppStrings.labelUpdated), formatTime(d.updatedAt)),
                  _Meta(context.tr(AppStrings.labelRevision), 'r${item.revision}'),
                  _Meta(context.tr(AppStrings.labelEncrypted), 'AES-256-GCM'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        TextSpan(text: '$label  ', style: context.text.bodySmall?.copyWith(color: context.zo.textFaint)),
        TextSpan(text: value, style: monoStyle(context, size: 11.5, color: context.zo.textMuted)),
      ]));
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Zo.radiusLg),
        border: Border.all(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: c.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 字段行：悬停时出现复制 / 显示按钮；点击整行即复制。
class FieldRow extends StatefulWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.value,
    required this.onCopy,
    this.secret = false,
    this.mono = false,
    this.badge,
    this.extra,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool secret;
  final bool mono;
  final Widget? badge;
  final Widget? extra;

  @override
  State<FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<FieldRow> {
  bool _reveal = false;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Hover(
      onTap: widget.onCopy,
      builder: (context, hover) => AnimatedContainer(
        duration: Zo.fast,
        color: hover ? c.surfaceHover.withValues(alpha: 0.5) : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 11, 10, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(widget.label, style: context.text.labelMedium),
                    if (widget.badge != null) ...[const SizedBox(width: 8), widget.badge!],
                  ]),
                  const SizedBox(height: 4),
                  if (widget.secret && !_reveal)
                    Text('•' * widget.value.length.clamp(8, 16), style: monoStyle(context, size: 15, color: c.textMuted, spacing: 1.5))
                  else if (widget.secret)
                    PasswordText(widget.value, size: 15)
                  else
                    Text(
                      widget.value,
                      style: widget.mono ? monoStyle(context, size: 14.5) : context.text.bodyLarge?.copyWith(fontSize: 14.5),
                    ),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: hover ? 1 : 0,
              duration: Zo.fast,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.extra != null) widget.extra!,
                  if (widget.secret)
                    ZoIconButton(
                      icon: _reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      tooltip: _reveal ? context.tr(AppStrings.labelHide) : context.tr(AppStrings.labelReveal),
                      size: 28,
                      onPressed: () => setState(() => _reveal = !_reveal),
                    ),
                  ZoIconButton(icon: Icons.copy_rounded, tooltip: context.tr(AppStrings.copy), size: 28, onPressed: widget.onCopy),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StrengthBadge extends StatelessWidget {
  const _StrengthBadge({required this.password, required this.inputs});

  final String password;
  final List<String> inputs;

  @override
  Widget build(BuildContext context) {
    final s = VaultApi.strength(password, inputs: inputs);
    return ZoTag(s.label, color: StrengthMeter.colorFor(context, s.score));
  }
}

class _TotpRow extends StatelessWidget {
  const _TotpRow({required this.config, required this.onCopy});

  final TotpConfig config;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) {
    return Hover(
      onTap: () => onCopy(VaultApi.totp(config).code),
      builder: (context, hover) => AnimatedContainer(
        duration: Zo.fast,
        color: hover ? context.zo.surfaceHover.withValues(alpha: 0.5) : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(16, 11, 10, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.tr(AppStrings.totpOnce), style: context.text.labelMedium),
                  const SizedBox(height: 4),
                  TotpView(config: config),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: hover ? 1 : 0,
              duration: Zo.fast,
              child: ZoIconButton(icon: Icons.copy_rounded, tooltip: context.tr(AppStrings.copyTotp), size: 28, onPressed: () => onCopy(VaultApi.totp(config).code)),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryGroup extends StatefulWidget {
  const _HistoryGroup({required this.history, required this.onCopy});

  final List<PasswordHistoryEntry> history;
  final ValueChanged<String> onCopy;

  @override
  State<_HistoryGroup> createState() => _HistoryGroupState();
}

class _HistoryGroupState extends State<_HistoryGroup> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return _Group(children: [
      Hover(
        onTap: () => setState(() => _open = !_open),
        builder: (context, hover) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Icon(Icons.history_rounded, size: 16, color: c.textMuted),
              const SizedBox(width: 10),
              Text(context.tr(AppStrings.passwordHistory), style: context.text.titleMedium?.copyWith(fontSize: 13.5)),
              const SizedBox(width: 8),
              Text('${widget.history.length}', style: monoStyle(context, size: 11, color: c.textFaint)),
              const Spacer(),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: Zo.fast,
                child: Icon(Icons.expand_more_rounded, size: 18, color: c.textMuted),
              ),
            ],
          ),
        ),
      ),
      if (_open)
        for (final h in widget.history)
          FieldRow(label: formatTime(h.time), value: h.password, secret: true, onCopy: () => widget.onCopy(h.password)),
    ]);
  }
}

/// 支付卡视觉：切角卡面 + 卡组织 + 尾号。
class _CardVisual extends StatelessWidget {
  const _CardVisual({required this.card});

  final CardData card;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 340,
        height: 200,
        padding: const EdgeInsets.all(22),
        decoration: ShapeDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.surfaceRaised, Color.lerp(c.surfaceRaised, c.accent, 0.08)!],
          ),
          shape: BeveledRectangleBorder(
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(18), bottomRight: Radius.circular(18)),
            side: BorderSide(color: c.borderStrong),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 38,
                height: 28,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [c.accent, Color.lerp(c.accent, c.warning, 0.6)!]),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              const Spacer(),
              Text(card.brand, style: context.text.titleMedium?.copyWith(letterSpacing: 1.5, fontStyle: FontStyle.italic)),
            ]),
            const Spacer(),
            Text('••••  ••••  ••••  ${card.last4}', style: monoStyle(context, size: 19, spacing: 2, weight: FontWeight.w600)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: Text(card.cardholder.toUpperCase(), style: context.text.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(card.expiry, style: monoStyle(context, size: 12.5, color: c.textMuted)),
            ]),
          ],
        ),
      ),
    );
  }
}

/// 彻底删除 / 清空回收站失败时按稳定错误码给出安全提示，不展示原始 message。
String purgeErrorMessage(BuildContext context, CoreException e) => switch (e.code) {
      'item_unsynced' => context.tr(AppStrings.purgeErrorUnsynced),
      'not_found' => context.tr(AppStrings.purgeErrorNotFound),
      'locked' || 'session_expired' => context.tr(AppStrings.purgeErrorLocked),
      _ => context.tr(AppStrings.purgeErrorGeneric),
    };

/// 通用确认对话框。
Future<bool?> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
  bool danger = false,
}) {
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.headlineSmall),
              const SizedBox(height: 10),
              Text(body, style: context.text.bodyMedium?.copyWith(color: context.zo.textMuted)),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ZoButton(label: context.tr(AppStrings.cancel), variant: ZoButtonVariant.ghost, onPressed: () => Navigator.pop(context, false)),
                  const SizedBox(width: 8),
                  ZoButton(
                    label: confirm,
                    variant: danger ? ZoButtonVariant.danger : ZoButtonVariant.primary,
                    onPressed: () => Navigator.pop(context, true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
