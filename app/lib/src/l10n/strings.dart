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
  static const welcomeBack = '欢迎回来';
  static const unlockSubtitle = '输入主密码以解锁保险库';
  static const secretKeyLabel = 'Secret Key';
  static const secretKeyMissingOnDevice = '本设备未保存 Secret Key，请从 Recovery Kit 中输入。';
  static const unlocking = '正在解锁…';
  static const unlockWithBiometrics = '使用生物识别解锁';
  static const forgotMasterPassword = '忘记主密码？使用 Recovery Kit';
  static const backToUnlock = '返回解锁';
  static const recoverEyebrow = 'Recovery';
  static const recoverOnlineTitle = '联网恢复云账户';
  static const recoverOnlineSubtitle = '需要连接 Java 服务验证恢复材料。本机条目保留；云端确认后旧会话失效，并生成新的 Recovery Kit。失败时请使用相同材料与新密码重试。';
  static const accountEmail = '账户邮箱';
  static const recoveryCodeLabel = 'Recovery Code';
  static const newMasterPassword = '新主密码';
  static const confirmNewMasterPassword = '确认新主密码';
  static const resetMasterPassword = '重设主密码';
  static const recoverySucceededTitle = '恢复成功 · 保存新的 Recovery Kit';
  static const newPasswordTooShort = '新主密码至少 10 个字符';
  static const newPasswordMismatch = '两次输入的新主密码不一致';
  static const fatalOpenVaultFailed = '无法打开保险库';
  static const fatalDataIntact = '数据文件未被修改。请将以上信息反馈给我们。';

  // ───────── 引导 ─────────

  static const onboardWelcomeTitle = '欢迎使用 VaultOne';
  static const onboardWelcomeBody = '口令、账号、两步验证、密钥——\n全部在你的设备上加密，只为你一个人打开。';
  static const onboardRegister = '注册云账户';
  static const onboardHaveAccount = '我已有账户，登录';
  static const onboardAllDevicesLost = '所有设备都丢失了？用 Recovery Kit 恢复';
  static const onboardNetworkNote = '账户注册与登录需要联网；密码条目在本机加密，可离线使用并自动同步。';
  static const onboardStepOne = 'Step 01 / 02';
  static const onboardSetMasterPassword = '设置主密码';
  static const onboardSetMasterPasswordBody = '主密码是你唯一需要记住的密码。它从不离开这台设备，我们也无法帮你找回。';
  static const emailLabel = '邮箱';
  static const masterPasswordHint = '至少 10 个字符，推荐使用口令短语';
  static const confirmMasterPassword = '确认主密码';
  static const registering = '正在注册云账户…';
  static const registerAccount = '注册账户';
  static const onboardKeyLocalNote = '密钥在本机生成，主密码和 Secret Key 不会发送给服务端。只有 Java 服务确认注册后才完成建号；网络失败会保留加密注册草稿供重试。';
  static const invalidEmail = '请输入有效的邮箱地址';
  static const masterPasswordTooShort = '主密码至少 10 个字符';
  static const passwordTooWeak = '强度不足：试试 4 个以上随机单词组成的短语';
  static const passwordMismatch = '两次输入不一致';
  static const onboardStepTwo = 'Step 02 / 02';
  static const saveRecoveryKitTitle = '保存你的 Recovery Kit';
  static const recoveryKitSubtitle = '换新设备或忘记主密码时，这是找回保险库的唯一方式。请打印或离线保存，不要存放在网盘或聊天记录里。';
  static const saveRecoveryKitPdf = '保存 Recovery Kit（PDF）';
  static const saveRecoveryKitAgain = '已保存 · 再次保存';
  static const exportBackupCard = '导出备份卡（PNG · 700×900）';
  static const verifySecretKeyTitle = '逐字节核对 Secret Key';
  static const verifySecretKeyBody = '请把刚保存的 Secret Key 重新输入或粘贴一次。系统会逐字节比对（大小写、连字符与 I/L/O 的写法差异不影响结果），确认你手上的副本与本机一致。';
  static const reenterSecretKey = '重新输入 Secret Key';
  static const verifyAction = '核对';
  static const verifyOk = '与本机保存的 Secret Key 逐字节一致。';
  static const savedRecoveryKitAck = '我已妥善保存 Recovery Kit 与备份卡，并理解丢失后无人能帮我恢复数据。';
  static const enterVault = '进入保险库';
  static const kitCopyToast = '{label} 已复制，60 秒后自动清空剪贴板';
  static const privacyEyebrow = 'Privacy';
  static const privacyTitle = '隐私保护说明';
  static const privacySubtitle = '在开始使用前，请阅读并同意《隐私政策》与《用户协议》。';
  static const privacyLocalOnly = '数据只在本机加密';
  static const privacyLocalOnlyBody = '保险库内容在本机加密存储，云同步也只发送密文；账户和在线业务由 Java 服务处理。';
  static const privacyMinimalData = '我们收集的最少信息';
  static const privacyMinimalDataBody = '仅在你开启云同步时收集邮箱（用于登录与安全通知）与设备名称。';
  static const privacyNeverDo = '不做的事';
  static const privacyNeverDoBody = '不接入任何第三方统计、广告或推送 SDK；不读取通讯录、位置等无关权限。';
  static const privacyBiometrics = '生物识别';
  static const privacyBiometricsBody = '指纹/面容仅由系统验证，VaultOne 无法获取任何生物特征数据；需你单独开启。';
  static const privacyPolicy = '《隐私政策》';
  static const termsOfService = '《用户协议》';
  static const agreeAndContinue = '同意并继续';
  static const disagreeAndExit = '不同意并退出';

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
    welcomeBack: '歡迎回來',
    unlockSubtitle: '輸入主密碼以解鎖保險庫',
    secretKeyLabel: 'Secret Key',
    secretKeyMissingOnDevice: '本裝置未儲存 Secret Key，請從 Recovery Kit 中輸入。',
    unlocking: '正在解鎖…',
    unlockWithBiometrics: '使用生物辨識解鎖',
    forgotMasterPassword: '忘記主密碼？使用 Recovery Kit',
    backToUnlock: '返回解鎖',
    recoverEyebrow: 'Recovery',
    recoverOnlineTitle: '連線恢復雲端帳戶',
    recoverOnlineSubtitle: '需連線 Java 服務驗證恢復材料。本機項目保留；雲端確認後舊工作階段失效，並產生新的 Recovery Kit。失敗時請使用相同材料與新密碼重試。',
    accountEmail: '帳戶電子郵件',
    recoveryCodeLabel: 'Recovery Code',
    newMasterPassword: '新主密碼',
    confirmNewMasterPassword: '確認新主密碼',
    resetMasterPassword: '重設主密碼',
    recoverySucceededTitle: '恢復成功 · 儲存新的 Recovery Kit',
    newPasswordTooShort: '新主密碼至少 10 個字元',
    newPasswordMismatch: '兩次輸入的新主密碼不一致',
    fatalOpenVaultFailed: '無法開啟保險庫',
    fatalDataIntact: '資料檔案未被修改。請將以上資訊回報給我們。',
    onboardWelcomeTitle: '歡迎使用 VaultOne',
    onboardWelcomeBody: '口令、帳號、兩步驗證、金鑰——\n全部在你的裝置上加密，只為你一個人開啟。',
    onboardRegister: '註冊雲端帳戶',
    onboardHaveAccount: '我已有帳戶，登入',
    onboardAllDevicesLost: '所有裝置都遺失了？用 Recovery Kit 恢復',
    onboardNetworkNote: '帳戶註冊與登入需要連線；密碼項目在本機加密，可離線使用並自動同步。',
    onboardStepOne: 'Step 01 / 02',
    onboardSetMasterPassword: '設定主密碼',
    onboardSetMasterPasswordBody: '主密碼是你唯一需要記住的密碼。它從不離開這台裝置，我們也無法幫你找回。',
    emailLabel: '電子郵件',
    masterPasswordHint: '至少 10 個字元，推薦使用口令短語',
    confirmMasterPassword: '確認主密碼',
    registering: '正在註冊雲端帳戶…',
    registerAccount: '註冊帳戶',
    onboardKeyLocalNote: '金鑰在本機產生，主密碼與 Secret Key 不會傳送給伺服器。只有 Java 服務確認註冊後才完成建號；網路失敗會保留加密註冊草稿供重試。',
    invalidEmail: '請輸入有效的電子郵件地址',
    masterPasswordTooShort: '主密碼至少 10 個字元',
    passwordTooWeak: '強度不足：試試 4 個以上隨機單字組成的短語',
    passwordMismatch: '兩次輸入不一致',
    onboardStepTwo: 'Step 02 / 02',
    saveRecoveryKitTitle: '儲存你的 Recovery Kit',
    recoveryKitSubtitle: '換新裝置或忘記主密碼時，這是找回保險庫的唯一方式。請列印或離線保存，不要存放在網盤或聊天記錄裡。',
    saveRecoveryKitPdf: '儲存 Recovery Kit（PDF）',
    saveRecoveryKitAgain: '已儲存 · 再次儲存',
    exportBackupCard: '匯出備份卡（PNG · 700×900）',
    verifySecretKeyTitle: '逐位元組核對 Secret Key',
    verifySecretKeyBody: '請把剛儲存的 Secret Key 重新輸入或貼上一次。系統會逐位元組比對（大小寫、連字號與 I/L/O 的寫法差異不影響結果），確認你手上的副本與本機一致。',
    reenterSecretKey: '重新輸入 Secret Key',
    verifyAction: '核對',
    verifyOk: '與本機儲存的 Secret Key 逐位元組一致。',
    savedRecoveryKitAck: '我已妥善保存 Recovery Kit 與備份卡，並理解遺失後無人能幫我恢復資料。',
    enterVault: '進入保險庫',
    kitCopyToast: '{label} 已複製，60 秒後自動清空剪貼簿',
    privacyEyebrow: 'Privacy',
    privacyTitle: '隱私保護說明',
    privacySubtitle: '在開始使用前，請閱讀並同意《隱私政策》與《使用者條款》。',
    privacyLocalOnly: '資料只在本機加密',
    privacyLocalOnlyBody: '保險庫內容在本機加密儲存，雲端同步也只傳送密文；帳戶與線上業務由 Java 服務處理。',
    privacyMinimalData: '我們收集的最少資訊',
    privacyMinimalDataBody: '僅在你開啟雲端同步時收集電子郵件（用於登入與安全通知）與裝置名稱。',
    privacyNeverDo: '不做的事',
    privacyNeverDoBody: '不接入任何第三方統計、廣告或推播 SDK；不讀取通訊錄、位置等無關權限。',
    privacyBiometrics: '生物辨識',
    privacyBiometricsBody: '指紋/面容僅由系統驗證，VaultOne 無法取得任何生物特徵資料；需你單獨開啟。',
    privacyPolicy: '《隱私政策》',
    termsOfService: '《使用者條款》',
    agreeAndContinue: '同意並繼續',
    disagreeAndExit: '不同意並結束',
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
    welcomeBack: 'Welcome back',
    unlockSubtitle: 'Enter your master password to unlock the vault',
    secretKeyLabel: 'Secret Key',
    secretKeyMissingOnDevice: 'This device has no stored Secret Key. Enter it from your Recovery Kit.',
    unlocking: 'Unlocking…',
    unlockWithBiometrics: 'Unlock with biometrics',
    forgotMasterPassword: 'Forgot your master password? Use the Recovery Kit',
    backToUnlock: 'Back to unlock',
    recoverEyebrow: 'Recovery',
    recoverOnlineTitle: 'Recover the cloud account online',
    recoverOnlineSubtitle:
        'A Java service is contacted to verify the recovery material. Local items are kept; once the cloud confirms, old sessions are invalidated and a new Recovery Kit is issued. If it fails, retry with the same material and new password.',
    accountEmail: 'Account email',
    recoveryCodeLabel: 'Recovery Code',
    newMasterPassword: 'New master password',
    confirmNewMasterPassword: 'Confirm new master password',
    resetMasterPassword: 'Reset master password',
    recoverySucceededTitle: 'Recovered · save the new Recovery Kit',
    newPasswordTooShort: 'The new master password needs at least 10 characters',
    newPasswordMismatch: 'The two new master passwords do not match',
    fatalOpenVaultFailed: 'Could not open the vault',
    fatalDataIntact: 'Your data files were not modified. Please report the message above.',
    onboardWelcomeTitle: 'Welcome to VaultOne',
    onboardWelcomeBody: 'Passwords, accounts, two-factor codes and keys —\nencrypted on your device, opened only by you.',
    onboardRegister: 'Create a cloud account',
    onboardHaveAccount: 'I already have an account',
    onboardAllDevicesLost: 'Lost every device? Restore with the Recovery Kit',
    onboardNetworkNote: 'Signing up and in requires a network connection. Passwords are encrypted locally, usable offline and synced automatically.',
    onboardStepOne: 'Step 01 / 02',
    onboardSetMasterPassword: 'Set your master password',
    onboardSetMasterPasswordBody: 'The master password is the only password you have to remember. It never leaves this device, and nobody can recover it for you.',
    emailLabel: 'Email',
    masterPasswordHint: 'At least 10 characters; a passphrase is recommended',
    confirmMasterPassword: 'Confirm master password',
    registering: 'Creating the cloud account…',
    registerAccount: 'Create account',
    onboardKeyLocalNote: 'Keys are generated on this device; the master password and Secret Key are never sent to the server. Signup completes only after the Java service confirms it; a failed network attempt keeps an encrypted draft for retry.',
    invalidEmail: 'Enter a valid email address',
    masterPasswordTooShort: 'The master password needs at least 10 characters',
    passwordTooWeak: 'Too weak: try a passphrase of four or more random words',
    passwordMismatch: 'The two entries do not match',
    onboardStepTwo: 'Step 02 / 02',
    saveRecoveryKitTitle: 'Save your Recovery Kit',
    recoveryKitSubtitle: 'On a new device, or if you forget the master password, this is the only way back into your vault. Print it or keep it offline — never in cloud drives or chat history.',
    saveRecoveryKitPdf: 'Save Recovery Kit (PDF)',
    saveRecoveryKitAgain: 'Saved · save again',
    exportBackupCard: 'Export backup card (PNG · 700×900)',
    verifySecretKeyTitle: 'Verify the Secret Key byte by byte',
    verifySecretKeyBody: 'Type or paste the Secret Key you just saved. It is compared byte by byte (case, dashes and I/L/O spellings do not matter) to confirm the copy in your hands matches this device.',
    reenterSecretKey: 'Re-enter the Secret Key',
    verifyAction: 'Verify',
    verifyOk: 'Byte-for-byte identical to the Secret Key stored on this device.',
    savedRecoveryKitAck: 'I have safely stored the Recovery Kit and backup card, and I understand nobody can recover my data if they are lost.',
    enterVault: 'Enter the vault',
    kitCopyToast: '{label} copied; the clipboard clears automatically in 60 seconds',
    privacyEyebrow: 'Privacy',
    privacyTitle: 'Privacy notice',
    privacySubtitle: 'Before you start, please read and accept the Privacy Policy and Terms of Service.',
    privacyLocalOnly: 'Data is encrypted on this device',
    privacyLocalOnlyBody: 'Vault contents are encrypted locally and cloud sync sends ciphertext only. Accounts and online features are handled by a Java service.',
    privacyMinimalData: 'The minimum we collect',
    privacyMinimalDataBody: 'Only when you enable cloud sync: your email (for sign-in and security notices) and device name.',
    privacyNeverDo: 'What we never do',
    privacyNeverDoBody: 'No third-party analytics, ads or push SDKs; no access to contacts, location or other unrelated permissions.',
    privacyBiometrics: 'Biometrics',
    privacyBiometricsBody: 'Fingerprint and face verification happen in the operating system; VaultOne never receives biometric data and you must opt in.',
    privacyPolicy: 'Privacy Policy',
    termsOfService: 'Terms of Service',
    agreeAndContinue: 'Agree and continue',
    disagreeAndExit: 'Disagree and exit',
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
