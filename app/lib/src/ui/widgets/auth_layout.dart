import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../theme.dart';
import 'brand.dart';

/// 注册 / 解锁 / 恢复页的双栏布局：左侧品牌叙事，右侧表单。窄屏时只保留表单。
class AuthLayout extends StatelessWidget {
  const AuthLayout({super.key, required this.child, this.sweep = 0});

  final Widget child;
  final double sweep;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 880;
      final form = Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: Zo.s8, vertical: Zo.s10),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: child),
        ),
      );
      return Stack(
        children: [
          Row(
            children: [
              if (wide)
                SizedBox(
                  width: box.maxWidth * 0.46,
                  child: Container(
                    decoration: BoxDecoration(color: c.surface, border: Border(right: BorderSide(color: c.border))),
                    child: const ZoBackdrop(child: _BrandStory()),
                  ),
                ),
              Expanded(child: form),
            ],
          ),
          Positioned.fill(child: RiseSweep(progress: sweep)),
        ],
      );
    });
  }
}

class _BrandStory extends StatelessWidget {
  const _BrandStory();

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Padding(
      padding: const EdgeInsets.fromLTRB(64, 72, 56, 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ZoWordmark(size: 20),
          const Spacer(),
          Text(context.tr(AppStrings.sidebarTagline), style: context.text.displayMedium?.copyWith(height: 1.25)),
          const SizedBox(height: 6),
          Text(
            context.tr(AppStrings.sidebarTaglineHighlight),
            style: context.text.displayMedium?.copyWith(color: c.accent, height: 1.25),
          ),
          const SizedBox(height: 28),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              context.tr(AppStrings.authAsideBody),
              style: context.text.bodyLarge?.copyWith(color: c.textMuted),
            ),
          ),
          const SizedBox(height: 40),
          _Principle(
            index: '00',
            title: context.tr(AppStrings.featureZeroKnowledge),
            body: context.tr(AppStrings.featureZeroKnowledgeBody),
          ),
          _Principle(
            index: '01',
            title: context.tr(AppStrings.featureTwoFactorDerivation),
            body: context.tr(AppStrings.featureTwoFactorDerivationBody),
          ),
          _Principle(
            index: '02',
            title: context.tr(AppStrings.featureItemEncryption),
            body: context.tr(AppStrings.featureItemEncryptionBody),
          ),
          const Spacer(),
          Text(context.tr(AppStrings.authAsideFooter), style: context.text.labelMedium?.copyWith(color: c.textFaint)),
        ],
      ),
    );
  }
}

class _Principle extends StatelessWidget {
  const _Principle({required this.index, required this.title, required this.body});

  final String index;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 34, child: Text(index, style: monoStyle(context, size: 12, color: c.accent, weight: FontWeight.w700))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleMedium),
                const SizedBox(height: 2),
                Text(body, style: context.text.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 表单页标题区
class AuthHeader extends StatelessWidget {
  const AuthHeader({super.key, required this.eyebrow, required this.title, this.subtitle});

  final String eyebrow;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.zo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 14, height: 2, color: c.accent),
          const SizedBox(width: 8),
          Text(eyebrow.toUpperCase(), style: context.text.labelSmall?.copyWith(color: c.accent)),
        ]),
        const SizedBox(height: 14),
        Text(title, style: context.text.headlineMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle!, style: context.text.bodyMedium?.copyWith(color: c.textMuted)),
        ],
        const SizedBox(height: 28),
      ],
    );
  }
}
