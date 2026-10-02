import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// 导入结果。`format` 为内核识别出的来源（chrome / firefox / bitwarden / lastpass / 1password / 1pif / csv）。
/// `updated` 是按「覆盖」策略改写掉的现有条目数——它改变了既有数据，必须单独展示。
typedef ImportSummary = ({String format, int added, int updated, int duplicates, int skipped});

/// 账户资料（§8.1）。`online` 为 false 表示本次没连上服务端，展示的是本机缓存。
typedef AccountProfile = ({String nickname, String avatar, int createdAt, bool online});

AccountProfile accountProfileFromJson(Map<String, dynamic> j) => (
      nickname: j['nickname'] as String? ?? '',
      avatar: j['avatar'] as String? ?? '',
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      online: j['online'] == true,
    );

/// 导入 / 导出历史的一条记录（计划书 §3.7）。本机记录、以 Vault Key 密封、不参与同步。
typedef TransferRecord = ({
  int at,
  TransferDirection direction,
  String format,
  String source,
  int added,
  int updated,
  int duplicates,
  int skipped,
  int bytes,
});

/// 一次传输的方向。wire 值与内核 `TransferDirection` 的 serde 名一致。
enum TransferDirection {
  import('import'),
  export('export');

  const TransferDirection(this.wire);

  final String wire;

  static TransferDirection parse(String? raw) => raw == 'export' ? TransferDirection.export : TransferDirection.import;
}

TransferRecord transferRecordFromJson(Map<String, dynamic> j) => (
      at: (j['at'] as num?)?.toInt() ?? 0,
      direction: TransferDirection.parse(j['direction'] as String?),
      format: j['format'] as String? ?? '',
      source: j['source'] as String? ?? '',
      added: (j['added'] as num?)?.toInt() ?? 0,
      updated: (j['updated'] as num?)?.toInt() ?? 0,
      duplicates: (j['duplicates'] as num?)?.toInt() ?? 0,
      skipped: (j['skipped'] as num?)?.toInt() ?? 0,
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
    );

/// 浏览器扩展配对请求。`code` 须与扩展弹窗中显示的配对码一致。
typedef PairingRequest = ({String clientId, String name, String code});

typedef BrowserClient = ({String id, String name, int createdAt, int lastUsedAt});

enum ItemKind {
  login('login', Icons.key_rounded),
  card('card', Icons.credit_card_rounded),
  note('note', Icons.sticky_note_2_outlined),
  identity('identity', Icons.badge_outlined);

  const ItemKind(this.wire, this.icon);

  final String wire;
  final IconData icon;

  /// 类型名的**唯一来源**是文案表；枚举只持引用，避免同一文案在枚举里再写一份而分叉。
  String title(BuildContext context) => context.tr(_labelKeys[this]!);

  static const _labelKeys = <ItemKind, String>{
    ItemKind.login: AppStrings.sectionLogin,
    ItemKind.card: AppStrings.sectionCard,
    ItemKind.note: AppStrings.sectionNote,
    ItemKind.identity: AppStrings.sectionIdentity,
  };

  static ItemKind parse(String? s) => ItemKind.values.firstWhere((k) => k.wire == s, orElse: () => ItemKind.login);
}

enum UrlMatch {
  domain('domain'),
  host('host'),
  exact('exact'),
  never('never');

  const UrlMatch(this.wire);

  final String wire;

  /// 匹配方式标签同样只来自文案表。
  String title(BuildContext context) => context.tr(_labelKeys[this]!);

  static const _labelKeys = <UrlMatch, String>{
    UrlMatch.domain: AppStrings.urlMatchDomain,
    UrlMatch.host: AppStrings.urlMatchHost,
    UrlMatch.exact: AppStrings.urlMatchExact,
    UrlMatch.never: AppStrings.urlMatchNever,
  };

  static UrlMatch parse(String? s) => UrlMatch.values.firstWhere((m) => m.wire == s, orElse: () => UrlMatch.domain);
}

String? _str(Object? v) => (v is String && v.isNotEmpty) ? v : null;

class ItemUrl {
  const ItemUrl({required this.url, this.match = UrlMatch.domain});

  final String url;
  final UrlMatch match;

  factory ItemUrl.fromJson(Map<String, dynamic> j) => ItemUrl(url: j['url'] as String? ?? '', match: UrlMatch.parse(j['match'] as String?));

