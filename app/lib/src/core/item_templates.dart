import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import 'models.dart';

/// 模板可控制显隐的编辑分区。`null` 模板表示展示当前类型的全部字段。
enum TemplateSection {
  loginCredentials,
  website,
  card,
  identity,
  customFields,
  notes,
}

/// 模板预置的自定义字段。
///
/// `label` 与 `hint` 是**条目内容**：应用模板后会写入保险库并参与同步，因此保持中文
/// 源文本，不随界面语言切换（与「条目内容不被翻译」的承诺一致）。界面层的模板**名称、
/// 说明、标题提示**才是可翻译文案，通过 `AppStrings` 常量按当前语言解析。
class TemplateField {
  const TemplateField(this.label, {this.sensitive = false, this.hint});

  final String label;
  final bool sensitive;
  final String? hint;
}

/// 条目模板：按条目类型提供预置字段集合，仅在新建时可选。
class ItemTemplate {
  const ItemTemplate({
    required this.id,
    required this.kind,
    required this.nameKey,
    required this.descriptionKey,
    required this.icon,
    required this.sections,
    this.titleHintKey,
    this.defaultTitle,
    this.fields = const [],
  });

  final String id;
  final ItemKind kind;

  /// 名称与说明的文案表常量；展示时经 `context.tr` 解析为当前语言。
  final String nameKey;
  final String descriptionKey;
  final IconData icon;
  final Set<TemplateSection> sections;

  /// 标题输入框的提示文案常量；与类型级默认提示同文案时复用同一常量。
  final String? titleHintKey;

  /// 模板预置的默认标题，属于条目内容，保持中文源文本。
  final String? defaultTitle;
  final List<TemplateField> fields;

  String name(BuildContext context) => context.tr(nameKey);

  String description(BuildContext context) => context.tr(descriptionKey);

  String? titleHint(BuildContext context) {
    final key = titleHintKey;
    return key == null ? null : context.tr(key);
  }

  bool shows(TemplateSection section) => sections.contains(section);
}

const _loginTemplates = <ItemTemplate>[
  ItemTemplate(
    id: 'login.website',
    kind: ItemKind.login,
    nameKey: AppStrings.tplLoginWebsite,
    descriptionKey: AppStrings.tplLoginWebsiteDesc,
    icon: Icons.language_rounded,
    sections: {
      TemplateSection.loginCredentials,
      TemplateSection.website,
      TemplateSection.notes,
    },
    titleHintKey: AppStrings.hintLoginTitle,
  ),
  ItemTemplate(
    id: 'login.api',
    kind: ItemKind.login,
    nameKey: AppStrings.tplLoginApi,
    descriptionKey: AppStrings.tplLoginApiDesc,
    icon: Icons.code_rounded,
    sections: {
      TemplateSection.loginCredentials,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHintKey: AppStrings.tplLoginApiHint,
    defaultTitle: 'API 凭据',
    fields: [
      TemplateField('API Key', sensitive: true),
      TemplateField('API Secret', sensitive: true),
      TemplateField('环境', hint: '例如：生产 / 测试'),
    ],
  ),
  ItemTemplate(
    id: 'login.device',
    kind: ItemKind.login,
    nameKey: AppStrings.tplLoginDevice,
    descriptionKey: AppStrings.tplLoginDeviceDesc,
    icon: Icons.dns_outlined,
    sections: {
      TemplateSection.loginCredentials,
      TemplateSection.website,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHintKey: AppStrings.tplLoginDeviceHint,
    fields: [
      TemplateField('主机'),
      TemplateField('端口'),
      TemplateField('协议'),
      TemplateField('设备名称'),
    ],
  ),
];

const _cardTemplates = <ItemTemplate>[
  ItemTemplate(
    id: 'card.bank',
    kind: ItemKind.card,
    nameKey: AppStrings.tplCardBank,
    descriptionKey: AppStrings.tplCardBankDesc,
    icon: Icons.credit_card_rounded,
    sections: {TemplateSection.card, TemplateSection.notes},
    titleHintKey: AppStrings.hintCardTitle,
  ),
  ItemTemplate(
    id: 'card.membership',
    kind: ItemKind.card,
    nameKey: AppStrings.tplCardMembership,
    descriptionKey: AppStrings.tplCardMembershipDesc,
    icon: Icons.card_membership_rounded,
    sections: {
      TemplateSection.card,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHintKey: AppStrings.tplCardMembershipHint,
    fields: [TemplateField('会员号'), TemplateField('等级'), TemplateField('积分')],
  ),
];

const _noteTemplates = <ItemTemplate>[
  ItemTemplate(
    id: 'note.secure',
    kind: ItemKind.note,
    nameKey: AppStrings.sectionNote,
    descriptionKey: AppStrings.tplNoteSecureDesc,
    icon: Icons.sticky_note_2_outlined,
    sections: {TemplateSection.notes},
    titleHintKey: AppStrings.hintNoteTitle,
  ),
  ItemTemplate(
    id: 'note.api',
    kind: ItemKind.note,
    nameKey: AppStrings.tplNoteApi,
    descriptionKey: AppStrings.tplNoteApiDesc,
    icon: Icons.vpn_key_outlined,
    sections: {TemplateSection.customFields, TemplateSection.notes},
    titleHintKey: AppStrings.tplNoteApiHint,
    fields: [
      TemplateField('主机'),
      TemplateField('端口'),
      TemplateField('用户名'),
      TemplateField('密钥', sensitive: true),
    ],
  ),
  ItemTemplate(
    id: 'note.wifi',
    kind: ItemKind.note,
    nameKey: AppStrings.tplNoteWifi,
    descriptionKey: AppStrings.tplNoteWifiDesc,
    icon: Icons.wifi_rounded,
    sections: {TemplateSection.customFields, TemplateSection.notes},
    titleHintKey: AppStrings.tplNoteWifiHint,
    fields: [
      TemplateField('网络名称'),
      TemplateField('密码', sensitive: true),
      TemplateField('安全类型'),
    ],
  ),
];

const _identityTemplates = <ItemTemplate>[
  ItemTemplate(
    id: 'identity.personal',
    kind: ItemKind.identity,
    nameKey: AppStrings.tplIdentityPersonal,
    descriptionKey: AppStrings.tplIdentityPersonalDesc,
    icon: Icons.badge_outlined,
    sections: {TemplateSection.identity, TemplateSection.notes},
    titleHintKey: AppStrings.hintIdentityTitle,
  ),
  ItemTemplate(
    id: 'identity.work',
    kind: ItemKind.identity,
    nameKey: AppStrings.tplIdentityWork,
    descriptionKey: AppStrings.tplIdentityWorkDesc,
    icon: Icons.business_center_outlined,
    sections: {
      TemplateSection.identity,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHintKey: AppStrings.tplIdentityWorkHint,
    fields: [TemplateField('职位'), TemplateField('工号')],
  ),
];

/// 返回某类条目的预置模板；顺序即创建页展示顺序。
List<ItemTemplate> itemTemplatesFor(ItemKind kind) => switch (kind) {
  ItemKind.login => _loginTemplates,
  ItemKind.card => _cardTemplates,
  ItemKind.note => _noteTemplates,
  ItemKind.identity => _identityTemplates,
};
