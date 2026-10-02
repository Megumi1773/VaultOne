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

  // ───────── 设置页明细 ─────────

  static const never = '从未';
  static const accountIdLabel = '账户 ID  {id}';
  static const keyDerivation = '密钥派生';
  static const itemCountTag = '{count} 个条目';
  static const secretKeyRowSubtitle = '保存在本机系统钥匙串中。查看或重新导出恢复材料前，需要重新输入 Secret Key 与恢复码做逐字节核对。';
  static const verifyAndView = '核对并查看';
  static const changeMasterPassword = '修改主密码';
  static const changeMasterPasswordSubtitle = '只重新封装保险库密钥，条目无需重新加密，秒级完成。';
  static const masterPasswordUpdated = '主密码已更新，其他设备同步后需使用新主密码解锁';
  static const newPasswordTooWeak = '新主密码强度不足';
  static const currentMasterPassword = '当前主密码';
  static const updateMasterPassword = '更新主密码';
  static const backupKindRecoveryKit = '恢复套件 PDF';
  static const backupKindCard = '备份卡 PNG';
  static const backupKindWljbak = '加密备份 .wljbak';
  static const backupKindCsv = '明文 CSV';
  static const backupNever = '本机尚未记录任何备份导出。请先导出恢复套件，并把它打印或存进离线介质。';
  static const backupLast = '最近一次：{time}（{kind}）。本机只记录时间与方式，不保存文件路径与内容。';
  static const backupStatus = '备份状态';
  static const backupCloudNote = '云端备份历史需要服务端端点，尚未实现；这里不把本机记录当作云端已备份。';
  static const backupMissing = '未备份';
  static const backupPresent = '已备份';
  static const recoveryKitAndCard = '恢复套件与备份卡';
  static const recoveryKitAndCardSubtitle = '重新导出 A4 恢复套件 PDF，或 700×900（2x 导出）的备份卡 PNG。两者都等价于明文凭据，导出前需要重新输入 Secret Key 与恢复码做核对。';
  static const manageAction = '管理';
  static const biometricUnlock = '生物识别解锁';
  static const biometricUnlockSubtitle = '使用 Windows Hello / Touch ID / Face ID / 指纹快速解锁。快速解锁密钥保存在系统钥匙串，修改主密码后自动失效。';
  static const biometricEnable = '启用生物识别解锁';
  static const biometricDisable = '关闭生物识别解锁';
  static const autoLock = '自动锁定';
  static const autoLockSubtitle = '无操作一段时间后锁定保险库并清空内存中的密钥。';
  static const minutes = '{n} 分钟';
  static const lockOnMinimize = '切到后台 / 最小化时锁定';
  static const clipboardAutoClear = '剪贴板自动清除';
  static const clipboardAutoClearSubtitle = '复制密码后到期清空；桌面端写入时排除剪贴板历史与云同步。';
  static const seconds = '{n} 秒';
  static const cloudSetupPending = '云账户尚未完成接入';
  static const cloudSetupPendingBody = '重新解锁后完成 Java 云注册。现有条目保留，不提供独立的纯本地账户模式。';
  static const syncing = '同步中…';
  static const syncFailed = '同步失败：{reason}';
  static const sessionExpired = '登录已过期，请重新验证';
  static const autoSync = '条目自动同步';
  static const deviceSummary = '本设备：{device} · 上次同步 {time} · 待上传 {pending}';
  static const revalidate = '重新验证';
  static const reconnectSync = '重新连接同步服务';
  static const reconnected = '已重新连接';
  static const syncNow = '立即同步';
  static const mergedItems = '已合并 {n} 个在多台设备上同时修改的条目';
  static const deviceManagement = '设备管理';
  static const signOutCloudLock = '退出云登录并锁定';
  static const signOutCloudTitle = '退出云登录？';
  static const signOutCloudBody = '联网撤销当前会话并锁定本机；本机条目、待同步修改和服务器绑定保留。';
  static const signOutAndLock = '退出并锁定';
  static const securityLog = '安全日志';
  static const deviceManagementSubtitle = '新设备登录需经邮件验证码或在此批准。撤销后该设备会话立即失效。';
  static const deviceThis = '本机';
  static const deviceRevoked = '已撤销';
  static const devicePending = '待批准';
  static const deviceLine = '{platform} · 添加于 {created} · 最近活跃 {seen}';
  static const approveAction = '批准';
  static const approvedAction = '已批准';
  static const revokeAction = '撤销';
  static const revokeDeviceTitle = '撤销设备「{name}」？';
  static const revokeDeviceBody = '该设备将被立即登出且无法再同步。';
  static const auditSignInOk = '登录成功';
  static const auditSignInFail = '登录失败';
  static const auditDeviceRequest = '新设备请求登录';
  static const auditDeviceApproved = '设备已批准';
  static const auditDeviceRevoked = '设备已撤销';
  static const auditPasswordChanged = '主密码已修改';
  static const auditRecoveryUsed = '使用 Recovery Kit 恢复';
  static const auditRecoveryFail = '恢复码验证失败';
  static const theme = '主题';
  static const themeSystem = '跟随系统';
  static const themeLight = '浅色';
  static const themeDark = '深色';
  static const compareConflicts = '比较并裁决冲突';
  static const compareConflictsSubtitle = '冲突双方版本在本机加密保存。裁决后等待同步确认；有未完成冲突时不能导出，以免漏掉另一方内容。';
  static const viewConflicts = '查看冲突';
  static const importDone = '导入完成';
  static const importSummary = '来源：{source}\n新增 {added} 条{duplicates}{skipped}。\n\n导出文件是明文，请立即从磁盘和回收站中彻底删除。';
  static const importBackupSummary = '新增 {added} 条{duplicates}{skipped}。';
  static const importDuplicates = '，{n} 条与现有条目重复已跳过';
  static const importSkipped = '，{n} 条无法识别';
  static const gotIt = '知道了';
  static const notUtf8 = '文件不是 UTF-8 文本，请用原软件重新导出为 CSV';
  static const vaultoneBackup = 'VaultOne 备份';
  static const backupSaved = '已保存加密备份（{bytes} 字节）到 {path}';
  static const backupSaveFailed = '备份保存失败，请检查目录权限与可用空间。若留下不完整文件，请勿用于恢复。';
  static const csvConfirmTitle = '导出明文 CSV？';
  static const csvConfirmBody = 'CSV 不加密，任何拿到文件的人都能看到密码与 TOTP 种子。\n\n'
      'CSV 不是完整备份：仅导出标题、首个网址、用户名、密码、备注、TOTP 种子、收藏和类型；'
      '不保留卡片/身份专用字段、自定义字段、其他网址与匹配规则、密码历史及完整 TOTP 参数。'
      '不含回收站，不能用它无损恢复保险库。完整条目备份请选 .wljbak。\n\n'
      '导出后请妥善保管，迁移完成后从磁盘与回收站彻底删除；不要用电子表格软件打开不可信内容。';
  static const stillExport = '仍要导出';
  static const csvSaved = '已保存有损 CSV（{bytes} 字节）到 {path}；请核对迁移结果，这不是完整备份。';
  static const csvSaveFailed = 'CSV 保存失败，请检查目录权限与可用空间，并清理可能留下的明文文件。';
  static const importFromOthers = '从其他密码管理器导入';
  static const importFromOthersSubtitle = '支持 Chrome / Edge / Firefox / Bitwarden / LastPass / 1Password 导出的 CSV 与 1PIF。文件只在本机解析，随即加密入库；重复条目自动跳过。';
  static const importing = '导入中…';
  static const chooseFile = '选择文件';
  static const exportEncryptedBackup = '导出加密备份';
  static const exportEncryptedBackupSubtitle = '导出本账户的 .wljbak 条目级备份，不含回收站，不是数据库快照。需先恢复同一账户及其 Vault Key，再导入；仅持有文件或新建同名账户无法恢复。导入会重建条目 ID 和创建/更新时间。';
  static const exportAction = '导出';
  static const exportCsv = '导出明文 CSV';
  static const exportCsvSubtitle = '仅用于有损迁移，不含完整类型字段、历史、多网址及完整 TOTP 参数。文件不加密，请谨慎保管。';
  static const importFromBackup = '从加密备份导入';
  static const importFromBackupSubtitle = '选择 .wljbak 备份包还原条目；重复条目自动跳过。';
  static const keepInTray = '关闭窗口时保留在系统托盘';
  static const keepInTraySubtitle = '关闭后仍可通过托盘图标或快捷键唤起；从托盘菜单选择「退出」才会结束程序。';
  static const globalHotkey = '全局快捷键  {combo}';
  static const globalHotkeySubtitle = '在任何程序中按下即可唤起 VaultOne 并聚焦搜索框。';
  static const allowBrowserExtension = '允许浏览器扩展连接';
  static const allowBrowserExtensionSubtitle = '扩展通过本机 Native Messaging 向 VaultOne 请求凭据，只会拿到与当前网站严格匹配的那一条；解密全部在本应用内完成。';
  static const installExtension = '安装扩展';
  static const installExtensionSubtitle = '支持 Chrome、Edge、Brave 等 Chromium 内核浏览器。安装后点击扩展图标完成配对。';
  static const pairedBrowsers = '已配对的浏览器';
  static const noneYet = '暂无';
  static const pairedAt = '配对于 {created} · 最近使用 {used}';
  static const removeAction = '移除';
  static const repairConnection = '修复连接';
  static const repairConnectionSubtitle = '扩展提示"未找到 VaultOne 桌面端"时，重新向浏览器登记连接器。';
  static const reregister = '重新登记';
  static const reregistered = '已登记，请重启浏览器后重试';
  static const autofillEnabled = 'VaultOne 已是系统自动填充服务';
  static const autofillEnable = '将 VaultOne 设为自动填充服务';
  static const autofillSubtitle = '在应用和浏览器的登录框中选择「用 VaultOne 填充」。网页只推荐与当前域名严格匹配的条目；登录后可一键保存新密码。';
  static const enabledTag = '已启用';
  static const openSettings = '去设置';
  static const verboseLogs = '详细日志（诊断模式）';
  static const verboseLogsSubtitle = '日志只含事件类型、错误码与耗时，绝不包含密码、条目内容或邮箱。重启应用后生效。';
  static const logFile = '日志文件';
  static const logFileSubtitle = '反馈问题时可附上日志文件。';
  static const openFolder = '打开目录';
  static const logDirFailed = '无法打开日志目录，请手动前往：{path}';
  static const logDirFailedGeneric = '打开日志目录失败，请手动前往应用数据目录下的 logs 文件夹';
  static const buildInfo = '构建 {build} · 加密内核开源（AGPL-3.0）';
  static const privacyPolicyLink = '隐私政策';
  static const termsLink = '用户协议';
  static const sourceAndWhitepaper = '源代码与安全白皮书';
  static const openSourceLicenses = '开源许可';
  static const viewLicenses = '查看第三方开源许可';
  static const feedback = '意见反馈';
  static const feedbackSubtitle = '提交问题或建议，查看处理状态与客服回复。需要连接支持此功能的 Java 服务。';
  static const openFeedback = '打开反馈';
  static const contactSupport = '联系支持';
  static const sendEmail = '发送邮件';
  static const wipeLocalData = '清除本机数据';
  static const wipeLocalDataSubtitle = '删除本机保险库与保存的 Secret Key，不注销云账户；未同步的本机修改会丢失。';
  static const wipeConfirmBody = '未同步的本机条目和修改将永久丢失。只有已成功同步的数据才能在重新登录后恢复。请先确认备份及 Secret Key 已妥善保存。';
  static const wipeConfirmTitle = '清除本机数据？';
  static const deleteCloudAccount = '注销云端账户';
  static const deleteCloudAccountSubtitle = '永久删除云端的全部密文、设备与日志（个人信息保护法 / GDPR 删除权）。本机数据保留。';
  static const deleteAccountAction = '注销';
  static const deleteCloudAccountBody = '此操作不可撤销。请输入主密码确认。';
  static const deletePermanently = '永久注销';
  static const cloudAccountDeleted = '云端账户已注销';

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

  // ───────── 条目列表 ─────────

  static const searchItemsHint = '搜索标题、用户名、网址';
  static const clearSearch = '清除';
  static const newItem = '新建';
  static const emptySearchTitle = '没有匹配“{query}”的条目';
  static const emptySearchBody = '试试标题、用户名或网址中的其他关键词';
  static const emptyTrashTitle = '回收站是空的';
  static const emptyTrashBody = '删除的条目会在这里保留，可随时恢复';
  static const emptyVaultTitle = '这里还没有条目';
  static const emptyVaultBodyCompact = '点右下角 + 创建第一个';
  static const emptyVaultBody = '按 Ctrl+N 创建第一个';
  static const emptyTrashConfirmTitle = '清空回收站？';
  static const emptyTrashConfirmBody = '回收站中已同步的条目将从本机永久删除，无法恢复；尚未同步的条目会保留。已同步到云端的数据不会在其他设备上被抹除。';
  static const emptyTrashConfirmAction = '清空';
  static const emptyTrashKeptNote = '，{kept} 条未同步已保留';
  static const emptyTrashNone = '没有可清空的条目{kept}';
  static const emptyTrashDone = '已彻底删除 {purged} 条{kept}';
  static const emptyTrashTooltip = '清空回收站';
  static const lockNow = '立即锁定';
  static const lockNowWithHotkey = '立即锁定 (Ctrl+L)';
  static const newItemTooltip = '新建条目';
  static const sidebarCategories = '分类';
  static const sidebarTools = '工具';
  static const selectItemHint = '选择一个条目查看详情';
  static const shortcutHint = 'Ctrl+F 搜索 · Ctrl+N 新建 · Ctrl+G 生成密码 · Ctrl+L 锁定';
  static const itemMissing = '条目不存在';
  static const cloudNeedsRevalidate = '云账户需要重新验证';

  // ───────── 条目编辑器 ─────────

  static const titleLabel = '标题';
  static const titleRequired = '请输入标题';
  static const createdItem = '已创建「{title}」';
  static const hintLoginTitle = '例如：GitHub';
  static const hintCardTitle = '例如：招商银行信用卡';
  static const hintNoteTitle = '例如：服务器备忘';
  static const hintIdentityTitle = '例如：本人';
  static const groupLoginCredentials = '登录凭据';
  static const fieldUsernameOrEmail = '用户名 / 邮箱';
  static const generateStrongPassword = '生成强密码';
  static const fieldTotpFull = '两步验证（TOTP）';
  static const scanQrCode = '扫描二维码';
  static const preview = '预览';
  static const totpParams = '{alg} · {digits} 位 · {period}s';
  static const addAction = '添加';
  static const groupWebsite = '网站';
  static const groupCardInfo = '卡片信息';
  static const fieldName = '名称';
  static const fieldValue = '值';
  static const sensitiveField = '敏感字段（默认隐藏）';
  static const plainField = '普通字段';
  static const groupContent = '内容';
  static const notesPlaceholder = '仅你可见，端到端加密';
  static const customFieldsExample = '例如：安全问题、U 盾编号、API Key';
  static const createItemTitle = '新建{kind}';
  static const editItemTitle = '编辑{kind}';
  static const editorShortcuts = 'Ctrl+S 保存 · Esc 取消';
  static const templateSection = '从模板开始';
  static const templateAllFields = '完整字段';
  static const templateNote = '模板会预置字段并调整新建表单，已填写内容不会被覆盖。';
  static const urlMatchPickerLabel = '匹配方式（自动填充时使用）';
  static const urlMatchDomain = '域名';
  static const urlMatchHost = '主机';
  static const urlMatchExact = '精确';
  static const urlMatchNever = '从不';

  // ───────── 登录与设备批准 ─────────

  static const signInEyebrow = 'Sign in';
  static const signInTitle = '登录已有账户';
  static const signInSubtitle = '需要 Recovery Kit 上的 Secret Key。主密码只在本机参与计算，不会发送到服务器。';
  static const fillAllFields = '请填写邮箱、Secret Key 与主密码';
  static const deviceNameLabel = '设备名称';
  static const thisDeviceName = '本设备名称';
  static const syncServerLabel = '同步服务器';
  static const verifying = '正在验证…';
  static const newDeviceEyebrow = 'New device';
  static const verifyDeviceTitle = '验证这台新设备';
  static const verifyDeviceSubtitle = '为防止账户被盗用，新设备首次登录必须二次验证。我们已向你的邮箱发送 6 位验证码；也可以在已登录的设备上「设置 → 设备管理」中批准。';
  static const emailCodeLabel = '邮件验证码';
  static const emailCodeHint = '6 位数字';
  static const verifyAndContinue = '验证并继续';
  static const waitingApproval = '正在等待其他设备批准…';
  static const cancelSignIn = '取消登录';
  static const recoverAccountTitle = '用 Recovery Kit 恢复账户';
  static const recoverAccountSubtitle = '恢复后需设置新主密码，旧恢复码与所有旧设备会话立即失效，你会拿到一份新的 Recovery Kit。';
  static const recoverAccountAction = '恢复账户';

  // ───────── 云注册过渡 ─────────

  static const cloudSetupRetry = '注册尚未完成，请重试';
  static const cloudBackupSaved = '加密备份已保存；恢复仍需当前账户的密钥材料';
  static const cloudBackupFailed = '备份保存失败，请检查保存位置';
  static const wipeAndReloginTitle = '清除本机数据并重新登录？';
  static const wipeAndReloginBody = '不会注销云账户。未同步的本机条目和注册草稿会永久丢失，本机保存的 Secret Key 也会删除。请先导出备份并保管恢复材料；云注册超时并不代表云账户未创建。';
  static const wipeAndReloginConfirm = '确认清除本机数据';
  static const wipeIncomplete = '清除未完成，请重试；云账户未被注销';
  static const cloudFinishTitle = '完成云账户注册';
  static const cloudAttachTitle = '将现有保险库接入云账户';
  static const cloudFinishBody = '注册材料已在本机加密保存。只有 Java 服务确认后才完成注册；重试沿用同一账户与密钥，不会重新生成。';
  static const cloudAttachBody = '新版本使用云账户。现有条目、账户标识和密钥全部保留；请使用当前主密码完成接入。若云端同邮箱属于不同账户，不会覆盖或合并。';
  static const javaServiceLabel = 'Java 服务：{url}';
  static const cloudVerifyAndFinish = '验证并完成云注册';
  static const exportBackupFirst = '先导出本机加密备份';
  static const lockAndContinueLater = '锁定并稍后继续';
  static const wipeAndReloginAction = '清除本机数据后重新登录';
  static const cloudZeroKnowledgeNote = '密码、Secret Key 和条目明文不会上传。完成云注册后，条目仍可离线读写，联网自动同步密文。';

  // ───────── 生成器 ─────────

  static const regenerate = '重新生成';
  static const generatorSubtitle = '使用系统级 CSPRNG 生成，结果只存在于本机内存。';
  static const generatePassword = '生成密码';
  static const lengthLabel = '长度';
  static const excludeAmbiguous = '排除易混字符';
  static const wordCountLabel = '词数';
  static const separatorSpace = '空格';
  static const capitalizeFirst = '首字母大写';
  static const includeDigits = '含数字';
  static const useThisPassword = '使用此密码';
  static const randomPasswordTab = '随机密码';
  static const passphraseTab = '口令短语';

  // ───────── 部件与扫码 ─────────

  static const sidebarTagline = '能打开你保险库的，\n只有一个人——';
  static const sidebarTaglineHighlight = '你自己。';
  static const authAsideBody = '所有数据在这台设备上加密后才会离开。服务器只保存密文——即使被整库拖走，也解不开任何一个密码。';
  static const featureZeroKnowledge = '零知识';
  static const featureZeroKnowledgeBody = '主密码从不上传，服务器无法重置，也无法窥视。';
  static const featureTwoFactorDerivation = '双因子派生';
  static const featureTwoFactorDerivationBody = 'Argon2id(主密码) × 240-bit Secret Key，离线爆破无从下手。';
  static const featureItemEncryption = '条目级加密';
  static const featureItemEncryptionBody = 'AES-256-GCM，每个条目、每个版本独立密钥与随机 IV。';
  static const authAsideFooter = 'VaultOne · 本地优先的数字资产保险库';
  static const clipboardCopiedToast = '已复制{label}';
  static const clipboardClearCountdown = '{seconds} 秒后从剪贴板清除 · 不进入剪贴板历史';
  static const clearNow = '立即清除';
  static const qrScanTitle = '扫描两步验证二维码';
  static const qrScanHint = '将网站提供的二维码置于框内';

  // ───────── 备份与导出（对话框 / 引导页共用） ─────────

  static const saveFailedDisk = '保存失败，请检查目录权限与可用空间。';
  static const backupCardSavedTo = '备份卡已保存到 {path}';
  static const backupCardFailed = '备份卡导出失败，请检查目录权限与可用空间。';
  static const kitSavedTo = '恢复套件已保存到 {path}';
  static const keyVerifyMismatch = '与本机保存的 Secret Key 不一致。请对照恢复套件逐组核对，注意易混字符 I/L/O 与数字 1/0。';
  static const verifyIncomplete = '核对未完成，请稍后重试。';
  static const keyVerifyOk = 'Secret Key 与本机保存的逐字节一致；恢复码格式有效。';
  static const recoveryCodeInvalid = '恢复码格式不正确，应为 R1- 开头、13 组 Crockford Base32。';
  static const lastLocalBackup = '最近本机备份';
  static const neverRecorded = '从未记录';
  static const cloudBackupHistory = '云端备份历史';
  static const cloudBackupHistoryNone = '暂无（服务端备份记录端点未实现）';
  static const backupManagerBody = '本机只保存「最近一次导出」这一事实，不保存文件路径与内容。恢复套件与备份卡都可以在这里重新导出；为避免他人趁保险库未锁定时拿到凭据，重新导出前需要你重新提供恢复材料。';
  static const verifyMaterials = '恢复材料核对';
  static const verifyPassed = '核对通过';
  static const reExport = '重新导出';
  static const recoveryKitPdfShort = '恢复套件（PDF）';
  static const backupCardShort = '备份卡（PNG 700×900）';
  static const viewSecretKey = '查看 Secret Key';
  static const backupCredentialWarning = '恢复套件与备份卡都等价于明文凭据，导出后请按同等级别保管：打印或存入离线介质，不要放进网盘、邮箱或聊天记录。';

  // ───────── 安全中心 ─────────

  static const securityCenterSubtitle = '所有分析均在本机完成。泄露检测只发送密码 SHA-1 的前 5 位，服务端无法得知你的密码。';
  static const auditFailed = '审计失败：{reason}';
  static const breachCheckFailed = '检测失败：{reason}';
  static const statusGood = '状态良好';
  static const statusNeedsWork = '有待加强';
  static const statusActNow = '需要立即处理';
  static const noPasswordItems = '还没有带密码的条目。';
  static const riskSummary = '{total} 个带密码的条目中，{problems} 个存在风险。';
  static const weakPasswords = '弱密码';
  static const reusedPasswords = '重复使用';
  static const breachedPasswords = '已泄露';
  static const twoFactorCoverage = '两步验证';

  // ---------- 安全体检（§5.2）----------
  static const healthTitle = '安全体检';
  static const healthScore = '健康分';
  static const healthCheckedAt = '最近检查：{time}';
  static const healthExpired = '报告已过期，建议重新体检';
  static const healthRerun = '重新体检';
  static const healthDimensionTitle = '维度得分';
  static const healthDimensionSkipped = '本次跳过';
  static const healthStatsTitle = '扫描统计';
  static const healthScanned = '已扫描密码';
  static const healthPasswordFields = '密码字段';
  static const healthUnreadable = '不可读条目';
  static const healthBreachLabel = '泄露检测';
  static const healthBreachNotRun = '未运行';
  static const healthBreachOk = '正常';
  static const healthBreachUnavailable = '不可用';
  static const healthBreachSkipped = '已跳过';
  static const healthFindings = '发现项';
  static const healthNoFindings = '没有发现问题，保持下去。';
  static const healthSnooze = '忽略 7 天';
  static const healthSnoozed = '已忽略 {n} 项';
  static const healthOpenItem = '打开条目';
  static const healthActionRun = '去运行';
  static const healthActionEnable = '去开启';
  static const healthActionGeneral = '打开通用设置';
  static const healthActionSystem = '打开系统设置';
  static const healthSeverityLow = '低危';
  static const healthSeverityMedium = '中危';
  static const healthSeverityHigh = '高危';
  static const healthSeverityCritical = '严重风险';
  static const healthDimBreach = '泄露';
  static const healthDimReuse = '密码复用';
  static const healthDimStale = '长期未更新';
  static const healthDimEnvironment = '设备环境';
  static const healthDimSettings = '设置项';
  static const healthDimScore = '扣 {used} / 上限 {cap}';

  // ---------- 安全总览（§5.1）----------
  static const healthChecklist = '任务清单';
  static const healthChecklistProgress = '已完成 {done} / {total}';
  static const healthRisks = '风险项';
  static const healthRiskNone = '没有风险项。';
  static const healthGrid = '快捷入口';

  // ---------- 首页板块自定义（§3.6 / §3.11）----------
  static const sidebarLayoutTitle = '首页板块';
  static const sidebarLayoutSubtitle = '调整侧栏分区的顺序与显隐。设置只保存在本机，不同步——不同设备屏幕大小不同，同步反而两边都不顺手。';
  static const sidebarMoveUp = '上移';
  static const sidebarMoveDown = '下移';
  static const sidebarShow = '在侧栏显示';
  static const sidebarKeepOne = '至少保留一个分区，否则侧栏会变成空白';
  static const sidebarResetLayout = '恢复默认布局';

  // ---------- 解锁与安全 / 通用设置补全（§5.4 / §8.3）----------
  static const lockOnExit = '退出即锁定';
  static const lockOnExitSubtitle = '关闭窗口（隐藏到托盘）时立即锁定保险库。';
  static const maskPasswords = '默认隐藏密码';
  static const maskPasswordsSubtitle = '详情页默认以圆点显示密码，需要时再点眼睛查看。';
  static const screenshotProtection = '截图保护';
  static const screenshotProtectionSubtitle = '阻止本应用窗口被截屏与录屏捕获。';
  static const screenshotUnsupported = '当前平台不支持截图保护';
  static const clipboardDisabled = '不自动清空';

  // ---------- 导入预览与字段映射（§3.7）----------
  static const importPreviewTitle = '导入预览';
  static const importPreviewSource = '识别来源：{source}';
  static const importPreviewCounts = '共 {rows} 行，可导入 {items} 条，跳过 {skipped} 行';
  static const importPreviewTruncated = '只显示前 {n} 行';
  static const importPreviewWarnings = '解析警告';
  static const importPreviewMapping = '字段映射';
  static const importPreviewUnmapped = '不导入';
  static const importPreviewColumn = '第 {n} 列';
  static const importPreviewStrategy = '同名条目';
  static const importStrategySkip = '保留现有的';
  static const importStrategyOverwrite = '用导入的内容覆盖';
  static const importStrategyKeepBoth = '两条都保留';
  static const importPreviewConfirm = '开始导入';
  static const importPreviewEmpty = '这份文件里没有可导入的条目';
  static const importUpdated = '，覆盖 {n} 条';

  // ---------- 标签与分类管理（§3.6）----------
  static const taxonomyManage = '标签与分类管理';
  static const taxonomyManageSubtitle = '重命名或清理标签与分类；只改分类归属，不会删除条目。';
  static const taxonomyRename = '重命名';
  static const taxonomyRenameTagTitle = '重命名标签';
  static const taxonomyRenameCategoryTitle = '重命名分类';
  static const taxonomyClearCategoryTitle = '清空分类';
  static const taxonomyNewName = '新名称';
  static const taxonomyTagHint = '不区分大小写；改成已存在的标签等于合并。';
  static const taxonomyCategoryHint = '子分类会一起移动；改成已存在的分类等于合并。';
  static const taxonomyClearBody = '将清空「{name}」及其子分类的归属，共 {n} 条条目。条目本身不会被删除。';
  static const taxonomyDeleteTagBody = '将从 {n} 条条目上移除标签「{name}」。条目本身不会被删除。';
  static const taxonomyAffected = '已更新 {n} 条条目';
  static const taxonomyNoTags = '还没有任何标签';
  static const taxonomyNoCategories = '还没有任何分类';

  // ---------- 条目子列表页（§2.3 / §3.6）----------
  static const subListTagTitle = '标签：{name}';
  static const subListCategoryTitle = '分类：{name}';
  static const subListCount = '共 {n} 条';
  static const subListViewItems = '查看条目';
  static const subListOpenInPage = '在新页面打开';

  // ---------- 动态字段类型（§3.1）----------
  static const fieldType = '字段类型';
  static const fieldKindText = '文本';
  static const fieldKindDate = '日期';
  static const fieldKindImage = '图片';
  static const fieldDateHint = '年-月-日，例如 2026-10-02';
  static const fieldImageHint = '本地路径或 https:// 地址';
  static const fieldPickDate = '选择日期';
  static const fieldPickImage = '选择图片';
  static const pickImageUnavailable = '当前平台没有文件选择器，请手动填写图片地址';
  static const fieldDateInvalid = '日期格式应为 年-月-日';
  static const fieldImageMissing = '请填写图片地址';
  static const imageLoadFailed = '图片无法加载';

  // ---------- 导入导出历史（§3.7）----------
  static const transferHistory = '导入导出历史';
  static const transferHistorySubtitle = '只记在这台设备上，以保险库密钥加密存放，不参与同步。';
  static const transferImport = '导入';
  static const transferNoHistory = '还没有导入导出记录';
  static const transferClear = '清空历史';
  static const transferClearConfirm = '清空本机导入导出历史？条目数据不受影响。';
  static const transferSource = '来源：{name}';
  static const transferNoSource = '未记录来源';
  static const transferBytes = '{n} 字节';
  static const transferCounts = '新增 {added}，覆盖 {updated}，重复 {duplicates}，跳过 {skipped}';

  // ---------- 账户资料（§8.1 / §8.2）----------
  static const profileEdit = '编辑资料';
  static const profileNickname = '昵称';
  static const profileAvatar = '头像地址';
  static const profileNoNickname = '未设置昵称';
  static const profileSaved = '资料已更新';
  static const profileOffline = '离线：显示的是本机缓存';
  static const profileNicknameHint = '最多 32 个字符，可留空';
  static const profileAvatarHint = 'http 或 https 链接，可留空';
  static const profileCreatedAt = '注册时间：{time}';
  static const inviteMine = '我的邀请码';
  static const inviteNone = '尚未生成';
  static const inviteCopy = '复制邀请码';
  static const inviteCopied = '邀请码已复制';
  static const inviteBind = '填写邀请码';
  static const inviteBindTitle = '填写邀请人的邀请码';
  static const inviteBindHint = '12 位字母数字，可带空格或连字符';
  static const inviteBindDone = '已绑定邀请人';
  static const inviteBindNote = '一次性绑定，绑定后不可更改。';

  // ---------- 备份提醒（§8.3）----------
  static const backupNow = '立即备份';
  static const backupReminder = '备份提醒';
  static const backupReminderHint = '关掉后体检清单里不再出现备份项。';

  static const breachCheck = '泄露密码检测';
  static const breachCheckSubtitle = '对照 Have I Been Pwned 数据库（k-匿名），需要联网。';
  static const breachCheckDone = '检测完成：{count} 个条目的密码出现在公开泄露数据中。';
  static const startCheck = '开始检测';
  static const recheck = '重新检测';
  static const breachedAdvice = '这些密码出现在公开泄露库中，攻击者会优先尝试，请立即更换。';
  static const breachTimes = '出现 {count} 次';
  static const weakAdvice = '容易被猜测或字典攻击破解。';
  static const strengthVeryWeak = '极弱';
  static const strengthWeak = '弱';
  static const strengthFair = '一般';
  static const strengthStrong = '强';
  static const strengthVeryStrong = '很强';
  static const reusedAdvice = '一个网站泄露，会连带其他网站失守。';
  static const reusedWith = '与 {count} 个条目相同';
  static const noProblems = '没有发现问题。保持下去。';
  static const securityScore = '安全评分';

  // ───────── 同步冲突 ─────────

  static const conflictLoadFailed = '暂时无法读取冲突，请重试';
  static const conflictSavedLocal = '选择已保存到本机，等待同步。远端确认前仍可能产生新的冲突。';
  static const conflictCandidateChanged = '候选已发生变化，请检查刷新后的版本并重新选择。';
  static const pickConflictHint = '选择一个冲突查看双方版本';
  static const showHistoryToggle = '显示历史记录';
  static const noConflictRecords = '暂无冲突记录';
  static const noPendingConflicts = '没有待处理的冲突';
  static const untitledItem = '未命名条目';
  static const refreshList = '刷新列表';
  static const backToConflictList = '返回冲突列表';
  static const pickAConflict = '请选择一个冲突';
  static const candidateExpired = '候选已过期，不能提交旧选择。请先刷新候选。';
  static const resolutionQueued = '解决方案已在本地排队，等待同步。这里不表示已经同步成功。';
  static const historyReadOnly = '历史记录，仅供查看，不能再次提交。';
  static const refreshCandidate = '刷新候选';
  static const hideSensitive = '隐藏敏感内容';
  static const showSensitive = '显示敏感内容';
  static const conflictWholeItemOnly = '条目类型或解决方案存在冲突，只能整条保留一方。';
  static const keepWholeLocal = '保留整条本地';
  static const keepWholeRemote = '保留整条远端';
  static const wholeItemAdvice = '整条保留会采用该方的全部内容；下方可比较所有字段。';
  static const submitFieldChoices = '提交逐字段选择（{chosen}/{total}）';
  static const sensitiveHidden = '敏感内容已隐藏';
  static const deletedYes = '已删除';
  static const deletedNo = '未删除';
  static const deletedUnknown = '未知（旧基线未记录）';
  static const emptyValue = '（空）';
  static const commonBase = '共同基础 · v{revision}';
  static const adoptSide = '采用{side}';
  static const sideRemote = '远端';
  static const sideWithRevision = '{side} · v{revision}';
  static const fieldConflictSuffix = '{field} · 冲突';
  static const adoptFieldSide = '采用{side}{field}';

  // ───────── 冲突字段与状态 ─────────

  static const conflictFieldKind = '条目类型';
  static const conflictFieldDeleted = '删除状态';
  static const conflictFieldResolution = '解决方案';
  static const conflictStatusPending = '待处理';
  static const conflictStatusAwaitingSync = '等待同步';
  static const conflictStatusResolved = '已解决';
  static const conflictStatusSuperseded = '已被替代';
  static const conflictCandidateStale = '候选已过期';

  // ───────── 浏览器扩展配对 ─────────

  static const pairingTitle = '连接浏览器扩展？';
  static const pairingBody = '「{name}」中的 VaultOne 扩展请求连接。请确认扩展弹窗中显示的配对码与下方一致；不一致或不是你发起的，请拒绝。';
  static const rejectAction = '拒绝';
  static const allowPairing = '配对码一致，允许连接';

  // ───────── 意见反馈 ─────────

  static const feedbackBug = '问题反馈';
  static const feedbackSuggestion = '功能建议';
  static const feedbackOther = '其他';
  static const feedbackStatusInProgress = '处理中';
  static const feedbackStatusResolved = '已处理';
  static const feedbackStatusUnknown = '无法识别反馈状态';
  static const feedbackClose = '关闭反馈';
  static const refreshAction = '刷新';
  static const feedbackExpired = '反馈页面已失效，请解锁并重新进入。';
  static const feedbackWriteTab = '写反馈';
  static const feedbackHistoryTab = '历史记录';
  static const feedbackDraftNotice = '关闭或锁定将清除本页内容，但不会撤回已发送的反馈。';
  static const feedbackConsentTitle = '客服可以读取反馈';
  static const feedbackConsentBody = '正文和可选联系方式会发送给客服，不属于零知识保险库内容。';
  static const feedbackNoSecrets = '请勿填写密码、Secret Key、恢复码或保险库内容。';
  static const feedbackNoAutoAttach = '不会自动附带邮箱、日志、设备诊断或剪贴板。';
  static const feedbackSubmitted = '提交成功';
  static const feedbackWriteAnother = '再写一条';
  static const feedbackCategory = '反馈类型';
  static const feedbackBody = '反馈正文';
  static const feedbackBodyHint = '描述遇到的问题或建议，不要填写敏感信息';
  static const feedbackBodyRequired = '请填写反馈正文';
  static const feedbackBodyTooLong = '正文最多 4000 个 UTF-16 代码单元';
  static const feedbackContact = '联系方式（可选）';
  static const feedbackContactTooLong = '联系方式最多 200 个 UTF-16 代码单元';
  static const feedbackConsentAck = '我理解正文和联系方式可被客服读取，并同意发送。';
  static const feedbackConsentRequired = '勾选同意后才能提交。';
  static const feedbackUnconfirmed = '尚未确认提交结果，反馈可能已保存。原请求和编号已保留，不可编辑；请原样重试，或先查看历史确认。';
  static const feedbackSubmitting = '正在提交…';
  static const feedbackRetryAsIs = '原样重试';
  static const feedbackSubmit = '提交反馈';
  static const feedbackDiscard = '放弃本次提交';
  static const feedbackClearDraft = '清空草稿';
  static const feedbackDiscardWarning = '本次反馈可能已经提交。放弃只清除本页请求，不会删除服务器记录；建议先看历史，避免重复提交。';
  static const feedbackCheckHistoryFirst = '先看历史';
  static const feedbackConfirmDiscard = '确认放弃本次提交';
  static const feedbackCancelDiscard = '取消放弃';
  static const feedbackRetryHistory = '重试读取历史';
  static const feedbackHistoryEmpty = '暂无反馈记录。你提交的反馈会显示在这里。';
  static const feedbackLoadEarlier = '加载更早记录';
  static const feedbackBackToHistory = '返回历史';
  static const feedbackRetryDetail = '重试读取详情';
  static const feedbackSubmittedAt = '提交于 {time}';
  static const feedbackIdLabel = '反馈编号：{id}';
  static const feedbackAccountLabel = '账户编号：{id}';
  static const feedbackSubmittedBody = '提交正文';
  static const feedbackContactLabel = '联系方式';
  static const feedbackLatestReply = '客服最近回复';
  static const feedbackNoReply = '暂时没有回复。';
  static const feedbackNetworkError = '网络连接异常，请检查连接后重试。';
  static const feedbackSessionExpired = '云会话已失效，请重新登录后再试。';
  static const feedbackLocked = '保险库已锁定，请解锁后重新进入。';
  static const feedbackNotConnected = '请先在设置中连接云服务，再使用反馈。';
  static const feedbackPrivacyRequired = '请先阅读并同意隐私政策与用户协议。';
  static const feedbackUnsupported = '此服务器暂不支持反馈功能，请联系支持。';
  static const feedbackForbidden = '当前设备无权访问反馈，请检查设备授权。';
  static const feedbackInvalid = '反馈格式不符合要求，请检查类型和长度。';
  static const feedbackDuplicate = '此提交编号已被使用，请先查看历史确认结果。';
  static const feedbackNotFound = '反馈不存在或已到期，请刷新历史记录。';
  static const feedbackRateLimited = '提交过于频繁或已达数量上限，请稍后再试。';
  static const feedbackUnavailable = '反馈服务暂时不可用，请稍后重试。';
  static const feedbackGenericError = '暂时无法完成操作，请稍后重试。';

  // ───────── Android 自动填充 ─────────

  static const autofillUnknownApp = '未知应用';
  static const autofillSetupFirst = '请先打开 VaultOne 完成保险库设置，再使用自动填充。';
  static const autofillFillTo = '填充到 {source}';
  static const autofillMatchedSite = '与此网站匹配';
  static const autofillAppNoMatch = '应用内的登录表单不做自动匹配，请确认所选条目属于该应用。';
  static const autofillAllLogins = '全部登录条目';
  static const autofillOtherItems = '其他条目';
  static const autofillNoLogins = '没有找到登录条目';
  static const autofillNoUsername = '（无用户名）';
  static const autofillSaveFailed = '保存失败';
  static const autofillSaveToVault = '保存到 VaultOne？';
  static const autofillUpdatePassword = '更新「{title}」的密码？';
  static const autofillUpdate = '更新';
  static const autofillDontSave = '不保存';

  // ───────── 条目模板名称与说明 ─────────
  //
  // 模板的**名称 / 说明 / 标题提示**属于界面文案，随语言切换；
  // 模板预置的**自定义字段名与默认标题**属于条目内容（会存入保险库并同步），
  // 保持中文源文本不变，与「条目内容不被翻译」的承诺一致。

  static const tplLoginWebsite = '网站账号';
  static const tplLoginWebsiteDesc = '用户名、密码、网址与两步验证';
  static const tplLoginApi = 'API / 开发者账号';
  static const tplLoginApiDesc = '登录凭据与 API Key、Secret 等敏感字段';
  static const tplLoginApiHint = '例如：OpenAI API';
  static const tplLoginDevice = '服务器 / 设备';
  static const tplLoginDeviceDesc = '主机、端口、账号与设备凭据';
  static const tplLoginDeviceHint = '例如：生产服务器';
  static const tplCardBank = '银行卡';
  static const tplCardBankDesc = '卡号、有效期、安全码与 PIN';
  static const tplCardMembership = '会员 / 积分卡';
  static const tplCardMembershipDesc = '会员号、等级与积分信息';
  static const tplCardMembershipHint = '例如：航空公司会员卡';
  static const tplNoteSecureDesc = '自由文本，适合恢复码与配置说明';
  static const tplNoteApi = '服务器 / API 密钥';
  static const tplNoteApiDesc = '主机、账号、密钥与备注';
  static const tplNoteApiHint = '例如：生产 API 密钥';
  static const tplNoteWifi = 'Wi-Fi 信息';
  static const tplNoteWifiDesc = '网络名称、密码与安全类型';
  static const tplNoteWifiHint = '例如：家里 Wi-Fi';
  static const tplIdentityPersonal = '个人信息';
  static const tplIdentityPersonalDesc = '姓名、邮箱、电话、证件号与地址';
  static const tplIdentityWork = '公司 / 工作身份';
  static const tplIdentityWorkDesc = '公司、职位、工号与联系方式';
  static const tplIdentityWorkHint = '例如：公司邮箱身份';

  // ───────── 内核 / 状态层抛出的提示 ─────────
  //
  // 这些文本由 Rust 桥接层与状态层构造后直接展示给用户。文案表以原文为键，
  // 展示点统一经 `context.tr(e.message)` 取词：已登记则按当前语言输出，
  // 未登记（例如内核新增的 code）则原样回退中文，不会显示空白。

  static const coreVaultLocked = '保险库已锁定，请重新解锁后操作';
  static const corePrivacyRequired = '请先阅读并同意隐私政策与用户协议';
  static const coreServerMismatch = '本机账户绑定的服务器与 Java 配置不同，请先重新验证并确认连接';
  static const configProdHttpsRequired = '发布构建需要显式配置有效的 HTTPS Java 服务地址';
  static const configServerInvalid = '服务器地址无效；真机 HTTP 调试需开启 VAULTONE_ALLOW_LAN_HTTP 并指定私网 IP';
  static const accountCancelled = '账户操作已取消';
  static const secureStorageIncomplete = '安全存储或注册未完成，请保留恢复材料后重试';
  static const unlockDraftFirst = '请先解锁账户草稿';
  static const finishCloudFirst = '请先完成云账户注册';
  static const missingSecretKey = '本设备未保存 Secret Key，请输入 Recovery Kit 上的 Secret Key';
  static const unlockVaultPrompt = '解锁 VaultOne 保险库';
  static const changePasswordUnconfirmed = '改密结果尚未确认。旧本机密码仍可解锁，请使用相同的新密码重试；其他设备可能已采用新密码。';
  static const reverifyKeepData = '请重新验证 Java 服务连接；原数据与待同步条目已保留';
  static const reverifyNoRequest = '请重新验证 Java 服务连接；不会自动向旧服务器发送请求';
  static const accountDeletedLocally = '云账户已注销。本机加密数据保留，可先导出备份或明确清除本机数据。';

  // ───────── 桌面托盘 ─────────

  static const trayOpen = '打开 VaultOne';
  static const trayQuickSearch = '快速搜索';
  static const trayQuit = '退出';

  // ───────── 恢复套件 PDF 与备份卡图 ─────────
  //
  // 这两份交付物是**位图与 PDF**，文字在渲染时固化，不随界面语言在运行时切换：
  // 渲染入口接收 `AppLanguage`，同时决定文案与内嵌字体（简中/英文用 Noto Sans SC，
  // 繁中用 Noto Sans TC）。两份材料内容高度重叠，同文案共用同一常量，避免分叉。

  static const docExportedViaPanel = '已通过系统面板导出';
  static const docSecretKeyLabel = 'SECRET KEY · 设备密钥';
  static const docRecoveryCodeLabel = 'RECOVERY CODE · 恢复码';
  static const docEmailLabel = '账户邮箱 / EMAIL';
  static const docMasterPasswordLabel = '主密码（可选，手写）/ MASTER PASSWORD';
  static const docLoginNeedsBoth = '在新设备登录时，需要同时输入「主密码」与「Secret Key」。';
  static const docGeneratedFooter = '生成于 {date} · 能打开你保险库的，只有你自己。';

  static const kitDocTitle = 'Recovery Kit · 恢复套件';
  static const kitLead = '这是找回你保险库的唯一凭据。VaultOne 采用零知识架构，我们无法重置你的主密码，也无法替你恢复数据。请打印或离线保存本文件，不要存放在网盘、邮箱或聊天记录中。';
  static const kitResetHint = '忘记主密码时，可用「Secret Key + 恢复码」重设主密码；重设后此恢复码立即作废，请保存新的 Recovery Kit。';
  static const kitAccountId = '账户 ID：{id}';
  static const kitFileName = 'VaultOne-Recovery-Kit.pdf';
  static const kitTypeGroup = 'PDF';

  static const cardDocBadge = 'RECOVERY KIT · 备份卡';
  static const cardDocTitle = '请离线保管这张卡';
  static const cardLead = '它是找回你保险库的唯一凭据。VaultOne 采用零知识架构，无法重置你的主密码，也无法替你恢复数据。请打印成实体卡或存入离线介质，不要放进网盘、邮箱或聊天记录。';
  static const cardResetHint = '忘记主密码时，可用「Secret Key + 恢复码」重设主密码；重设后此恢复码立即作废，请保存新的恢复套件。';
  static const cardFileName = 'VaultOne-备份卡.png';
  static const cardTypeGroup = 'PNG 图片';
  static const cardEncodeFailed = '备份卡编码失败';

  // ───────── 条目字段与操作 ─────────

  static const moveToTrash = '移入回收站';
  static const moveToTrashConfirmTitle = '移入回收站？';
  static const moveToTrashConfirmBody = '「{title}」将移入回收站，可随时恢复。';
  static const movedToTrashTitle = '已移入回收站';
  static const movedToTrashBody = '「{title}」已移入回收站，可随时恢复。';
  static const purgeConfirmTitle = '彻底删除？';
  static const purgeConfirmBody = '「{title}」将从本机永久删除，无法恢复。已同步到云端的数据不会在其他设备上被抹除。';
  static const purgeAction = '彻底删除';
  static const purgedTitle = '已彻底删除「{title}」';
  static const fieldUsername = '用户名';
  static const fieldPassword = '密码';
  static const fieldTotp = '验证码';
  static const urlMatchSuffix = '{label}匹配';
  static const urlFieldLabel = '网站 · {label}匹配';
  static const fieldWebsite = '网址';
  static const openInBrowser = '在浏览器中打开';
  static const fieldNotes = '备注';

  // ───────── 标签与分类（计划书 §3.6） ─────────

  static const groupTaxonomy = '标签与分类';
  static const tagLabel = '标签';
  static const tagInputHint = '输入标签后回车';
  static const tagAdd = '添加标签';
  static const tagLimitReached = '最多 {count} 个标签';
  static const tagRemoveTooltip = '移除标签「{tag}」';
  static const categoryHint = '例如：工作 / 个人 / 金融';
  static const filterByTagTitle = '按标签筛选';
  static const filterByCategoryTitle = '按分类筛选';
  static const clearFilter = '清除筛选';
  static const noTagsInVault = '还没有标签';
  static const noCategory = '未分类';
  static const allTags = '全部标签';
  static const groupCategories = '分组';
  static const noCategoriesYet = '暂无分类';
  static const categoryPathHint = '用 / 分隔层级，例如：工作/生产';
  static const categoryTreeTooltip = '层级分类，选中后连同子分类一起显示';
  static const fieldCardholder = '持卡人';
  static const fieldCardNumber = '卡号';
  static const fieldExpiry = '有效期';
  static const fieldCvv = '安全码';
  static const fieldPin = 'PIN';
  static const fieldFullName = '姓名';
  static const fieldPhone = '电话';
  static const fieldIdNumber = '证件号';
  static const fieldAddress = '地址';
  static const fieldCompany = '公司';
  static const fieldEmail = '邮箱';
  static const customFields = '自定义字段';
  static const passwordHistory = '密码历史';
  static const historyPassword = '历史密码';
  static const copyTotp = '复制验证码';
  static const labelEncrypted = '加密';
  static const labelHide = '隐藏';
  static const purgeErrorUnsynced = '该条目尚未同步到云端，请先完成同步后再彻底删除。';
  static const purgeErrorNotFound = '条目已不存在，请刷新回收站。';
  static const purgeErrorLocked = '保险库已锁定，请解锁后重试。';
  static const purgeErrorGeneric = '暂时无法彻底删除，请稍后重试。';
  static const restoreAction = '恢复';
  static const restoredTitle = '已恢复「{title}」';
  static const unfavorite = '取消收藏';
  static const editAction = '编辑';
  static const labelCreated = '创建';
  static const labelUpdated = '修改';
  static const labelRevision = '版本';
  static const labelKind = '类型';
  static const labelReveal = '显示';
  static const totpOnce = '一次性验证码';
  static const totpCountdown = '剩余 {seconds} 秒';
  static const cardExpired = '已过期';
  static const cardExpiresSoon = '即将过期';

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
    never: '從未',
    accountIdLabel: '帳戶 ID  {id}',
    keyDerivation: '金鑰派生',
    itemCountTag: '{count} 個項目',
    secretKeyRowSubtitle: '儲存在本機系統鑰匙圈中。查看或重新匯出恢復材料前，需要重新輸入 Secret Key 與恢復碼做逐位元組核對。',
    verifyAndView: '核對並查看',
    changeMasterPassword: '修改主密碼',
    changeMasterPasswordSubtitle: '只重新封裝保險庫金鑰，項目無需重新加密，秒級完成。',
    masterPasswordUpdated: '主密碼已更新，其他裝置同步後需使用新主密碼解鎖',
    newPasswordTooWeak: '新主密碼強度不足',
    currentMasterPassword: '目前主密碼',
    updateMasterPassword: '更新主密碼',
    backupKindRecoveryKit: '恢復套件 PDF',
    backupKindCard: '備份卡 PNG',
    backupKindWljbak: '加密備份 .wljbak',
    backupKindCsv: '明文 CSV',
    backupNever: '本機尚未記錄任何備份匯出。請先匯出恢復套件，並把它列印或存進離線媒體。',
    backupLast: '最近一次：{time}（{kind}）。本機只記錄時間與方式，不儲存檔案路徑與內容。',
    backupStatus: '備份狀態',
    backupCloudNote: '雲端備份歷史需要伺服器端點，尚未實作；這裡不把本機記錄當作雲端已備份。',
    backupMissing: '未備份',
    backupPresent: '已備份',
    recoveryKitAndCard: '恢復套件與備份卡',
    recoveryKitAndCardSubtitle: '重新匯出 A4 恢復套件 PDF，或 700×900（2x 匯出）的備份卡 PNG。兩者都等同於明文憑據，匯出前需要重新輸入 Secret Key 與恢復碼做核對。',
    manageAction: '管理',
    biometricUnlock: '生物辨識解鎖',
    biometricUnlockSubtitle: '使用 Windows Hello / Touch ID / Face ID / 指紋快速解鎖。快速解鎖金鑰儲存在系統鑰匙圈，修改主密碼後自動失效。',
    biometricEnable: '啟用生物辨識解鎖',
    biometricDisable: '關閉生物辨識解鎖',
    autoLock: '自動鎖定',
    autoLockSubtitle: '無操作一段時間後鎖定保險庫並清空記憶體中的金鑰。',
    minutes: '{n} 分鐘',
    lockOnMinimize: '切到背景 / 最小化時鎖定',
    clipboardAutoClear: '剪貼簿自動清除',
    clipboardAutoClearSubtitle: '複製密碼後到期清空；桌面端寫入時排除剪貼簿歷史與雲端同步。',
    seconds: '{n} 秒',
    cloudSetupPending: '雲端帳戶尚未完成接入',
    cloudSetupPendingBody: '重新解鎖後完成 Java 雲端註冊。現有項目保留，不提供獨立的純本機帳戶模式。',
    syncing: '同步中…',
    syncFailed: '同步失敗：{reason}',
    sessionExpired: '登入已過期，請重新驗證',
    autoSync: '項目自動同步',
    deviceSummary: '本裝置：{device} · 上次同步 {time} · 待上傳 {pending}',
    revalidate: '重新驗證',
    reconnectSync: '重新連線同步服務',
    reconnected: '已重新連線',
    syncNow: '立即同步',
    mergedItems: '已合併 {n} 個在多台裝置上同時修改的項目',
    deviceManagement: '裝置管理',
    signOutCloudLock: '登出雲端並鎖定',
    signOutCloudTitle: '登出雲端？',
    signOutCloudBody: '連線撤銷目前工作階段並鎖定本機；本機項目、待同步修改與伺服器綁定保留。',
    signOutAndLock: '登出並鎖定',
    securityLog: '安全日誌',
    deviceManagementSubtitle: '新裝置登入需經電子郵件驗證碼或在此批准。撤銷後該裝置工作階段立即失效。',
    deviceThis: '本機',
    deviceRevoked: '已撤銷',
    devicePending: '待批准',
    deviceLine: '{platform} · 新增於 {created} · 最近活動 {seen}',
    approveAction: '批准',
    approvedAction: '已批准',
    revokeAction: '撤銷',
    revokeDeviceTitle: '撤銷裝置「{name}」？',
    revokeDeviceBody: '該裝置將被立即登出且無法再同步。',
    auditSignInOk: '登入成功',
    auditSignInFail: '登入失敗',
    auditDeviceRequest: '新裝置請求登入',
    auditDeviceApproved: '裝置已批准',
    auditDeviceRevoked: '裝置已撤銷',
    auditPasswordChanged: '主密碼已修改',
    auditRecoveryUsed: '使用 Recovery Kit 恢復',
    auditRecoveryFail: '恢復碼驗證失敗',
    theme: '主題',
    themeSystem: '跟隨系統',
    themeLight: '淺色',
    themeDark: '深色',
    compareConflicts: '比較並裁決衝突',
    compareConflictsSubtitle: '衝突雙方版本在本機加密儲存。裁決後等待同步確認；有未完成衝突時不能匯出，以免漏掉另一方內容。',
    viewConflicts: '查看衝突',
    importDone: '匯入完成',
    importSummary: '來源：{source}\n新增 {added} 筆{duplicates}{skipped}。\n\n匯出檔案是明文，請立即從磁碟與回收筒中徹底刪除。',
    importBackupSummary: '新增 {added} 筆{duplicates}{skipped}。',
    importDuplicates: '，{n} 筆與現有項目重複已略過',
    importSkipped: '，{n} 筆無法識別',
    gotIt: '知道了',
    notUtf8: '檔案不是 UTF-8 文字，請用原軟體重新匯出為 CSV',
    vaultoneBackup: 'VaultOne 備份',
    backupSaved: '已儲存加密備份（{bytes} 位元組）到 {path}',
    backupSaveFailed: '備份儲存失敗，請檢查目錄權限與可用空間。若留下不完整檔案，請勿用於恢復。',
    csvConfirmTitle: '匯出明文 CSV？',
    csvConfirmBody: 'CSV 不加密，任何拿到檔案的人都能看到密碼與 TOTP 種子。\n\n'
        'CSV 不是完整備份：僅匯出標題、首個網址、使用者名稱、密碼、備註、TOTP 種子、收藏與類型；'
        '不保留卡片/身分專用欄位、自訂欄位、其他網址與比對規則、密碼歷史及完整 TOTP 參數。'
        '不含回收筒，不能用它無損恢復保險庫。完整項目備份請選 .wljbak。\n\n'
        '匯出後請妥善保管，遷移完成後從磁碟與回收筒徹底刪除；不要用試算表軟體開啟不可信內容。',
    stillExport: '仍要匯出',
    csvSaved: '已儲存有損 CSV（{bytes} 位元組）到 {path}；請核對遷移結果，這不是完整備份。',
    csvSaveFailed: 'CSV 儲存失敗，請檢查目錄權限與可用空間，並清理可能留下的明文檔案。',
    importFromOthers: '從其他密碼管理器匯入',
    importFromOthersSubtitle: '支援 Chrome / Edge / Firefox / Bitwarden / LastPass / 1Password 匯出的 CSV 與 1PIF。檔案只在本機解析，隨即加密入庫；重複項目自動略過。',
    importing: '匯入中…',
    chooseFile: '選擇檔案',
    exportEncryptedBackup: '匯出加密備份',
    exportEncryptedBackupSubtitle: '匯出本帳戶的 .wljbak 項目級備份，不含回收筒，不是資料庫快照。需先恢復同一帳戶及其 Vault Key，再匯入；僅持有檔案或新建同名帳戶無法恢復。匯入會重建項目 ID 與建立/更新時間。',
    exportAction: '匯出',
    exportCsv: '匯出明文 CSV',
    exportCsvSubtitle: '僅用於有損遷移，不含完整類型欄位、歷史、多網址及完整 TOTP 參數。檔案不加密，請謹慎保管。',
    importFromBackup: '從加密備份匯入',
    importFromBackupSubtitle: '選擇 .wljbak 備份包還原項目；重複項目自動略過。',
    keepInTray: '關閉視窗時保留在系統匣',
    keepInTraySubtitle: '關閉後仍可透過系統匣圖示或快速鍵喚起；從系統匣選單選擇「結束」才會終止程式。',
    globalHotkey: '全域快速鍵  {combo}',
    globalHotkeySubtitle: '在任何程式中按下即可喚起 VaultOne 並聚焦搜尋框。',
    allowBrowserExtension: '允許瀏覽器擴充功能連線',
    allowBrowserExtensionSubtitle: '擴充功能透過本機 Native Messaging 向 VaultOne 請求憑據，只會拿到與目前網站嚴格比對的那一筆；解密全部在本應用程式內完成。',
    installExtension: '安裝擴充功能',
    installExtensionSubtitle: '支援 Chrome、Edge、Brave 等 Chromium 核心瀏覽器。安裝後點擊擴充功能圖示完成配對。',
    pairedBrowsers: '已配對的瀏覽器',
    noneYet: '暫無',
    pairedAt: '配對於 {created} · 最近使用 {used}',
    removeAction: '移除',
    repairConnection: '修復連線',
    repairConnectionSubtitle: '擴充功能提示「找不到 VaultOne 桌面端」時，重新向瀏覽器登記連接器。',
    reregister: '重新登記',
    reregistered: '已登記，請重新啟動瀏覽器後重試',
    autofillEnabled: 'VaultOne 已是系統自動填入服務',
    autofillEnable: '將 VaultOne 設為自動填入服務',
    autofillSubtitle: '在應用程式與瀏覽器的登入框中選擇「用 VaultOne 填入」。網頁只推薦與目前網域嚴格比對的項目；登入後可一鍵儲存新密碼。',
    enabledTag: '已啟用',
    openSettings: '前往設定',
    verboseLogs: '詳細日誌（診斷模式）',
    verboseLogsSubtitle: '日誌只含事件類型、錯誤碼與耗時，絕不包含密碼、項目內容或電子郵件。重新啟動應用程式後生效。',
    logFile: '日誌檔案',
    logFileSubtitle: '回報問題時可附上日誌檔案。',
    openFolder: '開啟目錄',
    logDirFailed: '無法開啟日誌目錄，請手動前往：{path}',
    logDirFailedGeneric: '開啟日誌目錄失敗，請手動前往應用程式資料目錄下的 logs 資料夾',
    buildInfo: '建置 {build} · 加密核心開源（AGPL-3.0）',
    privacyPolicyLink: '隱私政策',
    termsLink: '使用者條款',
    sourceAndWhitepaper: '原始碼與安全白皮書',
    openSourceLicenses: '開源授權',
    viewLicenses: '查看第三方開源授權',
    feedback: '意見回饋',
    feedbackSubtitle: '提交問題或建議，查看處理狀態與客服回覆。需連線支援此功能的 Java 服務。',
    openFeedback: '開啟回饋',
    contactSupport: '聯絡支援',
    sendEmail: '傳送電子郵件',
    wipeLocalData: '清除本機資料',
    wipeLocalDataSubtitle: '刪除本機保險庫與儲存的 Secret Key，不註銷雲端帳戶；未同步的本機修改會遺失。',
    wipeConfirmBody: '未同步的本機項目與修改將永久遺失。只有已成功同步的資料才能在重新登入後恢復。請先確認備份及 Secret Key 已妥善保存。',
    wipeConfirmTitle: '清除本機資料？',
    deleteCloudAccount: '註銷雲端帳戶',
    deleteCloudAccountSubtitle: '永久刪除雲端的全部密文、裝置與日誌（個人資訊保護法 / GDPR 刪除權）。本機資料保留。',
    deleteAccountAction: '註銷',
    deleteCloudAccountBody: '此操作不可撤銷。請輸入主密碼確認。',
    deletePermanently: '永久註銷',
    cloudAccountDeleted: '雲端帳戶已註銷',
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
    searchItemsHint: '搜尋標題、使用者名稱、網址',
    clearSearch: '清除',
    newItem: '新增',
    emptySearchTitle: '沒有符合「{query}」的項目',
    emptySearchBody: '試試標題、使用者名稱或網址中的其他關鍵字',
    emptyTrashTitle: '回收筒是空的',
    emptyTrashBody: '刪除的項目會在這裡保留，可隨時恢復',
    emptyVaultTitle: '這裡還沒有項目',
    emptyVaultBodyCompact: '點右下角 + 建立第一個',
    emptyVaultBody: '按 Ctrl+N 建立第一個',
    emptyTrashConfirmTitle: '清空回收筒？',
    emptyTrashConfirmBody: '回收筒中已同步的項目將從本機永久刪除，無法恢復；尚未同步的項目會保留。已同步到雲端的資料不會在其他裝置上被抹除。',
    emptyTrashConfirmAction: '清空',
    emptyTrashKeptNote: '，{kept} 筆未同步已保留',
    emptyTrashNone: '沒有可清空的項目{kept}',
    emptyTrashDone: '已徹底刪除 {purged} 筆{kept}',
    emptyTrashTooltip: '清空回收筒',
    lockNow: '立即鎖定',
    lockNowWithHotkey: '立即鎖定 (Ctrl+L)',
    newItemTooltip: '新增項目',
    sidebarCategories: '分類',
    sidebarTools: '工具',
    selectItemHint: '選擇一個項目查看詳情',
    shortcutHint: 'Ctrl+F 搜尋 · Ctrl+N 新增 · Ctrl+G 產生密碼 · Ctrl+L 鎖定',
    itemMissing: '項目不存在',
    cloudNeedsRevalidate: '雲端帳戶需要重新驗證',
    titleLabel: '標題',
    titleRequired: '請輸入標題',
    createdItem: '已建立「{title}」',
    hintLoginTitle: '例如：GitHub',
    hintCardTitle: '例如：招商銀行信用卡',
    hintNoteTitle: '例如：伺服器備忘',
    hintIdentityTitle: '例如：本人',
    groupLoginCredentials: '登入憑據',
    fieldUsernameOrEmail: '使用者名稱 / 電子郵件',
    generateStrongPassword: '產生強密碼',
    fieldTotpFull: '兩步驗證（TOTP）',
    scanQrCode: '掃描 QR Code',
    preview: '預覽',
    totpParams: '{alg} · {digits} 位 · {period}s',
    addAction: '新增',
    groupWebsite: '網站',
    groupCardInfo: '卡片資訊',
    fieldName: '名稱',
    fieldValue: '值',
    sensitiveField: '敏感欄位（預設隱藏）',
    plainField: '一般欄位',
    groupContent: '內容',
    notesPlaceholder: '僅你可見，端到端加密',
    customFieldsExample: '例如：安全問題、U 盾編號、API Key',
    createItemTitle: '新增{kind}',
    editItemTitle: '編輯{kind}',
    editorShortcuts: 'Ctrl+S 儲存 · Esc 取消',
    templateSection: '從範本開始',
    templateAllFields: '完整欄位',
    templateNote: '範本會預設欄位並調整新增表單，已填寫內容不會被覆蓋。',
    urlMatchPickerLabel: '比對方式（自動填入時使用）',
    urlMatchDomain: '網域',
    urlMatchHost: '主機',
    urlMatchExact: '精確',
    urlMatchNever: '從不',
    signInEyebrow: 'Sign in',
    signInTitle: '登入現有帳戶',
    signInSubtitle: '需要 Recovery Kit 上的 Secret Key。主密碼只在本機參與計算，不會傳送到伺服器。',
    fillAllFields: '請填寫電子郵件、Secret Key 與主密碼',
    deviceNameLabel: '裝置名稱',
    thisDeviceName: '本裝置名稱',
    syncServerLabel: '同步伺服器',
    verifying: '正在驗證…',
    newDeviceEyebrow: 'New device',
    verifyDeviceTitle: '驗證這台新裝置',
    verifyDeviceSubtitle: '為防止帳戶被盜用，新裝置首次登入必須二次驗證。我們已向你的電子郵件寄送 6 位驗證碼；也可以在已登入的裝置上「設定 → 裝置管理」中批准。',
    emailCodeLabel: '電子郵件驗證碼',
    emailCodeHint: '6 位數字',
    verifyAndContinue: '驗證並繼續',
    waitingApproval: '正在等待其他裝置批准…',
    cancelSignIn: '取消登入',
    recoverAccountTitle: '用 Recovery Kit 恢復帳戶',
    recoverAccountSubtitle: '恢復後需設定新主密碼，舊恢復碼與所有舊裝置工作階段立即失效，你會拿到一份新的 Recovery Kit。',
    recoverAccountAction: '恢復帳戶',
    cloudSetupRetry: '註冊尚未完成，請重試',
    cloudBackupSaved: '加密備份已儲存；恢復仍需目前帳戶的金鑰材料',
    cloudBackupFailed: '備份儲存失敗，請檢查儲存位置',
    wipeAndReloginTitle: '清除本機資料並重新登入？',
    wipeAndReloginBody: '不會註銷雲端帳戶。未同步的本機項目與註冊草稿會永久遺失，本機儲存的 Secret Key 也會刪除。請先匯出備份並保管恢復材料；雲端註冊逾時並不代表雲端帳戶未建立。',
    wipeAndReloginConfirm: '確認清除本機資料',
    wipeIncomplete: '清除未完成，請重試；雲端帳戶未被註銷',
    cloudFinishTitle: '完成雲端帳戶註冊',
    cloudAttachTitle: '將現有保險庫接入雲端帳戶',
    cloudFinishBody: '註冊材料已在本機加密儲存。只有 Java 服務確認後才完成註冊；重試沿用同一帳戶與金鑰，不會重新產生。',
    cloudAttachBody: '新版本使用雲端帳戶。現有項目、帳戶識別與金鑰全部保留；請使用目前主密碼完成接入。若雲端同電子郵件屬於不同帳戶，不會覆蓋或合併。',
    javaServiceLabel: 'Java 服務：{url}',
    cloudVerifyAndFinish: '驗證並完成雲端註冊',
    exportBackupFirst: '先匯出本機加密備份',
    lockAndContinueLater: '鎖定並稍後繼續',
    wipeAndReloginAction: '清除本機資料後重新登入',
    cloudZeroKnowledgeNote: '密碼、Secret Key 與項目明文不會上傳。完成雲端註冊後，項目仍可離線讀寫，連線後自動同步密文。',
    regenerate: '重新產生',
    generatorSubtitle: '使用系統級 CSPRNG 產生，結果只存在於本機記憶體。',
    generatePassword: '產生密碼',
    lengthLabel: '長度',
    excludeAmbiguous: '排除易混淆字元',
    wordCountLabel: '字詞數',
    separatorSpace: '空格',
    capitalizeFirst: '首字母大寫',
    includeDigits: '含數字',
    useThisPassword: '使用此密碼',
    randomPasswordTab: '隨機密碼',
    passphraseTab: '口令短語',
    sidebarTagline: '能開啟你保險庫的，\n只有一個人——',
    sidebarTaglineHighlight: '你自己。',
    authAsideBody: '所有資料在這台裝置上加密後才會離開。伺服器只保存密文——即使被整庫拖走，也解不開任何一個密碼。',
    featureZeroKnowledge: '零知識',
    featureZeroKnowledgeBody: '主密碼從不上傳，伺服器無法重設，也無法窺視。',
    featureTwoFactorDerivation: '雙因子派生',
    featureTwoFactorDerivationBody: 'Argon2id(主密碼) × 240-bit Secret Key，離線爆破解不開。',
    featureItemEncryption: '項目級加密',
    featureItemEncryptionBody: 'AES-256-GCM，每個項目、每個版本獨立金鑰與隨機 IV。',
    authAsideFooter: 'VaultOne · 本機優先的數位資產保險庫',
    clipboardCopiedToast: '已複製{label}',
    clipboardClearCountdown: '{seconds} 秒後從剪貼簿清除 · 不進入剪貼簿歷史',
    clearNow: '立即清除',
    qrScanTitle: '掃描兩步驗證 QR Code',
    qrScanHint: '將網站提供的 QR Code 置於框內',
    saveFailedDisk: '儲存失敗，請檢查目錄權限與可用空間。',
    backupCardSavedTo: '備份卡已儲存到 {path}',
    backupCardFailed: '備份卡匯出失敗，請檢查目錄權限與可用空間。',
    kitSavedTo: '恢復套件已儲存到 {path}',
    keyVerifyMismatch: '與本機儲存的 Secret Key 不一致。請對照恢復套件逐組核對，注意易混淆字元 I/L/O 與數字 1/0。',
    verifyIncomplete: '核對未完成，請稍後重試。',
    keyVerifyOk: 'Secret Key 與本機儲存的逐位元組一致；恢復碼格式有效。',
    recoveryCodeInvalid: '恢復碼格式不正確，應為 R1- 開頭、13 組 Crockford Base32。',
    lastLocalBackup: '最近本機備份',
    neverRecorded: '從未記錄',
    cloudBackupHistory: '雲端備份歷史',
    cloudBackupHistoryNone: '暫無（伺服器備份記錄端點未實作）',
    backupManagerBody: '本機只保存「最近一次匯出」這個事實，不保存檔案路徑與內容。恢復套件與備份卡都可以在這裡重新匯出；為避免他人趁保險庫未鎖定時拿到憑據，重新匯出前需要你重新提供恢復材料。',
    verifyMaterials: '恢復材料核對',
    verifyPassed: '核對通過',
    reExport: '重新匯出',
    recoveryKitPdfShort: '恢復套件（PDF）',
    backupCardShort: '備份卡（PNG 700×900）',
    viewSecretKey: '查看 Secret Key',
    backupCredentialWarning: '恢復套件與備份卡都等同於明文憑據，匯出後請按同等級別保管：列印或存進離線媒體，不要放進網盤、電子郵件或聊天記錄。',
    securityCenterSubtitle: '所有分析均在本機完成。洩漏檢測只傳送密碼 SHA-1 的前 5 位，伺服器無法得知你的密碼。',
    auditFailed: '稽核失敗：{reason}',
    breachCheckFailed: '檢測失敗：{reason}',
    statusGood: '狀態良好',
    statusNeedsWork: '有待加強',
    statusActNow: '需要立即處理',
    noPasswordItems: '還沒有帶密碼的項目。',
    riskSummary: '{total} 個帶密碼的項目中，{problems} 個存在風險。',
    weakPasswords: '弱密碼',
    reusedPasswords: '重複使用',
    breachedPasswords: '已洩漏',
    twoFactorCoverage: '兩步驗證',
    healthTitle: '安全體檢',
    healthScore: '健康分',
    healthCheckedAt: '最近檢查：{time}',
    healthExpired: '報告已過期，建議重新體檢',
    healthRerun: '重新體檢',
    healthDimensionTitle: '維度得分',
    healthDimensionSkipped: '本次跳過',
    healthStatsTitle: '掃描統計',
    healthScanned: '已掃描密碼',
    healthPasswordFields: '密碼欄位',
    healthUnreadable: '不可讀條目',
    healthBreachLabel: '洩露檢測',
    healthBreachNotRun: '未執行',
    healthBreachOk: '正常',
    healthBreachUnavailable: '無法使用',
    healthBreachSkipped: '已跳過',
    healthFindings: '發現項',
    healthNoFindings: '沒有發現問題，請保持。',
    healthSnooze: '忽略 7 天',
    healthSnoozed: '已忽略 {n} 項',
    healthOpenItem: '開啟條目',
    healthActionRun: '去執行',
    healthActionEnable: '去開啟',
    healthActionGeneral: '開啟一般設定',
    healthActionSystem: '開啟系統設定',
    healthSeverityLow: '低危',
    healthSeverityMedium: '中危',
    healthSeverityHigh: '高危',
    healthSeverityCritical: '嚴重風險',
    healthDimBreach: '洩露',
    healthDimReuse: '密碼重用',
    healthDimStale: '長期未更新',
    healthDimEnvironment: '裝置環境',
    healthDimSettings: '設定項',
    healthDimScore: '扣 {used} / 上限 {cap}',
    healthChecklist: '任務清單',
    healthChecklistProgress: '已完成 {done} / {total}',
    healthRisks: '風險項',
    healthRiskNone: '沒有風險項。',
    healthGrid: '快速入口',
    sidebarLayoutTitle: '首頁板塊',
    sidebarLayoutSubtitle: '調整側欄分區的順序與顯示與否。設定只保存在本機，不同步——不同裝置螢幕大小不同，同步反而兩邊都不順手。',
    sidebarMoveUp: '上移',
    sidebarMoveDown: '下移',
    sidebarShow: '在側欄顯示',
    sidebarKeepOne: '至少保留一個分區，否則側欄會變成空白',
    sidebarResetLayout: '恢復預設版面',
    lockOnExit: '結束即鎖定',
    lockOnExitSubtitle: '關閉視窗（隱藏到系統匣）時立即鎖定保險庫。',
    maskPasswords: '預設隱藏密碼',
    maskPasswordsSubtitle: '詳情頁預設以圓點顯示密碼，需要時再點眼睛檢視。',
    screenshotProtection: '截圖保護',
    screenshotProtectionSubtitle: '阻止本應用程式視窗被截圖與錄影擷取。',
    screenshotUnsupported: '目前平台不支援截圖保護',
    clipboardDisabled: '不自動清空',
    importPreviewTitle: '匯入預覽',
    importPreviewSource: '識別來源：{source}',
    importPreviewCounts: '共 {rows} 列，可匯入 {items} 筆，跳過 {skipped} 列',
    importPreviewTruncated: '只顯示前 {n} 列',
    importPreviewWarnings: '解析警告',
    importPreviewMapping: '欄位對應',
    importPreviewUnmapped: '不匯入',
    importPreviewColumn: '第 {n} 欄',
    importPreviewStrategy: '同名項目',
    importStrategySkip: '保留現有的',
    importStrategyOverwrite: '用匯入的內容覆寫',
    importStrategyKeepBoth: '兩筆都保留',
    importPreviewConfirm: '開始匯入',
    importPreviewEmpty: '這份檔案裡沒有可匯入的項目',
    importUpdated: '，覆寫 {n} 筆',
    taxonomyManage: '標籤與分類管理',
    taxonomyManageSubtitle: '重新命名或清理標籤與分類；只改分類歸屬，不會刪除項目。',
    taxonomyRename: '重新命名',
    taxonomyRenameTagTitle: '重新命名標籤',
    taxonomyRenameCategoryTitle: '重新命名分類',
    taxonomyClearCategoryTitle: '清空分類',
    taxonomyNewName: '新名稱',
    taxonomyTagHint: '不分大小寫；改成已存在的標籤等於合併。',
    taxonomyCategoryHint: '子分類會一起移動；改成已存在的分類等於合併。',
    taxonomyClearBody: '將清空「{name}」及其子分類的歸屬，共 {n} 筆項目。項目本身不會被刪除。',
    taxonomyDeleteTagBody: '將從 {n} 筆項目上移除標籤「{name}」。項目本身不會被刪除。',
    taxonomyAffected: '已更新 {n} 筆項目',
    taxonomyNoTags: '還沒有任何標籤',
    taxonomyNoCategories: '還沒有任何分類',
    subListTagTitle: '標籤：{name}',
    subListCategoryTitle: '分類：{name}',
    subListCount: '共 {n} 筆',
    subListViewItems: '檢視項目',
    subListOpenInPage: '在新頁面開啟',
    fieldType: '欄位類型',
    fieldKindText: '文字',
    fieldKindDate: '日期',
    fieldKindImage: '圖片',
    fieldDateHint: '年-月-日，例如 2026-10-02',
    fieldImageHint: '本機路徑或 https:// 網址',
    fieldPickDate: '選擇日期',
    fieldPickImage: '選擇圖片',
    pickImageUnavailable: '目前平台沒有檔案選擇器，請手動填寫圖片網址',
    fieldDateInvalid: '日期格式應為 年-月-日',
    fieldImageMissing: '請填寫圖片網址',
    imageLoadFailed: '圖片無法載入',
    transferHistory: '匯入匯出歷史',
    transferHistorySubtitle: '只記在這台裝置上，以保險庫金鑰加密存放，不參與同步。',
    transferImport: '匯入',
    transferNoHistory: '還沒有匯入匯出紀錄',
    transferClear: '清空歷史',
    transferClearConfirm: '清空本機匯入匯出歷史？項目資料不受影響。',
    transferSource: '來源：{name}',
    transferNoSource: '未記錄來源',
    transferBytes: '{n} 位元組',
    transferCounts: '新增 {added}，覆寫 {updated}，重複 {duplicates}，跳過 {skipped}',
    profileEdit: '編輯資料',
    profileNickname: '暱稱',
    profileAvatar: '頭像網址',
    profileNoNickname: '未設定暱稱',
    profileSaved: '資料已更新',
    profileOffline: '離線：顯示的是本機快取',
    profileNicknameHint: '最多 32 個字元，可留空',
    profileAvatarHint: 'http 或 https 連結，可留空',
    profileCreatedAt: '註冊時間：{time}',
    inviteMine: '我的邀請碼',
    inviteNone: '尚未產生',
    inviteCopy: '複製邀請碼',
    inviteCopied: '邀請碼已複製',
    inviteBind: '填寫邀請碼',
    inviteBindTitle: '填寫邀請人的邀請碼',
    inviteBindHint: '12 位字母數字，可帶空格或連字元',
    inviteBindDone: '已綁定邀請人',
    inviteBindNote: '一次性綁定，綁定後不可更改。',
    backupNow: '立即備份',
    backupReminder: '備份提醒',
    backupReminderHint: '關掉後體檢清單裡不再出現備份項。',
    breachCheck: '洩漏密碼檢測',
    breachCheckSubtitle: '對照 Have I Been Pwned 資料庫（k-匿名），需要連線。',
    breachCheckDone: '檢測完成：{count} 個項目的密碼出現在公開洩漏資料中。',
    startCheck: '開始檢測',
    recheck: '重新檢測',
    breachedAdvice: '這些密碼出現在公開洩漏庫中，攻擊者會優先嘗試，請立即更換。',
    breachTimes: '出現 {count} 次',
    weakAdvice: '容易被猜測或字典攻擊破解。',
    strengthVeryWeak: '極弱',
    strengthWeak: '弱',
    strengthFair: '一般',
    strengthStrong: '強',
    strengthVeryStrong: '很強',
    reusedAdvice: '一個網站洩漏，會連帶其他網站失守。',
    reusedWith: '與 {count} 個項目相同',
    noProblems: '沒有發現問題。保持下去。',
    securityScore: '安全評分',
    conflictLoadFailed: '暫時無法讀取衝突，請重試',
    conflictSavedLocal: '選擇已保存到本機，等待同步。遠端確認前仍可能產生新的衝突。',
    conflictCandidateChanged: '候選已發生變化，請檢查重新整理後的版本並重新選擇。',
    pickConflictHint: '選擇一個衝突查看雙方版本',
    showHistoryToggle: '顯示歷史記錄',
    noConflictRecords: '暫無衝突記錄',
    noPendingConflicts: '沒有待處理的衝突',
    untitledItem: '未命名項目',
    refreshList: '重新整理清單',
    backToConflictList: '返回衝突清單',
    pickAConflict: '請選擇一個衝突',
    candidateExpired: '候選已過期，不能提交舊選擇。請先重新整理候選。',
    resolutionQueued: '解決方案已在本機排隊，等待同步。這裡不表示已經同步成功。',
    historyReadOnly: '歷史記錄，僅供查看，不能再次提交。',
    refreshCandidate: '重新整理候選',
    hideSensitive: '隱藏敏感內容',
    showSensitive: '顯示敏感內容',
    conflictWholeItemOnly: '項目類型或解決方案存在衝突，只能整條保留一方。',
    keepWholeLocal: '保留整條本機',
    keepWholeRemote: '保留整條遠端',
    wholeItemAdvice: '整條保留會採用該方的全部內容；下方可比較所有欄位。',
    submitFieldChoices: '提交逐欄位選擇（{chosen}/{total}）',
    sensitiveHidden: '敏感內容已隱藏',
    deletedYes: '已刪除',
    deletedNo: '未刪除',
    deletedUnknown: '未知（舊基線未記錄）',
    emptyValue: '（空）',
    commonBase: '共同基礎 · v{revision}',
    adoptSide: '採用{side}',
    sideRemote: '遠端',
    sideWithRevision: '{side} · v{revision}',
    fieldConflictSuffix: '{field} · 衝突',
    adoptFieldSide: '採用{side}{field}',
    conflictFieldKind: '項目類型',
    conflictFieldDeleted: '刪除狀態',
    conflictFieldResolution: '解決方案',
    conflictStatusPending: '待處理',
    conflictStatusAwaitingSync: '等待同步',
    conflictStatusResolved: '已解決',
    conflictStatusSuperseded: '已被替代',
    conflictCandidateStale: '候選已過期',
    pairingTitle: '連接瀏覽器擴充功能？',
    pairingBody: '「{name}」中的 VaultOne 擴充功能要求連線。請確認擴充功能彈窗中顯示的配對碼與下方一致；不一致或不是你發起的，請拒絕。',
    rejectAction: '拒絕',
    allowPairing: '配對碼一致，允許連線',
    feedbackBug: '問題回報',
    feedbackSuggestion: '功能建議',
    feedbackOther: '其他',
    feedbackStatusInProgress: '處理中',
    feedbackStatusResolved: '已處理',
    feedbackStatusUnknown: '無法識別回饋狀態',
    feedbackClose: '關閉回饋',
    refreshAction: '重新整理',
    feedbackExpired: '回饋頁面已失效，請解鎖並重新進入。',
    feedbackWriteTab: '寫回饋',
    feedbackHistoryTab: '歷史記錄',
    feedbackDraftNotice: '關閉或鎖定將清除本頁內容，但不會撤回已送出的回饋。',
    feedbackConsentTitle: '客服可以讀取回饋',
    feedbackConsentBody: '正文與選填聯絡方式會傳送給客服，不屬於零知識保險庫內容。',
    feedbackNoSecrets: '請勿填寫密碼、Secret Key、恢復碼或保險庫內容。',
    feedbackNoAutoAttach: '不會自動附上電子郵件、日誌、裝置診斷或剪貼簿。',
    feedbackSubmitted: '送出成功',
    feedbackWriteAnother: '再寫一則',
    feedbackCategory: '回饋類型',
    feedbackBody: '回饋正文',
    feedbackBodyHint: '描述遇到的問題或建議，不要填寫敏感資訊',
    feedbackBodyRequired: '請填寫回饋正文',
    feedbackBodyTooLong: '正文最多 4000 個 UTF-16 程式碼單元',
    feedbackContact: '聯絡方式（選填）',
    feedbackContactTooLong: '聯絡方式最多 200 個 UTF-16 程式碼單元',
    feedbackConsentAck: '我理解正文與聯絡方式可被客服讀取，並同意傳送。',
    feedbackConsentRequired: '勾選同意後才能送出。',
    feedbackUnconfirmed: '尚未確認送出結果，回饋可能已儲存。原請求與編號已保留，不可編輯；請原樣重試，或先查看歷史確認。',
    feedbackSubmitting: '正在送出…',
    feedbackRetryAsIs: '原樣重試',
    feedbackSubmit: '送出回饋',
    feedbackDiscard: '放棄本次送出',
    feedbackClearDraft: '清空草稿',
    feedbackDiscardWarning: '本次回饋可能已經送出。放棄只清除本頁請求，不會刪除伺服器記錄；建議先看歷史，避免重複送出。',
    feedbackCheckHistoryFirst: '先看歷史',
    feedbackConfirmDiscard: '確認放棄本次送出',
    feedbackCancelDiscard: '取消放棄',
    feedbackRetryHistory: '重試讀取歷史',
    feedbackHistoryEmpty: '暫無回饋記錄。你送出的回饋會顯示在這裡。',
    feedbackLoadEarlier: '載入更早記錄',
    feedbackBackToHistory: '返回歷史',
    feedbackRetryDetail: '重試讀取詳情',
    feedbackSubmittedAt: '送出於 {time}',
    feedbackIdLabel: '回饋編號：{id}',
    feedbackAccountLabel: '帳戶編號：{id}',
    feedbackSubmittedBody: '送出正文',
    feedbackContactLabel: '聯絡方式',
    feedbackLatestReply: '客服最近回覆',
    feedbackNoReply: '暫時沒有回覆。',
    feedbackNetworkError: '網路連線異常，請檢查連線後重試。',
    feedbackSessionExpired: '雲端工作階段已失效，請重新登入後再試。',
    feedbackLocked: '保險庫已鎖定，請解鎖後重新進入。',
    feedbackNotConnected: '請先在設定中連線雲端服務，再使用回饋。',
    feedbackPrivacyRequired: '請先閱讀並同意隱私政策與使用者條款。',
    feedbackUnsupported: '此伺服器暫不支援回饋功能，請聯絡支援。',
    feedbackForbidden: '目前裝置無權存取回饋，請檢查裝置授權。',
    feedbackInvalid: '回饋格式不符合要求，請檢查類型與長度。',
    feedbackDuplicate: '此送出編號已被使用，請先查看歷史確認結果。',
    feedbackNotFound: '回饋不存在或已到期，請重新整理歷史記錄。',
    feedbackRateLimited: '送出過於頻繁或已達數量上限，請稍後再試。',
    feedbackUnavailable: '回饋服務暫時無法使用，請稍後重試。',
    feedbackGenericError: '暫時無法完成操作，請稍後重試。',
    autofillUnknownApp: '未知應用程式',
    autofillSetupFirst: '請先開啟 VaultOne 完成保險庫設定，再使用自動填入。',
    autofillFillTo: '填入到 {source}',
    autofillMatchedSite: '與此網站相符',
    autofillAppNoMatch: '應用程式內的登入表單不做自動比對，請確認所選項目屬於該應用程式。',
    autofillAllLogins: '全部登入項目',
    autofillOtherItems: '其他項目',
    autofillNoLogins: '沒有找到登入項目',
    autofillNoUsername: '（無使用者名稱）',
    autofillSaveFailed: '儲存失敗',
    autofillSaveToVault: '儲存到 VaultOne？',
    autofillUpdatePassword: '更新「{title}」的密碼？',
    autofillUpdate: '更新',
    autofillDontSave: '不儲存',
    tplLoginWebsite: '網站帳號',
    tplLoginWebsiteDesc: '使用者名稱、密碼、網址與兩步驗證',
    tplLoginApi: 'API / 開發者帳號',
    tplLoginApiDesc: '登入憑據與 API Key、Secret 等敏感欄位',
    tplLoginApiHint: '例如：OpenAI API',
    tplLoginDevice: '伺服器 / 裝置',
    tplLoginDeviceDesc: '主機、連接埠、帳號與裝置憑據',
    tplLoginDeviceHint: '例如：生產伺服器',
    tplCardBank: '金融卡',
    tplCardBankDesc: '卡號、有效期限、安全碼與 PIN',
    tplCardMembership: '會員 / 積分卡',
    tplCardMembershipDesc: '會員號、等級與積分資訊',
    tplCardMembershipHint: '例如：航空公司會員卡',
    tplNoteSecureDesc: '自由文字，適合恢復碼與設定說明',
    tplNoteApi: '伺服器 / API 金鑰',
    tplNoteApiDesc: '主機、帳號、金鑰與備註',
    tplNoteApiHint: '例如：生產 API 金鑰',
    tplNoteWifi: 'Wi-Fi 資訊',
    tplNoteWifiDesc: '網路名稱、密碼與安全類型',
    tplNoteWifiHint: '例如：家裡 Wi-Fi',
    tplIdentityPersonal: '個人資訊',
    tplIdentityPersonalDesc: '姓名、電子郵件、電話、證件號與地址',
    tplIdentityWork: '公司 / 工作身分',
    tplIdentityWorkDesc: '公司、職位、員工編號與聯絡方式',
    tplIdentityWorkHint: '例如：公司電子郵件身分',
    coreVaultLocked: '保險庫已鎖定，請重新解鎖後操作',
    corePrivacyRequired: '請先閱讀並同意隱私政策與使用者條款',
    coreServerMismatch: '本機帳戶綁定的伺服器與 Java 設定不同，請先重新驗證並確認連線',
    configProdHttpsRequired: '發行組建需明確設定有效的 HTTPS Java 服務位址',
    configServerInvalid: '伺服器位址無效；真機 HTTP 偵錯需開啟 VAULTONE_ALLOW_LAN_HTTP 並指定私網 IP',
    accountCancelled: '帳戶操作已取消',
    secureStorageIncomplete: '安全儲存或註冊未完成，請保留恢復材料後重試',
    unlockDraftFirst: '請先解鎖帳戶草稿',
    finishCloudFirst: '請先完成雲端帳戶註冊',
    missingSecretKey: '本裝置未儲存 Secret Key，請輸入 Recovery Kit 上的 Secret Key',
    unlockVaultPrompt: '解鎖 VaultOne 保險庫',
    changePasswordUnconfirmed: '改密結果尚未確認。舊本機密碼仍可解鎖，請使用相同的新密碼重試；其他裝置可能已採用新密碼。',
    reverifyKeepData: '請重新驗證 Java 服務連線；原資料與待同步項目已保留',
    reverifyNoRequest: '請重新驗證 Java 服務連線；不會自動向舊伺服器傳送請求',
    accountDeletedLocally: '雲端帳戶已註銷。本機加密資料保留，可先匯出備份或明確清除本機資料。',
    trayOpen: '開啟 VaultOne',
    trayQuickSearch: '快速搜尋',
    trayQuit: '結束',
    docExportedViaPanel: '已透過系統面板匯出',
    docSecretKeyLabel: 'SECRET KEY · 裝置金鑰',
    docRecoveryCodeLabel: 'RECOVERY CODE · 恢復碼',
    docEmailLabel: '帳戶電子郵件 / EMAIL',
    docMasterPasswordLabel: '主密碼（選填，手寫）/ MASTER PASSWORD',
    docLoginNeedsBoth: '在新裝置登入時，需要同時輸入「主密碼」與「Secret Key」。',
    docGeneratedFooter: '產生於 {date} · 能開啟你保險庫的，只有你自己。',
    kitDocTitle: 'Recovery Kit · 恢復套件',
    kitLead: '這是找回你保險庫的唯一憑據。VaultOne 採用零知識架構，我們無法重設你的主密碼，也無法替你恢復資料。請列印或離線保存本檔案，不要存放在網盤、電子郵件或聊天記錄中。',
    kitResetHint: '忘記主密碼時，可用「Secret Key + 恢復碼」重設主密碼；重設後此恢復碼立即作廢，請保存新的 Recovery Kit。',
    kitAccountId: '帳戶 ID：{id}',
    kitFileName: 'VaultOne-Recovery-Kit.pdf',
    kitTypeGroup: 'PDF',
    cardDocBadge: 'RECOVERY KIT · 備份卡',
    cardDocTitle: '請離線保管這張卡',
    cardLead: '它是找回你保險庫的唯一憑據。VaultOne 採用零知識架構，無法重設你的主密碼，也無法替你恢復資料。請列印成實體卡或存入離線媒體，不要放進網盤、電子郵件或聊天記錄。',
    cardResetHint: '忘記主密碼時，可用「Secret Key + 恢復碼」重設主密碼；重設後此恢復碼立即作廢，請保存新的恢復套件。',
    cardFileName: 'VaultOne-備份卡.png',
    cardTypeGroup: 'PNG 圖片',
    cardEncodeFailed: '備份卡編碼失敗',
    moveToTrash: '移至回收筒',
    moveToTrashConfirmTitle: '移至回收筒？',
    moveToTrashConfirmBody: '「{title}」將移至回收筒，可隨時恢復。',
    movedToTrashTitle: '已移至回收筒',
    movedToTrashBody: '「{title}」已移至回收筒，可隨時恢復。',
    purgeConfirmTitle: '徹底刪除？',
    purgeConfirmBody: '「{title}」將從本機永久刪除，無法恢復。已同步到雲端的資料不會在其他裝置上被抹除。',
    purgeAction: '徹底刪除',
    purgedTitle: '已徹底刪除「{title}」',
    fieldUsername: '使用者名稱',
    fieldPassword: '密碼',
    fieldTotp: '驗證碼',
    urlMatchSuffix: '{label}比對',
    urlFieldLabel: '網站 · {label}比對',
    fieldWebsite: '網址',
    openInBrowser: '在瀏覽器中開啟',
    fieldNotes: '備註',
    groupTaxonomy: '標籤與分類',
    tagLabel: '標籤',
    tagInputHint: '輸入標籤後按 Enter',
    tagAdd: '新增標籤',
    tagLimitReached: '最多 {count} 個標籤',
    tagRemoveTooltip: '移除標籤「{tag}」',
    categoryHint: '例如：工作 / 個人 / 金融',
    filterByTagTitle: '依標籤篩選',
    filterByCategoryTitle: '依分類篩選',
    clearFilter: '清除篩選',
    noTagsInVault: '還沒有標籤',
    noCategory: '未分類',
    allTags: '全部標籤',
    groupCategories: '分組',
    noCategoriesYet: '暫無分類',
    categoryPathHint: '用 / 分隔層級，例如：工作/生產',
    categoryTreeTooltip: '層級分類，選取後連同子分類一起顯示',
    fieldCardholder: '持卡人',
    fieldCardNumber: '卡號',
    fieldExpiry: '有效期限',
    fieldCvv: '安全碼',
    fieldPin: 'PIN',
    fieldFullName: '姓名',
    fieldPhone: '電話',
    fieldIdNumber: '證件號',
    fieldAddress: '地址',
    fieldCompany: '公司',
    fieldEmail: '電子郵件',
    customFields: '自訂欄位',
    passwordHistory: '密碼歷史',
    historyPassword: '歷史密碼',
    copyTotp: '複製驗證碼',
    labelEncrypted: '加密',
    labelHide: '隱藏',
    purgeErrorUnsynced: '該項目尚未同步到雲端，請先完成同步後再徹底刪除。',
    purgeErrorNotFound: '項目已不存在，請重新整理回收筒。',
    purgeErrorLocked: '保險庫已鎖定，請解鎖後重試。',
    purgeErrorGeneric: '暫時無法徹底刪除，請稍後重試。',
    restoreAction: '恢復',
    restoredTitle: '已恢復「{title}」',
    unfavorite: '取消收藏',
    editAction: '編輯',
    labelCreated: '建立',
    labelUpdated: '修改',
    labelRevision: '版本',
    labelKind: '類型',
    labelReveal: '顯示',
    totpOnce: '一次性驗證碼',
    totpCountdown: '剩餘 {seconds} 秒',
    cardExpired: '已過期',
    cardExpiresSoon: '即將過期',
    onboardWelcomeTitle: '歡迎使用 VaultOne',
    onboardWelcomeBody: '口令、帳號、兩步驗證、金鑰——\n全部在你的裝置上加密，只為你一個人開啟。',
    onboardRegister: '註冊雲端帳戶',
    onboardHaveAccount: '我已有帳戶，登入',
    onboardAllDevicesLost: '所有裝置都遺失了？用 Recovery Kit 恢復',
    onboardNetworkNote: '帳戶註冊與登入需要連線；密碼項目在本機加密，可離線使用並自動同步。',
    onboardStepOne: 'Step 01 / 02',
    onboardSetMasterPassword: '設定主密碼',
    onboardSetMasterPasswordBody: '主密碼是你唯一需要記住的密碼。它從不離開這台裝置，我們也無法幫你找回。',
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
    never: 'Never',
    accountIdLabel: 'Account ID  {id}',
    keyDerivation: 'Key derivation',
    itemCountTag: '{count} items',
    secretKeyRowSubtitle: 'Stored in this device keychain. Viewing or re-exporting recovery material requires re-entering the Secret Key and recovery code for a byte-by-byte check.',
    verifyAndView: 'Verify and view',
    changeMasterPassword: 'Change master password',
    changeMasterPasswordSubtitle: 'Only the vault key is re-wrapped; items are not re-encrypted and it takes a second.',
    masterPasswordUpdated: 'Master password updated. Other devices need it after they sync.',
    newPasswordTooWeak: 'The new master password is too weak',
    currentMasterPassword: 'Current master password',
    updateMasterPassword: 'Update master password',
    backupKindRecoveryKit: 'Recovery Kit PDF',
    backupKindCard: 'Backup card PNG',
    backupKindWljbak: 'Encrypted backup .wljbak',
    backupKindCsv: 'Plain CSV',
    backupNever: 'No backup export recorded on this device yet. Export the Recovery Kit first and print it or keep it offline.',
    backupLast: 'Last: {time} ({kind}). This device only records when and how, never the file path or contents.',
    backupStatus: 'Backup status',
    backupCloudNote: 'Cloud backup history needs a server endpoint that does not exist yet, so this local record is not treated as a cloud backup.',
    backupMissing: 'Not backed up',
    backupPresent: 'Backed up',
    recoveryKitAndCard: 'Recovery Kit and backup card',
    recoveryKitAndCardSubtitle: 'Re-export the A4 Recovery Kit PDF, or the 700×900 (2x) backup card PNG. Both are equivalent to plaintext credentials, so the Secret Key and recovery code must be re-entered first.',
    manageAction: 'Manage',
    biometricUnlock: 'Biometric unlock',
    biometricUnlockSubtitle: 'Unlock quickly with Windows Hello, Touch ID, Face ID or a fingerprint. The quick-unlock key lives in the system keychain and stops working after a master password change.',
    biometricEnable: 'Enable biometric unlock',
    biometricDisable: 'Turn off biometric unlock',
    autoLock: 'Auto-lock',
    autoLockSubtitle: 'Lock the vault and clear in-memory keys after a period of inactivity.',
    minutes: '{n} min',
    lockOnMinimize: 'Lock when backgrounded or minimized',
    clipboardAutoClear: 'Clear the clipboard automatically',
    clipboardAutoClearSubtitle: 'Copied passwords are cleared on a timer; on desktop the write is excluded from clipboard history and cloud sync.',
    seconds: '{n}s',
    cloudSetupPending: 'Cloud account setup is not finished',
    cloudSetupPendingBody: 'Unlock again to finish Java cloud registration. Existing items are kept; there is no separate local-only account mode.',
    syncing: 'Syncing…',
    syncFailed: 'Sync failed: {reason}',
    sessionExpired: 'The session expired. Verify again.',
    autoSync: 'Sync items automatically',
    deviceSummary: 'This device: {device} · last sync {time} · {pending} pending',
    revalidate: 'Verify again',
    reconnectSync: 'Reconnect the sync service',
    reconnected: 'Reconnected',
    syncNow: 'Sync now',
    mergedItems: 'Merged {n} items that changed on several devices at once',
    deviceManagement: 'Device management',
    signOutCloudLock: 'Sign out of the cloud and lock',
    signOutCloudTitle: 'Sign out of the cloud?',
    signOutCloudBody: 'Revokes the current session online and locks this device. Local items, pending changes and the server binding are kept.',
    signOutAndLock: 'Sign out and lock',
    securityLog: 'Security log',
    deviceManagementSubtitle: 'New devices need an email code or approval here. Revoking invalidates that device session immediately.',
    deviceThis: 'This device',
    deviceRevoked: 'Revoked',
    devicePending: 'Pending',
    deviceLine: '{platform} · added {created} · last seen {seen}',
    approveAction: 'Approve',
    approvedAction: 'Approved',
    revokeAction: 'Revoke',
    revokeDeviceTitle: 'Revoke “{name}”?',
    revokeDeviceBody: 'That device is signed out immediately and can no longer sync.',
    auditSignInOk: 'Signed in',
    auditSignInFail: 'Sign-in failed',
    auditDeviceRequest: 'New device requested sign-in',
    auditDeviceApproved: 'Device approved',
    auditDeviceRevoked: 'Device revoked',
    auditPasswordChanged: 'Master password changed',
    auditRecoveryUsed: 'Recovered with the Recovery Kit',
    auditRecoveryFail: 'Recovery code rejected',
    theme: 'Theme',
    themeSystem: 'Follow system',
    themeLight: 'Light',
    themeDark: 'Dark',
    compareConflicts: 'Compare and resolve conflicts',
    compareConflictsSubtitle: 'Both conflicting versions are stored encrypted on this device. Export stays blocked while a conflict is open so no side is lost.',
    viewConflicts: 'View conflicts',
    importDone: 'Import finished',
    importSummary: 'Source: {source}\nAdded {added}{duplicates}{skipped}.\n\nThe exported file is plaintext. Delete it from disk and the trash right away.',
    importBackupSummary: 'Added {added}{duplicates}{skipped}.',
    importDuplicates: ', skipped {n} duplicates',
    importSkipped: ', {n} unrecognized',
    gotIt: 'Got it',
    notUtf8: 'The file is not UTF-8 text. Export it as CSV again from the original app.',
    vaultoneBackup: 'VaultOne backup',
    backupSaved: 'Saved an encrypted backup ({bytes} bytes) to {path}',
    backupSaveFailed: 'Saving the backup failed. Check folder permissions and free space, and do not use a partial file for restore.',
    csvConfirmTitle: 'Export a plaintext CSV?',
    csvConfirmBody: 'The CSV is not encrypted: anyone who gets the file can read passwords and TOTP seeds.\n\n'
        'It is not a full backup. It exports only the title, first URL, username, password, notes, TOTP seed, favorite flag and type; '
        'card and identity fields, custom fields, extra URLs and match rules, password history and full TOTP parameters are dropped. '
        'The trash is excluded, so it cannot restore a vault losslessly — use .wljbak for that.\n\n'
        'Keep the file safe, delete it from disk and the trash once the migration is done, and never open untrusted content in a spreadsheet app.',
    stillExport: 'Export anyway',
    csvSaved: 'Saved a lossy CSV ({bytes} bytes) to {path}. Check the migration result; this is not a full backup.',
    csvSaveFailed: 'Saving the CSV failed. Check folder permissions and free space, and clean up any plaintext file left behind.',
    importFromOthers: 'Import from other password managers',
    importFromOthersSubtitle: 'Supports CSV and 1PIF exports from Chrome, Edge, Firefox, Bitwarden, LastPass and 1Password. Files are parsed locally and encrypted immediately; duplicates are skipped.',
    importing: 'Importing…',
    chooseFile: 'Choose file',
    exportEncryptedBackup: 'Export an encrypted backup',
    exportEncryptedBackupSubtitle: 'Exports this account .wljbak item-level backup. It excludes the trash and is not a database snapshot: restore the same account and Vault Key first, then import. The file alone, or a new account with the same email, cannot restore it. Import rebuilds item IDs and timestamps.',
    exportAction: 'Export',
    exportCsv: 'Export a plaintext CSV',
    exportCsvSubtitle: 'For lossy migration only: no full type fields, history, extra URLs or full TOTP parameters. The file is not encrypted, so store it carefully.',
    importFromBackup: 'Import from an encrypted backup',
    importFromBackupSubtitle: 'Pick a .wljbak package to restore items; duplicates are skipped.',
    keepInTray: 'Keep running in the system tray when the window closes',
    keepInTraySubtitle: 'After closing, reopen it from the tray icon or the hotkey. Only “Quit” in the tray menu ends the process.',
    globalHotkey: 'Global hotkey  {combo}',
    globalHotkeySubtitle: 'Press it in any app to bring VaultOne up with the search box focused.',
    allowBrowserExtension: 'Allow the browser extension to connect',
    allowBrowserExtensionSubtitle: 'The extension asks VaultOne over local Native Messaging and only ever receives the entry that strictly matches the current site; all decryption happens inside this app.',
    installExtension: 'Install the extension',
    installExtensionSubtitle: 'Works with Chromium-based browsers such as Chrome, Edge and Brave. Click the extension icon after installing to pair.',
    pairedBrowsers: 'Paired browsers',
    noneYet: 'None yet',
    pairedAt: 'Paired {created} · last used {used}',
    removeAction: 'Remove',
    repairConnection: 'Repair the connection',
    repairConnectionSubtitle: 'If the extension reports that the VaultOne desktop app was not found, register the connector with the browser again.',
    reregister: 'Register again',
    reregistered: 'Registered. Restart the browser and try again.',
    autofillEnabled: 'VaultOne is the system autofill service',
    autofillEnable: 'Set VaultOne as the autofill service',
    autofillSubtitle: 'Choose “Fill with VaultOne” in app and browser login forms. Web pages only offer entries that strictly match the current domain, and a new password can be saved in one tap after signing in.',
    enabledTag: 'Enabled',
    openSettings: 'Open settings',
    verboseLogs: 'Verbose logs (diagnostic mode)',
    verboseLogsSubtitle: 'Logs contain event types, error codes and timings only — never passwords, item contents or email addresses. Takes effect after a restart.',
    logFile: 'Log file',
    logFileSubtitle: 'Attach the log file when reporting a problem.',
    openFolder: 'Open folder',
    logDirFailed: 'Could not open the log folder. Go there manually: {path}',
    logDirFailedGeneric: 'Could not open the log folder. Go to the logs folder inside the app data directory manually.',
    buildInfo: 'Build {build} · crypto core open source (AGPL-3.0)',
    privacyPolicyLink: 'Privacy Policy',
    termsLink: 'Terms of Service',
    sourceAndWhitepaper: 'Source code and security whitepaper',
    openSourceLicenses: 'Open source licenses',
    viewLicenses: 'View third-party licenses',
    feedback: 'Feedback',
    feedbackSubtitle: 'Report problems or ideas and follow their status and replies. Requires a Java service that supports this feature.',
    openFeedback: 'Open feedback',
    contactSupport: 'Contact support',
    sendEmail: 'Send email',
    wipeLocalData: 'Erase local data',
    wipeLocalDataSubtitle: 'Deletes the local vault and the stored Secret Key without closing the cloud account; unsynced local changes are lost.',
    wipeConfirmBody: 'Unsynced local items and changes are lost permanently. Only data that already synced can come back after signing in again. Make sure the backup and Secret Key are stored safely first.',
    wipeConfirmTitle: 'Erase local data?',
    deleteCloudAccount: 'Close the cloud account',
    deleteCloudAccountSubtitle: 'Permanently deletes every cloud ciphertext, device and log entry (GDPR / PIPL right to erasure). Local data is kept.',
    deleteAccountAction: 'Close account',
    deleteCloudAccountBody: 'This cannot be undone. Enter your master password to confirm.',
    deletePermanently: 'Close permanently',
    cloudAccountDeleted: 'Cloud account closed',
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
    searchItemsHint: 'Search titles, usernames, URLs',
    clearSearch: 'Clear',
    newItem: 'New',
    emptySearchTitle: 'No items match “{query}”',
    emptySearchBody: 'Try another keyword in the title, username or URL',
    emptyTrashTitle: 'Trash is empty',
    emptyTrashBody: 'Deleted items stay here until you restore or purge them',
    emptyVaultTitle: 'No items yet',
    emptyVaultBodyCompact: 'Tap + in the corner to create the first one',
    emptyVaultBody: 'Press Ctrl+N to create the first one',
    emptyTrashConfirmTitle: 'Empty the trash?',
    emptyTrashConfirmBody: 'Synced items in the trash are erased from this device and cannot be recovered; unsynced items are kept. Data already synced to the cloud is not wiped from other devices.',
    emptyTrashConfirmAction: 'Empty',
    emptyTrashKeptNote: ', kept {kept} unsynced',
    emptyTrashNone: 'Nothing to empty{kept}',
    emptyTrashDone: 'Permanently deleted {purged}{kept}',
    emptyTrashTooltip: 'Empty the trash',
    lockNow: 'Lock now',
    lockNowWithHotkey: 'Lock now (Ctrl+L)',
    newItemTooltip: 'New item',
    sidebarCategories: 'Categories',
    sidebarTools: 'Tools',
    selectItemHint: 'Select an item to see its details',
    shortcutHint: 'Ctrl+F search · Ctrl+N new · Ctrl+G generate · Ctrl+L lock',
    itemMissing: 'Item not found',
    cloudNeedsRevalidate: 'The cloud account needs verification again',
    titleLabel: 'Title',
    titleRequired: 'Enter a title',
    createdItem: 'Created “{title}”',
    hintLoginTitle: 'e.g. GitHub',
    hintCardTitle: 'e.g. Visa credit card',
    hintNoteTitle: 'e.g. Server notes',
    hintIdentityTitle: 'e.g. Myself',
    groupLoginCredentials: 'Login credentials',
    fieldUsernameOrEmail: 'Username or email',
    generateStrongPassword: 'Generate a strong password',
    fieldTotpFull: 'Two-factor (TOTP)',
    scanQrCode: 'Scan QR code',
    preview: 'Preview',
    totpParams: '{alg} · {digits} digits · {period}s',
    addAction: 'Add',
    groupWebsite: 'Website',
    groupCardInfo: 'Card details',
    fieldName: 'Name',
    fieldValue: 'Value',
    sensitiveField: 'Sensitive field (hidden by default)',
    plainField: 'Plain field',
    groupContent: 'Content',
    notesPlaceholder: 'Visible only to you, end-to-end encrypted',
    customFieldsExample: 'e.g. security question, hardware token ID, API key',
    createItemTitle: 'New {kind}',
    editItemTitle: 'Edit {kind}',
    editorShortcuts: 'Ctrl+S save · Esc cancel',
    templateSection: 'Start from a template',
    templateAllFields: 'All fields',
    templateNote: 'A template pre-fills fields and trims the new-item form. Content you already typed is never overwritten.',
    urlMatchPickerLabel: 'Match mode (used for autofill)',
    urlMatchDomain: 'Domain',
    urlMatchHost: 'Host',
    urlMatchExact: 'Exact',
    urlMatchNever: 'Never',
    signInEyebrow: 'Sign in',
    signInTitle: 'Sign in to an existing account',
    signInSubtitle: 'You need the Secret Key from your Recovery Kit. The master password is only used on this device and is never sent to the server.',
    fillAllFields: 'Fill in the email, Secret Key and master password',
    deviceNameLabel: 'Device name',
    thisDeviceName: 'Name of this device',
    syncServerLabel: 'Sync server',
    verifying: 'Verifying…',
    newDeviceEyebrow: 'New device',
    verifyDeviceTitle: 'Verify this new device',
    verifyDeviceSubtitle: 'A new device always needs a second factor to protect the account. We emailed you a 6-digit code; you can also approve it on a signed-in device under Settings → Device management.',
    emailCodeLabel: 'Email code',
    emailCodeHint: '6 digits',
    verifyAndContinue: 'Verify and continue',
    waitingApproval: 'Waiting for another device to approve…',
    cancelSignIn: 'Cancel sign-in',
    recoverAccountTitle: 'Recover the account with the Recovery Kit',
    recoverAccountSubtitle: 'Recovery sets a new master password; the old recovery code and every old device session stop working and you get a new Recovery Kit.',
    recoverAccountAction: 'Recover account',
    cloudSetupRetry: 'Signup is not finished yet. Try again.',
    cloudBackupSaved: 'Encrypted backup saved. Restoring it still requires this account key material.',
    cloudBackupFailed: 'Saving the backup failed. Check the destination.',
    wipeAndReloginTitle: 'Erase local data and sign in again?',
    wipeAndReloginBody: 'This does not close the cloud account. Unsynced local items and the signup draft are lost permanently, and the locally stored Secret Key is deleted. Export a backup and keep the recovery material first; a signup timeout does not mean the cloud account was not created.',
    wipeAndReloginConfirm: 'Erase local data',
    wipeIncomplete: 'Erase did not finish. Try again; the cloud account was not closed.',
    cloudFinishTitle: 'Finish cloud account signup',
    cloudAttachTitle: 'Attach this vault to a cloud account',
    cloudFinishBody: 'The signup material is stored encrypted on this device. Signup completes only after the Java service confirms it; a retry reuses the same account and keys instead of generating new ones.',
    cloudAttachBody: 'This version uses cloud accounts. Existing items, the account identifier and keys are all kept; confirm with your current master password. If the same email belongs to a different account in the cloud, nothing is overwritten or merged.',
    javaServiceLabel: 'Java service: {url}',
    cloudVerifyAndFinish: 'Verify and finish cloud signup',
    exportBackupFirst: 'Export a local encrypted backup first',
    lockAndContinueLater: 'Lock and continue later',
    wipeAndReloginAction: 'Erase local data and sign in again',
    cloudZeroKnowledgeNote: 'Passwords, the Secret Key and item plaintext are never uploaded. After cloud signup, items stay readable offline and ciphertext syncs when online.',
    regenerate: 'Regenerate',
    generatorSubtitle: 'Generated with the system CSPRNG; the result only ever lives in local memory.',
    generatePassword: 'Generate password',
    lengthLabel: 'Length',
    excludeAmbiguous: 'Exclude look-alike characters',
    wordCountLabel: 'Words',
    separatorSpace: 'Space',
    capitalizeFirst: 'Capitalize first letter',
    includeDigits: 'Include digits',
    useThisPassword: 'Use this password',
    randomPasswordTab: 'Random password',
    passphraseTab: 'Passphrase',
    sidebarTagline: 'Only one person can open\nyour vault —',
    sidebarTaglineHighlight: 'you.',
    authAsideBody: 'Everything is encrypted on this device before it leaves. The server only stores ciphertext, so even a full database theft unlocks nothing.',
    featureZeroKnowledge: 'Zero knowledge',
    featureZeroKnowledgeBody: 'The master password is never uploaded, so the server can neither reset nor read it.',
    featureTwoFactorDerivation: 'Two-factor derivation',
    featureTwoFactorDerivationBody: 'Argon2id(master password) × 240-bit Secret Key makes offline cracking impractical.',
    featureItemEncryption: 'Per-item encryption',
    featureItemEncryptionBody: 'AES-256-GCM with an independent key and random IV for every item and revision.',
    authAsideFooter: 'VaultOne · a local-first vault for digital assets',
    clipboardCopiedToast: 'Copied {label}',
    clipboardClearCountdown: 'Clears from the clipboard in {seconds}s · kept out of clipboard history',
    clearNow: 'Clear now',
    qrScanTitle: 'Scan a two-factor QR code',
    qrScanHint: 'Place the QR code from the website inside the frame',
    saveFailedDisk: 'Saving failed. Check folder permissions and free space.',
    backupCardSavedTo: 'Backup card saved to {path}',
    backupCardFailed: 'Exporting the backup card failed. Check folder permissions and free space.',
    kitSavedTo: 'Recovery Kit saved to {path}',
    keyVerifyMismatch: 'This does not match the Secret Key stored on this device. Check it group by group against the Recovery Kit; I/L/O and 1/0 are easy to mix up.',
    verifyIncomplete: 'Verification did not finish. Try again later.',
    keyVerifyOk: 'Byte-for-byte identical to the Secret Key stored on this device; the recovery code is well formed.',
    recoveryCodeInvalid: 'The recovery code is malformed. It must start with R1- and contain 13 Crockford Base32 groups.',
    lastLocalBackup: 'Last local backup',
    neverRecorded: 'Never recorded',
    cloudBackupHistory: 'Cloud backup history',
    cloudBackupHistoryNone: 'None yet (the server-side backup endpoint is not implemented)',
    backupManagerBody: 'This device only records the fact of the last export, never the file path or contents. Both the Recovery Kit and the backup card can be re-exported here; because someone could otherwise grab credentials while the vault is unlocked, re-exporting asks you for the recovery material again.',
    verifyMaterials: 'Verify recovery material',
    verifyPassed: 'Verified',
    reExport: 'Re-export',
    recoveryKitPdfShort: 'Recovery Kit (PDF)',
    backupCardShort: 'Backup card (PNG 700×900)',
    viewSecretKey: 'View Secret Key',
    backupCredentialWarning: 'The Recovery Kit and the backup card are both equivalent to plaintext credentials. Store them to the same standard: print them or keep them on offline media, never in cloud drives, email or chat history.',
    securityCenterSubtitle: 'Every check runs on this device. Breach detection sends only the first 5 characters of the password SHA-1, so the server never learns your password.',
    auditFailed: 'Audit failed: {reason}',
    breachCheckFailed: 'Check failed: {reason}',
    statusGood: 'In good shape',
    statusNeedsWork: 'Needs work',
    statusActNow: 'Act now',
    noPasswordItems: 'No items with a password yet.',
    riskSummary: '{problems} of {total} items with a password are at risk.',
    weakPasswords: 'Weak passwords',
    reusedPasswords: 'Reused',
    breachedPasswords: 'Breached',
    twoFactorCoverage: 'Two-factor',
    healthTitle: 'Security checkup',
    healthScore: 'Health score',
    healthCheckedAt: 'Last checked: {time}',
    healthExpired: 'Report expired, run the checkup again',
    healthRerun: 'Run checkup',
    healthDimensionTitle: 'Dimension scores',
    healthDimensionSkipped: 'Skipped',
    healthStatsTitle: 'Scan stats',
    healthScanned: 'Passwords scanned',
    healthPasswordFields: 'Password fields',
    healthUnreadable: 'Unreadable items',
    healthBreachLabel: 'Breach check',
    healthBreachNotRun: 'Not run',
    healthBreachOk: 'OK',
    healthBreachUnavailable: 'Unavailable',
    healthBreachSkipped: 'Skipped',
    healthFindings: 'Findings',
    healthNoFindings: 'No problems found. Keep it up.',
    healthSnooze: 'Snooze 7 days',
    healthSnoozed: '{n} snoozed',
    healthOpenItem: 'Open item',
    healthActionRun: 'Run now',
    healthActionEnable: 'Turn on',
    healthActionGeneral: 'Open general settings',
    healthActionSystem: 'Open system settings',
    healthSeverityLow: 'Low',
    healthSeverityMedium: 'Medium',
    healthSeverityHigh: 'High',
    healthSeverityCritical: 'Critical',
    healthDimBreach: 'Breach',
    healthDimReuse: 'Reuse',
    healthDimStale: 'Outdated',
    healthDimEnvironment: 'Environment',
    healthDimSettings: 'Settings',
    healthDimScore: '-{used} / cap {cap}',
    healthChecklist: 'Checklist',
    healthChecklistProgress: '{done} of {total} done',
    healthRisks: 'Risks',
    healthRiskNone: 'No risks found.',
    healthGrid: 'Shortcuts',
    sidebarLayoutTitle: 'Home sections',
    sidebarLayoutSubtitle: 'Reorder and show or hide sidebar sections. Stored on this device only — screens differ, so syncing it would make both sides worse.',
    sidebarMoveUp: 'Move up',
    sidebarMoveDown: 'Move down',
    sidebarShow: 'Show in sidebar',
    sidebarKeepOne: 'Keep at least one section, or the sidebar becomes empty',
    sidebarResetLayout: 'Reset layout',
    lockOnExit: 'Lock on exit',
    lockOnExitSubtitle: 'Lock the vault as soon as the window closes (hides to tray).',
    maskPasswords: 'Hide passwords by default',
    maskPasswordsSubtitle: 'Show passwords as dots in the detail view; reveal with the eye button.',
    screenshotProtection: 'Screenshot protection',
    screenshotProtectionSubtitle: 'Prevent this window from being captured by screenshots or recording.',
    screenshotUnsupported: 'Screenshot protection is not supported on this platform',
    clipboardDisabled: 'Never clear',
    importPreviewTitle: 'Import preview',
    importPreviewSource: 'Detected source: {source}',
    importPreviewCounts: '{rows} rows, {items} importable, {skipped} skipped',
    importPreviewTruncated: 'Showing the first {n} rows',
    importPreviewWarnings: 'Parse warnings',
    importPreviewMapping: 'Field mapping',
    importPreviewUnmapped: 'Do not import',
    importPreviewColumn: 'Column {n}',
    importPreviewStrategy: 'Same-name items',
    importStrategySkip: 'Keep existing',
    importStrategyOverwrite: 'Overwrite with imported',
    importStrategyKeepBoth: 'Keep both',
    importPreviewConfirm: 'Start import',
    importPreviewEmpty: 'No importable items in this file',
    importUpdated: ', {n} overwritten',
    taxonomyManage: 'Tags and categories',
    taxonomyManageSubtitle: 'Rename or clean up tags and categories. Only the grouping changes; items are never deleted.',
    taxonomyRename: 'Rename',
    taxonomyRenameTagTitle: 'Rename tag',
    taxonomyRenameCategoryTitle: 'Rename category',
    taxonomyClearCategoryTitle: 'Clear category',
    taxonomyNewName: 'New name',
    taxonomyTagHint: 'Matching ignores case; renaming onto an existing tag merges them.',
    taxonomyCategoryHint: 'Subcategories move along; renaming onto an existing category merges them.',
    taxonomyClearBody: 'This clears "{name}" and its subcategories, affecting {n} items. The items themselves are not deleted.',
    taxonomyDeleteTagBody: 'This removes the tag "{name}" from {n} items. The items themselves are not deleted.',
    taxonomyAffected: '{n} items updated',
    taxonomyNoTags: 'No tags yet',
    taxonomyNoCategories: 'No categories yet',
    subListTagTitle: 'Tag: {name}',
    subListCategoryTitle: 'Category: {name}',
    subListCount: '{n} items',
    subListViewItems: 'View items',
    subListOpenInPage: 'Open in a page',
    fieldType: 'Field type',
    fieldKindText: 'Text',
    fieldKindDate: 'Date',
    fieldKindImage: 'Image',
    fieldDateHint: 'YYYY-MM-DD, e.g. 2026-10-02',
    fieldImageHint: 'Local path or https:// URL',
    fieldPickDate: 'Pick a date',
    fieldPickImage: 'Pick an image',
    pickImageUnavailable: 'No file picker on this platform; type the image location instead',
    fieldDateInvalid: 'Date must look like YYYY-MM-DD',
    fieldImageMissing: 'Enter an image location',
    imageLoadFailed: 'Image failed to load',
    transferHistory: 'Import and export history',
    transferHistorySubtitle: 'Recorded on this device only, sealed with the vault key, never synced.',
    transferImport: 'Import',
    transferNoHistory: 'No imports or exports yet',
    transferClear: 'Clear history',
    transferClearConfirm: 'Clear the local import and export history? Item data is unaffected.',
    transferSource: 'Source: {name}',
    transferNoSource: 'No source recorded',
    transferBytes: '{n} bytes',
    transferCounts: '{added} added, {updated} overwritten, {duplicates} duplicates, {skipped} skipped',
    profileEdit: 'Edit profile',
    profileNickname: 'Nickname',
    profileAvatar: 'Avatar URL',
    profileNoNickname: 'No nickname set',
    profileSaved: 'Profile updated',
    profileOffline: 'Offline: showing the local cache',
    profileNicknameHint: 'Up to 32 characters; may be empty',
    profileAvatarHint: 'http or https link; may be empty',
    profileCreatedAt: 'Registered {time}',
    inviteMine: 'My invite code',
    inviteNone: 'Not generated yet',
    inviteCopy: 'Copy invite code',
    inviteCopied: 'Invite code copied',
    inviteBind: 'Enter an invite code',
    inviteBindTitle: 'Enter the invite code you received',
    inviteBindHint: '12 letters or digits; spaces and hyphens are fine',
    inviteBindDone: 'Inviter bound',
    inviteBindNote: 'This binds once and cannot be changed.',
    backupNow: 'Back up now',
    backupReminder: 'Backup reminder',
    backupReminderHint: 'Turning this off removes the backup item from the checkup list.',
    breachCheck: 'Breached password check',
    breachCheckSubtitle: 'Compares against Have I Been Pwned with k-anonymity; needs a network connection.',
    breachCheckDone: 'Check finished: {count} items have a password found in public breaches.',
    startCheck: 'Start check',
    recheck: 'Check again',
    breachedAdvice: 'These passwords appear in public breach lists and attackers try them first. Replace them now.',
    breachTimes: 'Seen {count} times',
    weakAdvice: 'Easy to guess or crack with a dictionary attack.',
    strengthVeryWeak: 'Very weak',
    strengthWeak: 'Weak',
    strengthFair: 'Fair',
    strengthStrong: 'Strong',
    strengthVeryStrong: 'Very strong',
    reusedAdvice: 'One breached site puts every other site using it at risk.',
    reusedWith: 'Same as {count} other items',
    noProblems: 'Nothing found. Keep it up.',
    securityScore: 'Security score',
    conflictLoadFailed: 'Could not read conflicts right now. Try again.',
    conflictSavedLocal: 'Your choice is saved locally and waiting to sync. New conflicts can still appear before the remote confirms.',
    conflictCandidateChanged: 'The candidate changed. Check the refreshed version and choose again.',
    pickConflictHint: 'Pick a conflict to compare both versions',
    showHistoryToggle: 'Show history',
    noConflictRecords: 'No conflict records',
    noPendingConflicts: 'No conflicts waiting',
    untitledItem: 'Untitled item',
    refreshList: 'Refresh list',
    backToConflictList: 'Back to the conflict list',
    pickAConflict: 'Pick a conflict',
    candidateExpired: 'The candidate expired, so an old choice cannot be submitted. Refresh the candidate first.',
    resolutionQueued: 'The resolution is queued locally and waiting to sync. This does not mean it has synced yet.',
    historyReadOnly: 'History is read-only and cannot be submitted again.',
    refreshCandidate: 'Refresh candidate',
    hideSensitive: 'Hide sensitive content',
    showSensitive: 'Show sensitive content',
    conflictWholeItemOnly: 'The item type or the resolution conflicts, so the whole item must be kept from one side.',
    keepWholeLocal: 'Keep the whole local item',
    keepWholeRemote: 'Keep the whole remote item',
    wholeItemAdvice: 'Keeping the whole item adopts everything from that side; every field is compared below.',
    submitFieldChoices: 'Submit per-field choices ({chosen}/{total})',
    sensitiveHidden: 'Sensitive content hidden',
    deletedYes: 'Deleted',
    deletedNo: 'Not deleted',
    deletedUnknown: 'Unknown (the old baseline did not record it)',
    emptyValue: '(empty)',
    commonBase: 'Common base · v{revision}',
    adoptSide: 'Adopt {side}',
    sideRemote: 'Remote',
    sideWithRevision: '{side} · v{revision}',
    fieldConflictSuffix: '{field} · conflict',
    adoptFieldSide: 'Adopt {side} {field}',
    conflictFieldKind: 'Item type',
    conflictFieldDeleted: 'Deleted state',
    conflictFieldResolution: 'Resolution',
    conflictStatusPending: 'Pending',
    conflictStatusAwaitingSync: 'Waiting to sync',
    conflictStatusResolved: 'Resolved',
    conflictStatusSuperseded: 'Superseded',
    conflictCandidateStale: 'Candidate expired',
    pairingTitle: 'Connect the browser extension?',
    pairingBody: 'The VaultOne extension in “{name}” asks to connect. Check that the pairing code shown in the extension popup matches the one below; if it differs, or you did not start this, reject it.',
    rejectAction: 'Reject',
    allowPairing: 'Codes match, allow the connection',
    feedbackBug: 'Bug report',
    feedbackSuggestion: 'Feature idea',
    feedbackOther: 'Other',
    feedbackStatusInProgress: 'In progress',
    feedbackStatusResolved: 'Resolved',
    feedbackStatusUnknown: 'Unrecognized feedback status',
    feedbackClose: 'Close feedback',
    refreshAction: 'Refresh',
    feedbackExpired: 'This feedback page expired. Unlock and open it again.',
    feedbackWriteTab: 'Write feedback',
    feedbackHistoryTab: 'History',
    feedbackDraftNotice: 'Closing or locking clears this page, but does not retract feedback already sent.',
    feedbackConsentTitle: 'Support can read your feedback',
    feedbackConsentBody: 'The body and the optional contact go to support and are not part of the zero-knowledge vault.',
    feedbackNoSecrets: 'Never write passwords, the Secret Key, recovery codes or vault contents here.',
    feedbackNoAutoAttach: 'No email address, logs, device diagnostics or clipboard contents are attached automatically.',
    feedbackSubmitted: 'Submitted',
    feedbackWriteAnother: 'Write another',
    feedbackCategory: 'Category',
    feedbackBody: 'Feedback body',
    feedbackBodyHint: 'Describe the problem or idea; do not include sensitive information',
    feedbackBodyRequired: 'Enter the feedback body',
    feedbackBodyTooLong: 'The body is limited to 4000 UTF-16 code units',
    feedbackContact: 'Contact (optional)',
    feedbackContactTooLong: 'The contact is limited to 200 UTF-16 code units',
    feedbackConsentAck: 'I understand support can read the body and contact, and I agree to send it.',
    feedbackConsentRequired: 'Tick the consent box before submitting.',
    feedbackUnconfirmed: 'The submission result is unconfirmed, so the feedback may already be saved. The original request and id are kept and cannot be edited; retry as is, or check the history first.',
    feedbackSubmitting: 'Submitting…',
    feedbackRetryAsIs: 'Retry as is',
    feedbackSubmit: 'Submit feedback',
    feedbackDiscard: 'Discard this submission',
    feedbackClearDraft: 'Clear draft',
    feedbackDiscardWarning: 'This feedback may already be submitted. Discarding only clears this page — it does not delete the server record. Check the history first to avoid a duplicate.',
    feedbackCheckHistoryFirst: 'Check history first',
    feedbackConfirmDiscard: 'Confirm discarding',
    feedbackCancelDiscard: 'Keep editing',
    feedbackRetryHistory: 'Retry loading history',
    feedbackHistoryEmpty: 'No feedback yet. What you submit shows up here.',
    feedbackLoadEarlier: 'Load earlier entries',
    feedbackBackToHistory: 'Back to history',
    feedbackRetryDetail: 'Retry loading details',
    feedbackSubmittedAt: 'Submitted {time}',
    feedbackIdLabel: 'Feedback id: {id}',
    feedbackAccountLabel: 'Account id: {id}',
    feedbackSubmittedBody: 'Body',
    feedbackContactLabel: 'Contact',
    feedbackLatestReply: 'Latest reply from support',
    feedbackNoReply: 'No reply yet.',
    feedbackNetworkError: 'The network connection failed. Check it and try again.',
    feedbackSessionExpired: 'The cloud session expired. Sign in again and retry.',
    feedbackLocked: 'The vault is locked. Unlock it and come back.',
    feedbackNotConnected: 'Connect a cloud service in Settings before using feedback.',
    feedbackPrivacyRequired: 'Read and accept the Privacy Policy and Terms of Service first.',
    feedbackUnsupported: 'This server does not support feedback yet. Contact support instead.',
    feedbackForbidden: 'This device has no access to feedback. Check the device authorization.',
    feedbackInvalid: 'The feedback format is invalid. Check the category and lengths.',
    feedbackDuplicate: 'This submission id was already used. Check the history to confirm the result.',
    feedbackNotFound: 'The feedback is gone or expired. Refresh the history.',
    feedbackRateLimited: 'Too many submissions, or the limit was reached. Try again later.',
    feedbackUnavailable: 'The feedback service is temporarily unavailable. Try again later.',
    feedbackGenericError: 'The operation could not be completed. Try again later.',
    autofillUnknownApp: 'Unknown app',
    autofillSetupFirst: 'Open VaultOne and finish vault setup before using autofill.',
    autofillFillTo: 'Fill into {source}',
    autofillMatchedSite: 'Matches this site',
    autofillAppNoMatch: 'Login forms inside apps are not matched automatically; check that the item you picked belongs to this app.',
    autofillAllLogins: 'All logins',
    autofillOtherItems: 'Other items',
    autofillNoLogins: 'No logins found',
    autofillNoUsername: '(no username)',
    autofillSaveFailed: 'Saving failed',
    autofillSaveToVault: 'Save to VaultOne?',
    autofillUpdatePassword: 'Update the password for “{title}”?',
    autofillUpdate: 'Update',
    autofillDontSave: 'Do not save',
    tplLoginWebsite: 'Website account',
    tplLoginWebsiteDesc: 'Username, password, URLs and two-factor',
    tplLoginApi: 'API / developer account',
    tplLoginApiDesc: 'Login credentials plus API keys, secrets and other sensitive fields',
    tplLoginApiHint: 'For example: OpenAI API',
    tplLoginDevice: 'Server / device',
    tplLoginDeviceDesc: 'Host, port, account and device credentials',
    tplLoginDeviceHint: 'For example: production server',
    tplCardBank: 'Bank card',
    tplCardBankDesc: 'Card number, expiry, security code and PIN',
    tplCardMembership: 'Membership / loyalty card',
    tplCardMembershipDesc: 'Member number, tier and points',
    tplCardMembershipHint: 'For example: airline membership card',
    tplNoteSecureDesc: 'Free text, good for recovery codes and configuration notes',
    tplNoteApi: 'Server / API keys',
    tplNoteApiDesc: 'Host, account, key and notes',
    tplNoteApiHint: 'For example: production API key',
    tplNoteWifi: 'Wi-Fi details',
    tplNoteWifiDesc: 'Network name, password and security type',
    tplNoteWifiHint: 'For example: home Wi-Fi',
    tplIdentityPersonal: 'Personal details',
    tplIdentityPersonalDesc: 'Name, email, phone, ID number and address',
    tplIdentityWork: 'Company / work identity',
    tplIdentityWorkDesc: 'Company, role, employee number and contact details',
    tplIdentityWorkHint: 'For example: work email identity',
    coreVaultLocked: 'The vault is locked. Unlock it again to continue.',
    corePrivacyRequired: 'Read and accept the Privacy Policy and Terms of Service first.',
    coreServerMismatch: 'The server bound to this account differs from the Java configuration. Verify the connection again.',
    configProdHttpsRequired: 'Release builds require an explicit, valid HTTPS Java service URL.',
    configServerInvalid: 'Invalid server URL. On-device HTTP debugging needs VAULTONE_ALLOW_LAN_HTTP plus a private-network IP.',
    accountCancelled: 'The account operation was cancelled',
    secureStorageIncomplete: 'Secure storage or registration did not finish. Keep your recovery material and try again.',
    unlockDraftFirst: 'Unlock the account draft first',
    finishCloudFirst: 'Finish cloud account registration first',
    missingSecretKey: 'This device has no stored Secret Key. Enter the one from the Recovery Kit.',
    unlockVaultPrompt: 'Unlock the VaultOne vault',
    changePasswordUnconfirmed: 'The password change is unconfirmed. The old local password still unlocks; retry with the same new password. Other devices may already use the new one.',
    reverifyKeepData: 'Verify the Java service connection again; your data and pending items are kept',
    reverifyNoRequest: 'Verify the Java service connection again; no request is sent to the old server automatically',
    accountDeletedLocally: 'The cloud account is deleted. Local encrypted data is kept; export a backup or erase it explicitly.',
    trayOpen: 'Open VaultOne',
    trayQuickSearch: 'Quick search',
    trayQuit: 'Quit',
    docExportedViaPanel: 'Exported through the system panel',
    docSecretKeyLabel: 'SECRET KEY · DEVICE KEY',
    docRecoveryCodeLabel: 'RECOVERY CODE',
    docEmailLabel: 'ACCOUNT EMAIL',
    docMasterPasswordLabel: 'MASTER PASSWORD (optional, handwritten)',
    docLoginNeedsBoth: 'Signing in on a new device requires both the master password and the Secret Key.',
    docGeneratedFooter: 'Generated {date} · Only you can open your vault.',
    kitDocTitle: 'Recovery Kit',
    kitLead: 'This is the only credential that can recover your vault. VaultOne is zero-knowledge: we cannot reset your master password or restore your data for you. Print this file or keep it offline; never store it in a cloud drive, email or chat history.',
    kitResetHint: 'If you forget the master password, reset it with the Secret Key plus the recovery code. That immediately invalidates this recovery code, so save the new Recovery Kit.',
    kitAccountId: 'Account ID: {id}',
    kitFileName: 'VaultOne-Recovery-Kit.pdf',
    kitTypeGroup: 'PDF',
    cardDocBadge: 'RECOVERY KIT · BACKUP CARD',
    cardDocTitle: 'Keep this card offline',
    cardLead: 'It is the only credential that can recover your vault. VaultOne is zero-knowledge: we cannot reset your master password or restore your data for you. Print it as a physical card or keep it on offline media; never put it in a cloud drive, email or chat history.',
    cardResetHint: 'If you forget the master password, reset it with the Secret Key plus the recovery code. That immediately invalidates this recovery code, so save the new Recovery Kit.',
    cardFileName: 'VaultOne-backup-card.png',
    cardTypeGroup: 'PNG image',
    cardEncodeFailed: 'Encoding the backup card failed',
    moveToTrash: 'Move to trash',
    moveToTrashConfirmTitle: 'Move to trash?',
    moveToTrashConfirmBody: '“{title}” moves to the trash and can be restored at any time.',
    movedToTrashTitle: 'Moved to trash',
    movedToTrashBody: '“{title}” is now in the trash and can be restored at any time.',
    purgeConfirmTitle: 'Delete permanently?',
    purgeConfirmBody:
        '“{title}” will be erased from this device and cannot be recovered. Data already synced to the cloud is not wiped from other devices.',
    purgeAction: 'Delete permanently',
    purgedTitle: 'Permanently deleted “{title}”',
    fieldUsername: 'Username',
    fieldPassword: 'Password',
    fieldTotp: 'Code',
    urlMatchSuffix: '{label} match',
    urlFieldLabel: 'Website · {label} match',
    fieldWebsite: 'Website',
    openInBrowser: 'Open in browser',
    fieldNotes: 'Notes',
    groupTaxonomy: 'Tags and category',
    tagLabel: 'Tags',
    tagInputHint: 'Type a tag and press Enter',
    tagAdd: 'Add tag',
    tagLimitReached: 'At most {count} tags',
    tagRemoveTooltip: 'Remove the tag “{tag}”',
    categoryHint: 'For example: work / personal / finance',
    filterByTagTitle: 'Filter by tag',
    filterByCategoryTitle: 'Filter by category',
    clearFilter: 'Clear filter',
    noTagsInVault: 'No tags yet',
    noCategory: 'Uncategorized',
    allTags: 'All tags',
    groupCategories: 'Groups',
    noCategoriesYet: 'No categories yet',
    categoryPathHint: 'Separate levels with /, for example: work/production',
    categoryTreeTooltip: 'Hierarchical categories; selecting one includes its subcategories',
    fieldCardholder: 'Cardholder',
    fieldCardNumber: 'Card number',
    fieldExpiry: 'Expiry',
    fieldCvv: 'Security code',
    fieldPin: 'PIN',
    fieldFullName: 'Full name',
    fieldPhone: 'Phone',
    fieldIdNumber: 'ID number',
    fieldAddress: 'Address',
    fieldCompany: 'Company',
    fieldEmail: 'Email',
    customFields: 'Custom fields',
    passwordHistory: 'Password history',
    historyPassword: 'Previous password',
    copyTotp: 'Copy code',
    labelEncrypted: 'Encrypted',
    labelHide: 'Hide',
    purgeErrorUnsynced: 'This item is not synced to the cloud yet. Finish syncing before deleting it permanently.',
    purgeErrorNotFound: 'The item no longer exists. Refresh the trash.',
    purgeErrorLocked: 'The vault is locked. Unlock it and try again.',
    purgeErrorGeneric: 'Could not delete it permanently. Try again later.',
    restoreAction: 'Restore',
    restoredTitle: 'Restored “{title}”',
    unfavorite: 'Remove from favorites',
    editAction: 'Edit',
    labelCreated: 'Created',
    labelUpdated: 'Updated',
    labelRevision: 'Revision',
    labelKind: 'Type',
    labelReveal: 'Show',
    totpOnce: 'One-time code',
    totpCountdown: '{seconds}s left',
    cardExpired: 'Expired',
    cardExpiresSoon: 'Expires soon',
    onboardWelcomeTitle: 'Welcome to VaultOne',
    onboardWelcomeBody: 'Passwords, accounts, two-factor codes and keys —\nencrypted on your device, opened only by you.',
    onboardRegister: 'Create a cloud account',
    onboardHaveAccount: 'I already have an account',
    onboardAllDevicesLost: 'Lost every device? Restore with the Recovery Kit',
    onboardNetworkNote: 'Signing up and in requires a network connection. Passwords are encrypted locally, usable offline and synced automatically.',
    onboardStepOne: 'Step 01 / 02',
    onboardSetMasterPassword: 'Set your master password',
    onboardSetMasterPasswordBody: 'The master password is the only password you have to remember. It never leaves this device, and nobody can recover it for you.',
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