  Map<String, Object?> toJson() => {'url': url, 'match': match.wire};

  String get host {
    final u = Uri.tryParse(url.contains('://') ? url : 'https://$url');
    return u?.host ?? url;
  }
}

class TotpConfig {
  const TotpConfig({required this.secret, this.alg = 'SHA1', this.digits = 6, this.period = 30});

  final String secret;
  final String alg;
  final int digits;
  final int period;

  factory TotpConfig.fromJson(Map<String, dynamic> j) => TotpConfig(
        secret: j['secret'] as String? ?? '',
        alg: j['alg'] as String? ?? 'SHA1',
        digits: (j['digits'] as num?)?.toInt() ?? 6,
        period: (j['period'] as num?)?.toInt() ?? 30,
      );

  Map<String, Object?> toJson() => {'secret': secret, 'alg': alg, 'digits': digits, 'period': period};
}

class CustomField {
  const CustomField({required this.label, required this.value, this.sensitive = false, this.kind = FieldKind.text});

  final String label;
  final String value;
  final bool sensitive;

  /// 渲染与校验类型（计划书 §3.1）。与 [sensitive] 正交：`sensitive` 决定默认隐藏与按敏感
  /// 方式复制，`kind` 只决定怎么显示与校验。规则由内核唯一确定（`crates/vault-core/src/item.rs`）。
  final FieldKind kind;

  factory CustomField.fromJson(Map<String, dynamic> j) => CustomField(
        label: j['label'] as String? ?? '',
        value: j['value'] as String? ?? '',
        sensitive: j['sensitive'] == true,
        kind: FieldKind.parse(j['kind'] as String?),
      );

  Map<String, Object?> toJson() => {'label': label, 'value': value, 'sensitive': sensitive, 'kind': kind.wire};
}

/// 动态字段的渲染与校验类型。wire 值与内核 `FieldKind` 的 serde 名一致。
enum FieldKind {
  text('text'),
  date('date'),
  image('image');

  const FieldKind(this.wire);

  final String wire;

  /// 未知或缺失一律按文本处理（旧库没有 `kind` 键）。
  static FieldKind parse(String? raw) => switch (raw) {
        'date' => FieldKind.date,
        'image' => FieldKind.image,
        _ => FieldKind.text,
      };
}

class PasswordHistoryEntry {
  const PasswordHistoryEntry(this.password, this.time);

  final String password;
  final int time;

  factory PasswordHistoryEntry.fromJson(Map<String, dynamic> j) => PasswordHistoryEntry(j['p'] as String? ?? '', (j['t'] as num?)?.toInt() ?? 0);

  Map<String, Object?> toJson() => {'p': password, 't': time};
}

class CardData {
  const CardData({this.cardholder = '', this.number = '', this.expiry = '', this.cvv = '', this.pin = ''});

  final String cardholder;
  final String number;
  final String expiry;
  final String cvv;
  final String pin;

  factory CardData.fromJson(Map<String, dynamic> j) => CardData(
        cardholder: j['cardholder'] as String? ?? '',
        number: j['number'] as String? ?? '',
        expiry: j['expiry'] as String? ?? '',
        cvv: j['cvv'] as String? ?? '',
        pin: j['pin'] as String? ?? '',
      );

  Map<String, Object?> toJson() => {'cardholder': cardholder, 'number': number, 'expiry': expiry, 'cvv': cvv, 'pin': pin};

  String get brand {
    final n = number.replaceAll(RegExp(r'\D'), '');
    if (n.startsWith('4')) return 'VISA';
    if (RegExp(r'^(5[1-5]|2[2-7])').hasMatch(n)) return 'Mastercard';
    if (RegExp(r'^3[47]').hasMatch(n)) return 'AMEX';
    if (n.startsWith('62')) return 'UnionPay';
    if (RegExp(r'^35').hasMatch(n)) return 'JCB';
    return '';
  }

  String get last4 {
    final n = number.replaceAll(RegExp(r'\D'), '');
    return n.length >= 4 ? n.substring(n.length - 4) : n;
  }
}

class IdentityData {
  const IdentityData({this.fullName = '', this.email = '', this.phone = '', this.idNumber = '', this.address = '', this.company = ''});

  final String fullName;
  final String email;
  final String phone;
  final String idNumber;
  final String address;
  final String company;

