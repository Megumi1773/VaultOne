import 'package:flutter/material.dart';

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
    required this.name,
    required this.description,
    required this.icon,
    required this.sections,
    this.titleHint,
    this.defaultTitle,
    this.fields = const [],
  });

  final String id;
  final ItemKind kind;
  final String name;
  final String description;
  final IconData icon;
  final Set<TemplateSection> sections;
  final String? titleHint;
  final String? defaultTitle;
  final List<TemplateField> fields;

  bool shows(TemplateSection section) => sections.contains(section);
}

const _loginTemplates = <ItemTemplate>[
  ItemTemplate(
    id: 'login.website',
    kind: ItemKind.login,
    name: '网站账号',
    description: '用户名、密码、网址与两步验证',
    icon: Icons.language_rounded,
    sections: {
      TemplateSection.loginCredentials,
      TemplateSection.website,
      TemplateSection.notes,
    },
    titleHint: '例如：GitHub',
  ),
  ItemTemplate(
    id: 'login.api',
    kind: ItemKind.login,
    name: 'API / 开发者账号',
    description: '登录凭据与 API Key、Secret 等敏感字段',
    icon: Icons.code_rounded,
    sections: {
      TemplateSection.loginCredentials,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHint: '例如：OpenAI API',
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
    name: '服务器 / 设备',
    description: '主机、端口、账号与设备凭据',
    icon: Icons.dns_outlined,
    sections: {
      TemplateSection.loginCredentials,
      TemplateSection.website,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHint: '例如：生产服务器',
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
    name: '银行卡',
    description: '卡号、有效期、安全码与 PIN',
    icon: Icons.credit_card_rounded,
    sections: {TemplateSection.card, TemplateSection.notes},
    titleHint: '例如：招商银行信用卡',
  ),
  ItemTemplate(
    id: 'card.membership',
    kind: ItemKind.card,
    name: '会员 / 积分卡',
    description: '会员号、等级与积分信息',
    icon: Icons.card_membership_rounded,
    sections: {
      TemplateSection.card,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHint: '例如：航空公司会员卡',
    fields: [TemplateField('会员号'), TemplateField('等级'), TemplateField('积分')],
  ),
];

const _noteTemplates = <ItemTemplate>[
  ItemTemplate(
    id: 'note.secure',
    kind: ItemKind.note,
    name: '安全笔记',
    description: '自由文本，适合恢复码与配置说明',
    icon: Icons.sticky_note_2_outlined,
    sections: {TemplateSection.notes},
    titleHint: '例如：服务器备忘',
  ),
  ItemTemplate(
    id: 'note.api',
    kind: ItemKind.note,
    name: '服务器 / API 密钥',
    description: '主机、账号、密钥与备注',
    icon: Icons.vpn_key_outlined,
    sections: {TemplateSection.customFields, TemplateSection.notes},
    titleHint: '例如：生产 API 密钥',
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
    name: 'Wi-Fi 信息',
    description: '网络名称、密码与安全类型',
    icon: Icons.wifi_rounded,
    sections: {TemplateSection.customFields, TemplateSection.notes},
    titleHint: '例如：家里 Wi-Fi',
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
    name: '个人信息',
    description: '姓名、邮箱、电话、证件号与地址',
    icon: Icons.badge_outlined,
    sections: {TemplateSection.identity, TemplateSection.notes},
    titleHint: '例如：本人',
  ),
  ItemTemplate(
    id: 'identity.work',
    kind: ItemKind.identity,
    name: '公司 / 工作身份',
    description: '公司、职位、工号与联系方式',
    icon: Icons.business_center_outlined,
    sections: {
      TemplateSection.identity,
      TemplateSection.customFields,
      TemplateSection.notes,
    },
    titleHint: '例如：公司邮箱身份',
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
