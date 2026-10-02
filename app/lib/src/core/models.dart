import 'package:flutter/material.dart';

import '../l10n/strings.dart';

/// 导入结果。`format` 为内核识别出的来源（chrome / firefox / bitwarden / lastpass / 1password / 1pif / csv）。
typedef ImportSummary = ({String format, int added, int duplicates, int skipped});

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
  const CustomField({required this.label, required this.value, this.sensitive = false});

  final String label;
  final String value;
  final bool sensitive;

  factory CustomField.fromJson(Map<String, dynamic> j) =>
      CustomField(label: j['label'] as String? ?? '', value: j['value'] as String? ?? '', sensitive: j['sensitive'] == true);

  Map<String, Object?> toJson() => {'label': label, 'value': value, 'sensitive': sensitive};
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
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  ItemData copyWith({bool? favorite, String? password}) => ItemData(
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