  factory IdentityData.fromJson(Map<String, dynamic> j) => IdentityData(
        fullName: j['fullName'] as String? ?? '',
        email: j['email'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        idNumber: j['idNumber'] as String? ?? '',
        address: j['address'] as String? ?? '',
        company: j['company'] as String? ?? '',
      );

  Map<String, Object?> toJson() =>
      {'fullName': fullName, 'email': email, 'phone': phone, 'idNumber': idNumber, 'address': address, 'company': company};
}

/// 单条目标签数量上限，与内核 `item::TAG_LIMIT` 保持一致；
/// UI 据此禁用输入，避免用户填完才在后端被拒。
const int itemTagLimit = 20;

/// 分类树节点（对应内核 `item::CategoryNode`）。
///
/// 分类是层级路径，树从条目派生而非独立存储，因此树里不会有空分类。
/// `total` 含后代汇总，与计划书 §3.11 的「分组条目数含后代汇总」一致。
class CategoryNode {
  const CategoryNode({
    required this.name,
    required this.path,
    required this.direct,
    required this.total,
    this.children = const [],
  });

  factory CategoryNode.fromJson(Map<String, dynamic> j) => CategoryNode(
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? '',
        direct: (j['direct'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        children: [
          for (final c in (j['children'] as List? ?? const []))
            CategoryNode.fromJson((c as Map).cast()),
        ],
      );

  /// 段名（不含父路径）。
  final String name;

  /// 完整路径，作为筛选与重命名的标识。
  final String path;

  /// 直属该分类的条目数（不含后代）。
  final int direct;

  /// 含后代汇总的条目数。
  final int total;

  final List<CategoryNode> children;

  /// 按深度优先展开成「节点 + 缩进层级」列表，供侧栏渲染。
  List<({CategoryNode node, int depth})> flatten({int depth = 0}) => [
        (node: this, depth: depth),
        for (final child in children) ...child.flatten(depth: depth + 1),
      ];
}

/// 条目明文（对应内核 `ItemData`）。
class ItemData {
  const ItemData({
    required this.kind,
    required this.title,
    this.urls = const [],
    this.username,
    this.password,
    this.totp,
    this.notes,
    this.card,
    this.identity,
    this.customFields = const [],
    this.passwordHistory = const [],
    this.favorite = false,
    this.tags = const [],
    this.category,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final ItemKind kind;
  final String title;
  final List<ItemUrl> urls;
  final String? username;
  final String? password;
  final TotpConfig? totp;
  final String? notes;
  final CardData? card;
  final IdentityData? identity;
  final List<CustomField> customFields;
  final List<PasswordHistoryEntry> passwordHistory;
  final bool favorite;

  /// 多标签（计划书 §3.6）。内核写入前已做去空白 / 大小写去重 / 限量规范化。
  final List<String> tags;

  /// 单选分类，null 表示未分类。
  final String? category;
  final int createdAt;
  final int updatedAt;

  factory ItemData.fromJson(Map<String, dynamic> j) => ItemData(
        kind: ItemKind.parse(j['type'] as String?),
        title: j['title'] as String? ?? '',
        urls: [for (final u in (j['urls'] as List? ?? const [])) ItemUrl.fromJson((u as Map).cast())],
        username: _str(j['username']),
        password: _str(j['password']),
        totp: j['totp'] is Map ? TotpConfig.fromJson((j['totp'] as Map).cast()) : null,
        notes: _str(j['notes']),
        card: j['card'] is Map ? CardData.fromJson((j['card'] as Map).cast()) : null,
        identity: j['identity'] is Map ? IdentityData.fromJson((j['identity'] as Map).cast()) : null,
        customFields: [for (final f in (j['customFields'] as List? ?? const [])) CustomField.fromJson((f as Map).cast())],
        passwordHistory: [for (final h in (j['passwordHistory'] as List? ?? const [])) PasswordHistoryEntry.fromJson((h as Map).cast())],
        favorite: j['favorite'] == true,
        tags: [for (final t in (j['tags'] as List? ?? const [])) t as String],
        category: _str(j['category']),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
      );

  Map<String, Object?> toJson() => {
        'type': kind.wire,
        'title': title,
        'urls': [for (final u in urls) u.toJson()],
        if (username != null) 'username': username,
        if (password != null) 'password': password,
        if (totp != null) 'totp': totp!.toJson(),
        if (notes != null) 'notes': notes,
        if (card != null) 'card': card!.toJson(),
        if (identity != null) 'identity': identity!.toJson(),
        'customFields': [for (final f in customFields) f.toJson()],
        'passwordHistory': [for (final h in passwordHistory) h.toJson()],
        'favorite': favorite,
        'tags': tags,
        if (category != null) 'category': category,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  ItemData copyWith({bool? favorite, String? password, List<String>? tags, String? category, bool clearCategory = false}) => ItemData(
        kind: kind,
        title: title,
        urls: urls,
        username: username,
        password: password ?? this.password,
        totp: totp,
        notes: notes,
        card: card,
        identity: identity,
        customFields: customFields,
        passwordHistory: passwordHistory,
        favorite: favorite ?? this.favorite,
        tags: tags ?? this.tags,
        category: clearCategory ? null : (category ?? this.category),
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  /// 列表副标题
  String get subtitle {
    switch (kind) {
      case ItemKind.login:
        return username ?? (urls.isNotEmpty ? urls.first.host : '');
      case ItemKind.card:
        final c = card;
        if (c == null) return '';
        return [if (c.brand.isNotEmpty) c.brand, if (c.last4.isNotEmpty) '•••• ${c.last4}'].join('  ');
      case ItemKind.note:
        final n = notes ?? '';
        return n.split('\n').first;
      case ItemKind.identity:
        return identity?.fullName ?? '';
    }
  }

  /// 本地搜索用的文本（仅在内存中拼接）
  String get searchText => [
        title,
        username ?? '',
        for (final u in urls) u.url,
        if (kind == ItemKind.note) notes ?? '',
        identity?.fullName ?? '',
        identity?.company ?? '',
        card?.cardholder ?? '',
        category ?? '',
        ...tags,
        for (final f in customFields)
          if (!f.sensitive) '${f.label} ${f.value}',
      ].join(' ').toLowerCase();
}

class VaultItem {
  const VaultItem({required this.id, required this.vaultId, required this.revision, required this.data});

  final String id;
  final String vaultId;
  final int revision;
  final ItemData data;

  factory VaultItem.fromJson(Map<String, dynamic> j) => VaultItem(
        id: j['id'] as String,
        vaultId: j['vaultId'] as String,
        revision: (j['revision'] as num).toInt(),
        data: ItemData.fromJson((j['data'] as Map).cast()),
      );
}

class Enrollment {
  const Enrollment({required this.accountId, required this.email, required this.secretKey, required this.recoveryCode});

  final String accountId;
  final String email;
  final String secretKey;
  final String recoveryCode;

  factory Enrollment.fromJson(Map<String, dynamic> j) => Enrollment(
        accountId: j['accountId'] as String,
        email: j['email'] as String,
        secretKey: j['secretKey'] as String,
        recoveryCode: j['recoveryCode'] as String,
      );
}

class AccountInfo {
  const AccountInfo({
    required this.accountId,
    required this.email,
    required this.kdfSummary,
    required this.pendingChanges,
    required this.itemCount,
  });

  final String accountId;
  final String email;
  final String kdfSummary;
  final int pendingChanges;
  final int itemCount;
}

class TotpCode {
  const TotpCode(this.code, this.remaining, this.period);

  final String code;
  final int remaining;
  final int period;
}

class Strength {
  const Strength(this.score, this.guessesLog10, this.warning);

  final int score;
  final double guessesLog10;
  final String? warning;

  static const empty = Strength(0, 0, null);

  /// 强度标签的**唯一来源**是文案表；此处只持常量引用，避免同一文案再写一份。
  static const _labelKeys = [
    AppStrings.strengthVeryWeak,
    AppStrings.strengthWeak,
    AppStrings.strengthFair,
    AppStrings.strengthStrong,
    AppStrings.strengthVeryStrong,
  ];

  String label(BuildContext context) => context.tr(_labelKeys[score.clamp(0, 4)]);
}

class AuditFinding {
  const AuditFinding({required this.itemId, required this.weak, required this.score, required this.reusedWith});

  final String itemId;
  final bool weak;
  final int score;
  final int reusedWith;

}

class Generated {
  const Generated(this.value, this.entropy);

  final String value;
  final double entropy;
}
