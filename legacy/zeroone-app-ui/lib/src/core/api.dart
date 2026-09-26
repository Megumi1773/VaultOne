import 'ffi.dart';
import 'models.dart';

/// 内核命令的强类型封装。
abstract final class VaultApi {
  static Map<String, dynamic> _map(Object? v) => (v as Map).cast<String, dynamic>();

  static Future<void> open(String path) => Core.call('open', {'path': path});

  static Future<({bool initialized, bool unlocked})> status() async {
    final s = _map(await Core.call('status'));
    return (initialized: s['initialized'] == true, unlocked: s['unlocked'] == true);
  }

  static Future<Enrollment> createAccount(String email, String password) async =>
      Enrollment.fromJson(_map(await Core.call('create_account', {'email': email, 'password': password})));

  static Future<void> unlock(String password, String secretKey) =>
      Core.call('unlock', {'password': password, 'secretKey': secretKey});

  static Future<void> lock() => Core.call('lock');

  static Future<String> accountId() async => await Core.call('account_id') as String;

  static Future<AccountInfo> account() async => AccountInfo.fromJson(_map(await Core.call('account')));

  static Future<void> changePassword(String current, String secretKey, String newPassword) =>
      Core.call('change_password', {'current': current, 'secretKey': secretKey, 'newPassword': newPassword});

  static Future<Enrollment> recover(String recoveryCode, String secretKey, String newPassword) async => Enrollment.fromJson(
      _map(await Core.call('recover', {'recoveryCode': recoveryCode, 'secretKey': secretKey, 'newPassword': newPassword})));

  static Future<List<VaultItem>> listItems() async =>
      [for (final i in (await Core.call('list_items')) as List) VaultItem.fromJson(_map(i))];

  static Future<List<VaultItem>> listTrash() async =>
      [for (final i in (await Core.call('list_trash')) as List) VaultItem.fromJson(_map(i))];

  static Future<VaultItem> createItem(ItemData data) async =>
      VaultItem.fromJson(_map(await Core.call('create_item', {'data': data.toJson()})));

  static Future<VaultItem> updateItem(String id, ItemData data) async =>
      VaultItem.fromJson(_map(await Core.call('update_item', {'id': id, 'data': data.toJson()})));

  static Future<void> deleteItem(String id) => Core.call('delete_item', {'id': id});

  static Future<void> restoreItem(String id) => Core.call('restore_item', {'id': id});

  static Future<List<AuditFinding>> audit() async =>
      [for (final f in (await Core.call('audit')) as List) AuditFinding.fromJson(_map(f))];

  static Future<String?> getSetting(String key) async => await Core.call('get_setting', {'key': key}) as String?;

  static Future<void> setSetting(String key, String value) => Core.call('set_setting', {'key': key, 'value': value});

  // ---- 同步调用（微秒级） ----

  static TotpCode totp(TotpConfig config) {
    final m = _map(Core.callSync('totp', {'config': config.toJson()}));
    return TotpCode(m['code'] as String, (m['remaining'] as num).toInt(), (m['period'] as num).toInt());
  }

  static ({TotpConfig config, String? issuer, String? account}) parseTotp(String text) {
    final m = _map(Core.callSync('parse_totp', {'text': text}));
    return (config: TotpConfig.fromJson(_map(m['config'])), issuer: m['issuer'] as String?, account: m['account'] as String?);
  }

  static Generated generatePassword({
    int length = 20,
    bool lowercase = true,
    bool uppercase = true,
    bool digits = true,
    bool symbols = true,
    bool excludeAmbiguous = true,
  }) {
    final m = _map(Core.callSync('generate_password', {
      'length': length,
      'lowercase': lowercase,
      'uppercase': uppercase,
      'digits': digits,
      'symbols': symbols,
      'excludeAmbiguous': excludeAmbiguous,
    }));
    return Generated(m['value'] as String, (m['entropy'] as num).toDouble());
  }

  static Generated generatePassphrase({int words = 5, String separator = '-', bool capitalize = true, bool includeNumber = true}) {
    final m = _map(Core.callSync('generate_passphrase', {
      'words': words,
      'separator': separator,
      'capitalize': capitalize,
      'includeNumber': includeNumber,
    }));
    return Generated(m['value'] as String, (m['entropy'] as num).toDouble());
  }

  static Strength strength(String password, {List<String> inputs = const []}) {
    if (password.isEmpty) return Strength.empty;
    final m = _map(Core.callSync('strength', {'password': password, 'inputs': inputs}));
    return Strength((m['score'] as num).toInt(), (m['guessesLog10'] as num).toDouble(), m['warning'] as String?);
  }

  static ({String prefix, String suffix}) breachQuery(String password) {
    final m = _map(Core.callSync('breach_query', {'text': password}));
    return (prefix: m['prefix'] as String, suffix: m['suffix'] as String);
  }

  static int breachCount(String body, String suffix) =>
      (Core.callSync('breach_count', {'body': body, 'suffix': suffix}) as num).toInt();

  /// 返回剪贴板序列号；平台不支持时返回 null。
  static int? clipboardCopy(String text) {
    try {
      return (_map(Core.callSync('clipboard_copy', {'text': text}))['sequence'] as num).toInt();
    } on CoreException catch (e) {
      if (e.code == 'unsupported') return null;
      rethrow;
    }
  }

  static bool clipboardClear(int sequence) =>
      _map(Core.callSync('clipboard_clear', {'sequence': sequence}))['cleared'] == true;
}
