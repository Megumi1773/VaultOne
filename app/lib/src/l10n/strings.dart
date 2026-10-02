import 'package:flutter/widgets.dart';

/// 支持的语言。`code`/`script` 用于持久化与 `Locale`，`label` 是设置页上的自称（各语言用本语言写）。
enum AppLanguage {
  zhHans('zh', 'Hans', '简体中文'),
  zhHant('zh', 'Hant', '繁體中文'),
  en('en', '', 'English');

  const AppLanguage(this.code, this.script, this.label);

  final String code;
  final String script;
  final String label;

  Locale get locale => script.isEmpty ? Locale(code) : Locale.fromSubtags(languageCode: code, scriptCode: script);

  /// 从持久化值解析；未知值回退到简体中文。
  static AppLanguage parse(String? value) => switch (value) {
        'zh_Hant' => AppLanguage.zhHant,
        'en' => AppLanguage.en,
        _ => AppLanguage.zhHans,
      };

  String get storageKey => script.isEmpty ? code : '${code}_$script';
}

/// 界面文案表。
///
/// 常量本身是**简体中文原文**，其余语言通过 [translate] 查表覆盖：未翻译的条目自动回退到
/// 中文原文，因此新增文案不会因为漏翻译而显示空白或键名。带参数的文案用 `{name}` 占位，
/// 配合 [format] 填充。
///
/// 本类只放**用户可见**文案。内核错误码到提示的映射、日志与调试文本不进这里。
abstract final class AppStrings {
  static const supported = AppLanguage.values;

  static const defaultLanguage = AppLanguage.zhHans;

  // ───────── 应用壳与通用 ─────────

  static const appName = 'VaultOne';
  static const unknownError = '未知错误';
  static const cancel = '取消';
  static const confirm = '确认';
  static const close = '关闭';
  static const save = '保存';
  static const saved = '已保存';
  static const delete = '删除';
  static const retry = '重试';
  static const back = '返回';
  static const search = '搜索';
  static const loading = '加载中…';
  static const copy = '复制';
  static const copied = '已复制';
  static const placeholder = '—';

  // ───────── 语言 ─────────

  static const language = '语言';
  static const languageSubtitle = '切换界面语言。条目内容、备注与自定义字段不受影响，不会被翻译或上传。';

  // ───────── 设置页 ─────────

  static const settings = '设置';
  static const sectionAccount = '账户';
  static const sectionCloudAccount = '云账户';
  static const sectionKeyBackup = '密钥与备份';
  static const sectionSecurity = '解锁与安全';
  static const sectionSync = '云同步';
  static const sectionConflict = '同步冲突';
  static const sectionData = '数据';
  static const sectionDesktop = '桌面';
  static const sectionAutofill = '自动填充';
  static const sectionBrowser = '浏览器扩展';
  static const sectionAppearance = '外观';
  static const sectionDiagnostics = '诊断';
  static const sectionAbout = '关于';
  static const sectionDanger = '危险操作';

  // ───────── 导航分区 ─────────

  static const sectionAll = '全部条目';
  static const sectionAllShort = '全部';
  static const sectionFavorites = '收藏';
  static const sectionLogin = '登录';
  static const sectionCard = '支付卡';
  static const sectionNote = '安全笔记';
  static const sectionNoteShort = '笔记';
  static const sectionIdentity = '身份信息';
  static const sectionIdentityShort = '身份';
  static const sectionGenerator = '密码生成器';
  static const sectionSecurityCenter = '安全中心';
  static const sectionTrash = '回收站';
  static const tabVault = '保险库';
  static const tabGenerator = '生成器';
  static const tabSecurity = '安全';

  // ───────── 解锁与身份 ─────────

  static const unlockTitle = '解锁保险库';
  static const masterPassword = '主密码';
  static const unlockAction = '解锁';
  static const lockAction = '锁定';

  /// 简单占位替换：`format(AppStrings.someTemplate, {'name': value})`。
  static String format(String template, Map<String, Object?> values) {
    var out = template;
    for (final entry in values.entries) {
      out = out.replaceAll('{${entry.key}}', '${entry.value}');
    }
    return out;
  }

  /// 查表翻译：目标语言缺条目时回退到中文原文。
  static String translate(String source, AppLanguage language) {
    if (language == defaultLanguage) return source;
    return _tables[language]?[source] ?? source;
  }

  static const Map<AppLanguage, Map<String, String>> _tables = {
    AppLanguage.zhHant: _zhHant,
    AppLanguage.en: _en,
  };

