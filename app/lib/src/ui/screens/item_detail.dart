import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/models.dart';
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
      title: '移入回收站？',
      body: '「${item.data.title}」将移入回收站，可随时恢复。',
      confirm: '移入回收站',
      danger: true,
    );
    if (ok != true || !context.mounted) return;
    await AppScope.read(context).delete(item.id);
    onDeleted();
    if (context.mounted) showZoMessage(context, '已移入回收站');
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
        if (d.username != null) FieldRow(label: '用户名', value: d.username!, onCopy: () => copy(d.username!, '用户名', sensitive: false)),
        if (d.password != null)
          FieldRow(
            label: '密码',
            value: d.password!,
            secret: true,
            onCopy: () => copy(d.password!, '密码'),
            badge: _StrengthBadge(password: d.password!, inputs: [d.title, d.username ?? '']),
          ),
        if (d.totp != null)
          _TotpRow(config: d.totp!, onCopy: (code) => copy(code, '验证码')),
      ]));
    }

    if (d.urls.isNotEmpty) {
      sections.add(_Group(children: [
        for (final u in d.urls)
          FieldRow(
            label: '网站 · ${u.match.label}匹配',
            value: u.url,
            onCopy: () => copy(u.url, '网址', sensitive: false),
            extra: ZoIconButton(
              icon: Icons.open_in_new_rounded,
              tooltip: '在浏览器中打开',
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
        if (k.cardholder.isNotEmpty) FieldRow(label: '持卡人', value: k.cardholder, onCopy: () => copy(k.cardholder, '持卡人', sensitive: false)),
        if (k.number.isNotEmpty) FieldRow(label: '卡号', value: k.number, secret: true, mono: true, onCopy: () => copy(k.number.replaceAll(' ', ''), '卡号')),
        if (k.expiry.isNotEmpty) FieldRow(label: '有效期', value: k.expiry, mono: true, onCopy: () => copy(k.expiry, '有效期', sensitive: false)),
        if (k.cvv.isNotEmpty) FieldRow(label: '安全码', value: k.cvv, secret: true, mono: true, onCopy: () => copy(k.cvv, '安全码')),
        if (k.pin.isNotEmpty) FieldRow(label: 'PIN', value: k.pin, secret: true, mono: true, onCopy: () => copy(k.pin, 'PIN')),
      ]));
    }

    if (d.identity != null) {
      final id = d.identity!;
      final rows = [
        ('姓名', id.fullName, false),
        ('邮箱', id.email, false),
        ('电话', id.phone, false),
        ('证件号', id.idNumber, true),
        ('地址', id.address, false),
        ('公司', id.company, false),
      ].where((r) => r.$2.isNotEmpty);
      sections.add(_Group(children: [
        for (final r in rows) FieldRow(label: r.$1, value: r.$2, secret: r.$3, onCopy: () => copy(r.$2, r.$1, sensitive: r.$3)),
      ]));
    }

    if (d.customFields.isNotEmpty) {
      sections.add(_Group(children: [
        for (final f in d.customFields)
          FieldRow(label: f.label.isEmpty ? '自定义字段' : f.label, value: f.value, secret: f.sensitive, onCopy: () => copy(f.value, f.label, sensitive: f.sensitive)),
      ]));
    }

    if (d.notes != null) {
      sections.add(_Group(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('备注', style: context.text.labelMedium),
              const SizedBox(height: 8),
              SelectableText(d.notes!, style: context.text.bodyMedium?.copyWith(height: 1.65)),
            ],
          ),
        ),
      ]));
    }

    if (d.passwordHistory.isNotEmpty) {
      sections.add(_HistoryGroup(history: d.passwordHistory, onCopy: (p) => copy(p, '历史密码')));
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
                      ZoTag(d.kind.label, icon: d.kind.icon),
                      if (inTrash) ...[const SizedBox(width: 6), ZoTag('回收站', color: c.danger)],
                    ]),
                  ],
                ),
              ),
              if (inTrash)
                ZoButton(
                  label: '恢复',
                  icon: Icons.restore_rounded,
                  variant: ZoButtonVariant.secondary,
                  dense: true,
                  onPressed: () async {
                    await state.restore(item.id);
                    if (context.mounted) showZoMessage(context, '已恢复「${d.title}」');
                  },
                )
              else ...[
                ZoIconButton(
                  icon: d.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  tooltip: d.favorite ? '取消收藏' : '收藏',
                  active: d.favorite,
                  onPressed: () => state.toggleFavorite(item),
                ),
                const SizedBox(width: 4),
                ZoIconButton(icon: Icons.delete_outline_rounded, tooltip: '移入回收站', onPressed: () => _delete(context)),
                const SizedBox(width: 10),
                ZoButton(label: '编辑', icon: Icons.edit_outlined, dense: true, variant: ZoButtonVariant.secondary, onPressed: onEdit),
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
                  _Meta('创建', formatTime(d.createdAt)),
                  _Meta('修改', formatTime(d.updatedAt)),
                  _Meta('版本', 'r${item.revision}'),
                  _Meta('加密', 'AES-256-GCM'),
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
                      tooltip: _reveal ? '隐藏' : '显示',
                      size: 28,
                      onPressed: () => setState(() => _reveal = !_reveal),
                    ),
                  ZoIconButton(icon: Icons.copy_rounded, tooltip: '复制', size: 28, onPressed: widget.onCopy),
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
                  Text('一次性验证码', style: context.text.labelMedium),
                  const SizedBox(height: 4),
                  TotpView(config: config),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: hover ? 1 : 0,
              duration: Zo.fast,
              child: ZoIconButton(icon: Icons.copy_rounded, tooltip: '复制验证码', size: 28, onPressed: () => onCopy(VaultApi.totp(config).code)),
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
              Text('密码历史', style: context.text.titleMedium?.copyWith(fontSize: 13.5)),
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
                  ZoButton(label: '取消', variant: ZoButtonVariant.ghost, onPressed: () => Navigator.pop(context, false)),
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
