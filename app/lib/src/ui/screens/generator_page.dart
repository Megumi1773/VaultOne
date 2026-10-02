import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../state/clipboard.dart';
import '../../state/scope.dart';
import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/controls.dart';
import '../widgets/vault_widgets.dart';

enum _Mode { random, passphrase }

/// 密码生成器面板（页面与对话框共用）。
class GeneratorPanel extends StatefulWidget {
  const GeneratorPanel({super.key, this.onUse});

  /// 在编辑器中使用时提供；为 null 时只显示复制按钮。
  final ValueChanged<String>? onUse;

  @override
  State<GeneratorPanel> createState() => _GeneratorPanelState();
}

class _GeneratorPanelState extends State<GeneratorPanel> {
  _Mode _mode = _Mode.random;
  double _length = 20;
  bool _lower = true, _upper = true, _digits = true, _symbols = true, _noAmbiguous = true;
  double _words = 5;
  String _sep = '-';
  bool _cap = true, _num = true;
  Generated? _value;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _regen();
  }

  void _regen() {
    try {
      final v = _mode == _Mode.random
          ? VaultApi.generatePassword(
              length: _length.round(),
              lowercase: _lower,
              uppercase: _upper,
              digits: _digits,
              symbols: _symbols,
              excludeAmbiguous: _noAmbiguous,
            )
          : VaultApi.generatePassphrase(words: _words.round(), separator: _sep, capitalize: _cap, includeNumber: _num);
      setState(() {
        _value = v;
        _gen++;
      });
    } catch (_) {
      // 全部字符集都关闭时保持上一次结果
    }
  }

  void _toggle(void Function() f) {
    f();
    if (!(_lower || _upper || _digits || _symbols)) _lower = true;
    _regen();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    final v = _value;
    final bits = v?.entropy ?? 0;
    final strengthScore = bits >= 100 ? 4 : bits >= 70 ? 3 : bits >= 50 ? 2 : 1;
    final seconds = AppScope.of(context).settings.clipboardSeconds;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 结果
        Container(
          padding: const EdgeInsets.fromLTRB(22, 22, 14, 18),
          decoration: ShapeDecoration(
            color: c.surfaceRaised,
            shape: BeveledRectangleBorder(
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(14), bottomRight: Radius.circular(14)),
              side: BorderSide(color: c.borderStrong),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedSwitcher(
                    duration: Zo.fast,
                    child: v == null
                        ? const SizedBox.shrink()
                        : SelectionArea(
                            key: ValueKey(_gen),
                            child: PasswordText(v.value, size: v.value.length > 40 ? 17 : 22),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: StrengthMeter(strength: Strength(strengthScore, bits / 3.32, null), showLabel: false)),
                  const SizedBox(width: 14),
                  Text('${bits.toStringAsFixed(0)} bit', style: monoStyle(context, size: 12, color: c.textMuted)),
                  const SizedBox(width: 10),
                  ZoIconButton(
                    icon: Icons.refresh_rounded,
                    tooltip: context.tr(AppStrings.regenerate),
                    onPressed: _regen,
                  ),
                  ZoIconButton(
                    icon: Icons.copy_rounded,
                    tooltip: context.tr(AppStrings.copy),
                    onPressed: v == null
                        ? null
                        : () => ClipboardService.copy(
                            v.value,
                            label: context.tr(AppStrings.fieldPassword),
                            clearAfterSeconds: seconds,
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _Segmented(
          value: _mode,
          onChanged: (m) {
            _mode = m;
            _regen();
          },
        ),
        const SizedBox(height: 18),
        if (_mode == _Mode.random) ...[
          _SliderRow(label: context.tr(AppStrings.lengthLabel), value: _length, min: 8, max: 64, onChanged: (x) {
            _length = x;
            _regen();
          }),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _Chip('a-z', _lower, () => _toggle(() => _lower = !_lower)),
            _Chip('A-Z', _upper, () => _toggle(() => _upper = !_upper)),
            _Chip('0-9', _digits, () => _toggle(() => _digits = !_digits)),
            _Chip('!@#', _symbols, () => _toggle(() => _symbols = !_symbols)),
            _Chip(context.tr(AppStrings.excludeAmbiguous), _noAmbiguous, () => _toggle(() => _noAmbiguous = !_noAmbiguous)),
          ]),
        ] else ...[
          _SliderRow(label: context.tr(AppStrings.wordCountLabel), value: _words, min: 3, max: 8, onChanged: (x) {
            _words = x;
            _regen();
          }),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in ['-', '.', '_', ' '])
              _Chip(s == ' ' ? context.tr(AppStrings.separatorSpace) : s, _sep == s, () {
                _sep = s;
                _regen();
              }),
            _Chip(context.tr(AppStrings.capitalizeFirst), _cap, () {
              _cap = !_cap;
              _regen();
            }),
            _Chip(context.tr(AppStrings.includeDigits), _num, () {
              _num = !_num;
              _regen();
            }),
          ]),
        ],
        if (widget.onUse != null) ...[
          const SizedBox(height: 24),
          ZoButton(
            label: context.tr(AppStrings.useThisPassword),
            icon: Icons.check_rounded,
            expand: true,
            onPressed: v == null ? null : () => widget.onUse!(v.value),
          ),
        ],
      ],
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.value, required this.onChanged});

  final _Mode value;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    Widget seg(_Mode m, String label) => Expanded(
          child: Hover(
            onTap: () => onChanged(m),
            builder: (context, hover) => AnimatedContainer(
              duration: Zo.fast,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: value == m ? c.surfaceHover : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: value == m ? c.borderStrong : Colors.transparent),
              ),
              child: Text(label, style: context.text.labelLarge?.copyWith(color: value == m ? c.text : c.textMuted)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.border)),
      child: Row(
        children: [
          seg(_Mode.random, context.tr(AppStrings.randomPasswordTab)),
          seg(_Mode.passphrase, context.tr(AppStrings.passphraseTab)),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.label, required this.value, required this.min, required this.max, required this.onChanged});

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 44, child: Text(label, style: context.text.labelMedium)),
        Expanded(
          child: Slider(value: value, min: min, max: max, divisions: (max - min).round(), onChanged: (v) => onChanged(v.roundToDouble())),
        ),
        SizedBox(width: 30, child: Text('${value.round()}', textAlign: TextAlign.right, style: monoStyle(context, size: 14, weight: FontWeight.w600))),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.selected, this.onTap);

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Hover(
      onTap: onTap,
      builder: (context, hover) => AnimatedContainer(
        duration: Zo.fast,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.accentSoft : (hover ? c.surfaceHover : c.surface),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: selected ? c.accent.withValues(alpha: 0.6) : c.border),
        ),
        child: Text(label, style: context.text.labelLarge?.copyWith(fontSize: 12.5, color: selected ? c.text : c.textMuted)),
      ),
    );
  }
}

/// 独立页面
class GeneratorPage extends StatelessWidget {
  const GeneratorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(40, 36, 40, 48),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.tr(AppStrings.sectionGenerator), style: context.text.headlineMedium),
                const SizedBox(height: 6),
                Text(
                  context.tr(AppStrings.generatorSubtitle),
                  style: context.text.bodyMedium?.copyWith(color: context.zo.textMuted),
                ),
                const SizedBox(height: 28),
                const GeneratorPanel(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 编辑器中弹出的生成器
class GeneratorDialog extends StatelessWidget {
  const GeneratorDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Text(context.tr(AppStrings.generatePassword), style: context.text.headlineSmall),
                const Spacer(),
                ZoIconButton(
                  icon: Icons.close_rounded,
                  tooltip: context.tr(AppStrings.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ]),
              const SizedBox(height: 18),
              GeneratorPanel(onUse: (v) => Navigator.pop(context, v)),
            ],
          ),
        ),
      ),
    );
  }
}