  static const Map<String, String> _zhHant = {
    appName: 'VaultOne',
    unknownError: '未知錯誤',
    cancel: '取消',
    confirm: '確認',
    close: '關閉',
    save: '儲存',
    saved: '已儲存',
    delete: '刪除',
    retry: '重試',
    back: '返回',
    search: '搜尋',
    loading: '載入中…',
    copy: '複製',
    copied: '已複製',
    language: '語言',
    languageSubtitle: '切換介面語言。條目內容、備註與自訂欄位不受影響，不會被翻譯或上傳。',
    settings: '設定',
    sectionAccount: '帳戶',
    sectionCloudAccount: '雲端帳戶',
    sectionKeyBackup: '金鑰與備份',
    sectionSecurity: '解鎖與安全',
    sectionSync: '雲端同步',
    sectionConflict: '同步衝突',
    sectionData: '資料',
    sectionDesktop: '桌面',
    sectionAutofill: '自動填入',
    sectionBrowser: '瀏覽器擴充功能',
    sectionAppearance: '外觀',
    sectionDiagnostics: '診斷',
    sectionAbout: '關於',
    sectionDanger: '危險操作',
    sectionAll: '全部項目',
    sectionAllShort: '全部',
    sectionFavorites: '收藏',
    sectionLogin: '登入',
    sectionCard: '支付卡',
    sectionNote: '安全筆記',
    sectionNoteShort: '筆記',
    sectionIdentity: '身分資訊',
    sectionIdentityShort: '身分',
    sectionGenerator: '密碼產生器',
    sectionSecurityCenter: '安全中心',
    sectionTrash: '回收筒',
    tabVault: '保險庫',
    tabGenerator: '產生器',
    tabSecurity: '安全',
    unlockTitle: '解鎖保險庫',
    masterPassword: '主密碼',
    unlockAction: '解鎖',
    lockAction: '鎖定',
  };

  static const Map<String, String> _en = {
    appName: 'VaultOne',
    unknownError: 'Unknown error',
    cancel: 'Cancel',
    confirm: 'Confirm',
    close: 'Close',
    save: 'Save',
    saved: 'Saved',
    delete: 'Delete',
    retry: 'Retry',
    back: 'Back',
    search: 'Search',
    loading: 'Loading…',
    copy: 'Copy',
    copied: 'Copied',
    language: 'Language',
    languageSubtitle:
        'Switch the interface language. Item contents, notes and custom fields are never translated or uploaded.',
    settings: 'Settings',
    sectionAccount: 'Account',
    sectionCloudAccount: 'Cloud account',
    sectionKeyBackup: 'Keys and backup',
    sectionSecurity: 'Unlock and security',
    sectionSync: 'Cloud sync',
    sectionConflict: 'Sync conflicts',
    sectionData: 'Data',
    sectionDesktop: 'Desktop',
    sectionAutofill: 'Autofill',
    sectionBrowser: 'Browser extension',
    sectionAppearance: 'Appearance',
    sectionDiagnostics: 'Diagnostics',
    sectionAbout: 'About',
    sectionDanger: 'Danger zone',
    sectionAll: 'All items',
    sectionAllShort: 'All',
    sectionFavorites: 'Favorites',
    sectionLogin: 'Logins',
    sectionCard: 'Cards',
    sectionNote: 'Secure notes',
    sectionNoteShort: 'Notes',
    sectionIdentity: 'Identities',
    sectionIdentityShort: 'Identity',
    sectionGenerator: 'Password generator',
    sectionSecurityCenter: 'Security center',
    sectionTrash: 'Trash',
    tabVault: 'Vault',
    tabGenerator: 'Generator',
    tabSecurity: 'Security',
    unlockTitle: 'Unlock vault',
    masterPassword: 'Master password',
    unlockAction: 'Unlock',
    lockAction: 'Lock',
  };
}

/// 当前语言的作用域。语言切换要立即重建整棵树，因此放在应用根之上。
class LocaleScope extends InheritedWidget {
  const LocaleScope({super.key, required this.language, required super.child});

  final AppLanguage language;

  @override
  bool updateShouldNotify(LocaleScope old) => old.language != language;
}

extension AppLocaleX on BuildContext {
  /// 当前语言；没有 [LocaleScope] 时回退到默认语言（测试与独立页面）。
  AppLanguage get language => dependOnInheritedWidgetOfExactType<LocaleScope>()?.language ?? AppStrings.defaultLanguage;

  /// 翻译取词入口：`context.tr(AppStrings.settings)`。
  String tr(String source) => AppStrings.translate(source, language);

  /// 带占位符的翻译：`context.trf(AppStrings.someTemplate, {'name': v})`。
  String trf(String source, Map<String, Object?> values) => AppStrings.format(tr(source), values);
}
