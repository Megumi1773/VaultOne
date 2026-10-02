//! 安全体检（计划书 §5.2）：0–100 健康报告、六维扣分、发现项与忽略（snooze）。
//!
//! 这里只做**纯计算**：输入是已解密条目、泄露检测结果、设备环境探测结果与安全设置快照，
//! 输出是可直接展示的报告。设备探测由平台层（`app/rust`）提供，内核不碰平台 API，
//! 因此这套规则可以在任何平台上完整单测。
//!
//! 评分口径（写死并可复核）：总分 = `100 - min(100, 各维度扣分之和)`；
//! 每个维度有独立上限，单类问题再多也不会把分数压到负值以外。每项扣分常量见
//! `DIMENSION_RULES`，调整规则必须同步更新本模块的测试与 docs/11。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::item::Item;

/// 报告有效期：超过 24 小时视为过期（计划书 §5.2）。
pub const REPORT_TTL_SECONDS: i64 = 24 * 60 * 60;

/// 「长期未更新」的判定阈值：180 天。
pub const STALE_PASSWORD_SECONDS: i64 = 180 * 24 * 60 * 60;

/// 体检维度。每个维度有独立扣分上限，互不挤占。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Dimension {
    Breach,
    Weak,
    Reuse,
    Stale,
    Environment,
    Settings,
}

impl Dimension {
    pub const ALL: [Dimension; 6] =
        [Dimension::Breach, Dimension::Weak, Dimension::Reuse, Dimension::Stale, Dimension::Environment, Dimension::Settings];

    /// 该维度的扣分上限（计划书 §5.2）。
    pub fn cap(self) -> u32 {
        match self {
            Dimension::Breach => 50,
            Dimension::Weak => 24,
            Dimension::Reuse => 20,
            Dimension::Stale => 15,
            Dimension::Environment => 30,
            Dimension::Settings => 30,
        }
    }

    /// 单个命中项的扣分。取「上限 / 4 向上取整」量级：约四项饱和，既让严重问题立刻反映，
    /// 也不至于一条弱密码就把总分打穿。
    pub fn per_hit(self) -> u32 {
        match self {
            Dimension::Breach => 25,
            Dimension::Weak => 6,
            Dimension::Reuse => 5,
            Dimension::Stale => 3,
            Dimension::Environment => 6,
            Dimension::Settings => 10,
        }
    }
}

/// 发现项分类（计划书 §5.2）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FindingCategory {
    Vault,
    Breach,
    Environment,
    Settings,
}

/// 发现项严重度。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Severity {
    Low,
    Medium,
    High,
    Critical,
}

/// 发现项可执行的动作（计划书 §5.2）。不带参数：需要跳转条目时用 `item_ids` 的第一个。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FindingAction {
    None,
    OpenItem,
    OpenCheckup,
    Biometrics,
    AutoLock,
    Autofill,
    PrivateKey,
    GeneralSettings,
    SystemSettings,
}

/// 泄露检测状态（计划书 §5.2）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BreachStatus {
    /// 还没跑过。
    NotRun,
    /// 跑过且可用。
    Ok,
    /// 网络或服务不可用。
    Unavailable,
    /// 用户主动跳过。
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Finding {
    /// 稳定 id：同一条问题在多次体检之间保持不变，忽略（snooze）才能跨次生效。
    pub id: String,
    pub category: FindingCategory,
    pub severity: Severity,
    pub title: String,
    pub description: String,
    pub action: FindingAction,
    /// 关联条目（可能为空）。
    pub item_ids: Vec<String>,
    /// 命中数量（条目数或问题项数）。
    pub count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DimensionScore {
    pub dimension: Dimension,
    pub cap: u32,
    pub deduction: u32,
    /// 该维度本次是否被跳过（例如平台不支持环境探测、泄露检测未运行）。
    pub skipped: bool,
}

/// 设备环境探测结果（计划书 §5.2）。由平台层填写；`supported = false` 表示该平台无法探测。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentReport {
    pub supported: bool,
    pub debugger_attached: bool,
    pub emulator: bool,
    pub adb_enabled: bool,
    pub developer_options: bool,
    /// 设备是否已设锁屏（安全）。
    pub device_secure: bool,
    /// 设备是否已被攻破（root / 越狱）。
    pub compromised: bool,
}

impl EnvironmentReport {
    /// 平台不支持探测时的取值：不扣分，并在报告里标记该维度已跳过。
    pub const UNSUPPORTED: EnvironmentReport = EnvironmentReport {
        supported: false,
        debugger_attached: false,
        emulator: false,
        adb_enabled: false,
        developer_options: false,
        device_secure: true,
        compromised: false,
    };
}

/// 安全设置快照，用于「设置项」维度。只包含与本体检相关的项。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecuritySettings {
    /// 自动锁定分钟数；0 表示关闭。
    pub auto_lock_minutes: u32,
    /// 退出应用时是否锁定。
    pub lock_on_exit: bool,
    /// 剪贴板自动清除秒数；0 表示不清除。
    pub clipboard_clear_seconds: u32,
    /// 设备是否支持生物识别。
    pub biometrics_available: bool,
    /// 是否已启用生物识别解锁。
    pub biometrics_enabled: bool,
    /// 是否开启了详细诊断日志。
    pub verbose_logs: bool,
}

impl SecuritySettings {
    /// 测试与默认场景：一切都已妥善配置。
    pub const SECURE_DEFAULTS: SecuritySettings = SecuritySettings {
        auto_lock_minutes: 5,
        lock_on_exit: true,
        clipboard_clear_seconds: 30,
        biometrics_available: false,
        biometrics_enabled: false,
        verbose_logs: false,
    };
}

/// 忽略一条发现项直到某个时刻。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snooze {
    pub finding_id: String,
    /// 忽略到期时间（Unix 秒）。
    pub until: i64,
}

impl Snooze {
    pub fn is_active(&self, now: i64) -> bool {
        self.until > now
    }
}

/// 体检输入。字段都是借用或 Copy，避免为大保险库复制数据。
pub struct HealthInputs<'a> {
    pub items: &'a [Item],
    /// 条目 id → 泄露次数（只含已查询且 > 0 的条目）。
    pub breaches: &'a HashMap<String, u64>,
    pub breach_status: BreachStatus,
    pub environment: EnvironmentReport,
    pub settings: SecuritySettings,
    /// 解密失败、未能纳入扫描的条目数。
    pub unreadable_items: usize,
    pub now: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HealthReport {
    /// 0–100。
    pub score: u32,
    pub checked_at: i64,
    pub dimensions: Vec<DimensionScore>,
    pub findings: Vec<Finding>,
    /// 已扫描的密码条数。
    pub scanned_passwords: usize,
    /// 密码字段总数（含空值字段不计）。
    pub password_fields: usize,
    pub unreadable_items: usize,
    pub breach_status: BreachStatus,
}

impl HealthReport {
    /// 报告是否已过期（超过 24 小时）。
    pub fn is_stale(&self, now: i64) -> bool {
        now.saturating_sub(self.checked_at) > REPORT_TTL_SECONDS
    }

    /// 忽略到期的发现项过滤掉后，剩下的有效发现项。
    pub fn active_findings<'a>(&'a self, snoozes: &'a [Snooze], now: i64) -> Vec<&'a Finding> {
        self.findings.iter().filter(|f| !snoozes.iter().any(|s| s.finding_id == f.id && s.is_active(now))).collect()
    }
}

fn cap_to(cap: u32, per_hit: u32, hits: usize) -> u32 {
    (per_hit.saturating_mul(hits.min(u32::MAX as usize) as u32)).min(cap)
}

/// 当前密码的「开始时间」：最近一次改密的时间，没有历史则用创建时间。
///
/// 改密时旧密码会被推入 `password_history` 并记录当时的时间，因此历史里的最大值
/// 就是当前密码生效的时刻。
fn password_set_at(item: &Item) -> i64 {
    item.data.password_history.iter().map(|h| h.t).max().unwrap_or(item.data.created_at)
}

/// 运行一次完整体检。
pub fn checkup(input: HealthInputs<'_>) -> HealthReport {
    let now = input.now;
    let mut findings: Vec<Finding> = Vec::new();
    let mut deductions: HashMap<Dimension, u32> = HashMap::new();
    let mut skipped: HashMap<Dimension, bool> = HashMap::new();

    // 只统计真正带密码的条目；空字符串不算密码字段。
    let with_password: Vec<&Item> = input.items.iter().filter(|i| i.data.password.as_deref().is_some_and(|p| !p.is_empty())).collect();
    let password_fields = with_password.len();

    // ---------- 泄露 ----------
    let mut breached: Vec<&Item> = with_password.iter().copied().filter(|i| input.breaches.contains_key(&i.id)).collect();
    breached.sort_by(|a, b| a.id.cmp(&b.id));
    match input.breach_status {
        BreachStatus::Ok => {
            if !breached.is_empty() {
                *deductions.entry(Dimension::Breach).or_default() +=
                    cap_to(Dimension::Breach.cap(), Dimension::Breach.per_hit(), breached.len());
                findings.push(Finding {
                    id: "breach.passwords".into(),
                    category: FindingCategory::Breach,
                    severity: Severity::Critical,
                    title: "密码已出现在公开泄露数据中".into(),
                    description: "这些密码在公开泄露库里可以查到，攻击者会优先尝试，请立即更换。".into(),
                    action: FindingAction::OpenItem,
                    item_ids: breached.iter().map(|i| i.id.clone()).collect(),
                    count: breached.len(),
                });
            }
        }
        BreachStatus::NotRun | BreachStatus::Unavailable => {
            skipped.insert(Dimension::Breach, true);
            let unavailable = input.breach_status == BreachStatus::Unavailable;
            findings.push(Finding {
                id: "breach.notRun".into(),
                category: FindingCategory::Breach,
                severity: Severity::Medium,
                title: if unavailable { "泄露检测暂时不可用".into() } else { "尚未运行泄露检测".into() },
                description: if unavailable {
                    "网络或服务不可用，本次未检查泄露；联网后可重试。".into()
                } else {
                    "运行泄露检测才能发现已泄露的密码；只发送密码 SHA-1 的前 5 位。".into()
                },
                action: FindingAction::OpenCheckup,
                item_ids: Vec::new(),
                count: 0,
            });
        }
        BreachStatus::Skipped => {
            // 用户主动跳过：不计扣分，也不提示。
            skipped.insert(Dimension::Breach, true);
        }
    }

    // ---------- 弱密码 ----------
    let mut weak: Vec<&Item> = Vec::new();
    // ---------- 复用 ----------
    let mut by_password: HashMap<&str, Vec<&Item>> = HashMap::new();
    for item in &with_password {
        let pw = item.data.password.as_deref().unwrap_or_default();
        by_password.entry(pw).or_default().push(item);
    }
    for item in &with_password {
        let pw = item.data.password.as_deref().unwrap_or_default();
        let mut inputs = vec![item.data.title.as_str()];
        if let Some(u) = item.data.username.as_deref() {
            inputs.push(u);
        }
        if crate::security::estimate_strength(pw, &inputs).score <= crate::security::WEAK_SCORE_THRESHOLD {
            weak.push(item);
        }
    }
    weak.sort_by(|a, b| a.id.cmp(&b.id));
    if !weak.is_empty() {
        *deductions.entry(Dimension::Weak).or_default() += cap_to(Dimension::Weak.cap(), Dimension::Weak.per_hit(), weak.len());
        findings.push(Finding {
            id: "vault.weak".into(),
            category: FindingCategory::Vault,
            severity: Severity::High,
            title: "存在弱密码".into(),
            description: "这些密码容易被猜测或字典攻击破解，建议改用更长的随机密码。".into(),
            action: FindingAction::OpenItem,
            item_ids: weak.iter().map(|i| i.id.clone()).collect(),
            count: weak.len(),
        });
    }

    // 复用的「被牵连」条目数 = 共享同一密码的全部条目（每组第一个也列出，
    // 因为用户需要看到这一组里有哪几条要改）。
    let mut reused: Vec<&Item> = Vec::new();
    for group in by_password.values() {
        if group.len() > 1 {
            let mut sorted = group.clone();
            sorted.sort_by(|a, b| a.id.cmp(&b.id));
            reused.extend(sorted);
        }
    }
    reused.sort_by(|a, b| a.id.cmp(&b.id));
    if !reused.is_empty() {
        *deductions.entry(Dimension::Reuse).or_default() += cap_to(Dimension::Reuse.cap(), Dimension::Reuse.per_hit(), reused.len());
        findings.push(Finding {
            id: "vault.reuse".into(),
            category: FindingCategory::Vault,
            severity: Severity::High,
            title: "存在重复使用的密码".into(),
            description: "一个网站泄露会连带其他使用同一密码的网站失守；请为每个站点设置独立密码。".into(),
            action: FindingAction::OpenItem,
            item_ids: reused.iter().map(|i| i.id.clone()).collect(),
            count: reused.len(),
        });
    }

    // ---------- 长期未更新 ----------
    let cutoff = now.saturating_sub(STALE_PASSWORD_SECONDS);
    let mut stale: Vec<&Item> = with_password.iter().copied().filter(|i| password_set_at(i) < cutoff).collect();
    stale.sort_by(|a, b| a.id.cmp(&b.id));
    if !stale.is_empty() {
        *deductions.entry(Dimension::Stale).or_default() += cap_to(Dimension::Stale.cap(), Dimension::Stale.per_hit(), stale.len());
        findings.push(Finding {
            id: "vault.stale".into(),
            category: FindingCategory::Vault,
            severity: Severity::Low,
            title: "密码长期未更新".into(),
            description: "这些密码超过 180 天没有更换；对重要账户建议定期轮换。".into(),
            action: FindingAction::OpenItem,
            item_ids: stale.iter().map(|i| i.id.clone()).collect(),
            count: stale.len(),
        });
    }

    // ---------- 设备环境 ----------
    if input.environment.supported {
        let env = &input.environment;
        let mut hits = 0usize;
        let mut push = |hits: &mut usize, id: &str, severity: Severity, title: &str, description: &str| {
            *hits += 1;
            findings.push(Finding {
                id: format!("environment.{id}"),
                category: FindingCategory::Environment,
                severity,
                title: title.into(),
                description: description.into(),
                action: FindingAction::SystemSettings,
                item_ids: Vec::new(),
                count: 1,
            });
        };
        if env.compromised {
            push(&mut hits, "compromised", Severity::Critical, "设备已被攻破", "设备存在 root / 越狱痕迹，保险库数据可能被其他应用读取。");
        }
        if env.debugger_attached {
            push(&mut hits, "debugger", Severity::Critical, "检测到调试器", "有调试器附着在本应用上，内存中的明文可能被读取。");
        }
        if !env.device_secure {
            push(&mut hits, "lockScreen", Severity::High, "设备未设置锁屏", "没有锁屏时，拿到设备的人可以直接打开应用。");
        }
        if env.adb_enabled {
            push(&mut hits, "adb", Severity::Medium, "ADB 已开启", "调试桥开启后，连接的电脑可以读写应用数据。");
        }
        if env.emulator {
            push(&mut hits, "emulator", Severity::Medium, "运行在模拟器中", "模拟器环境不可信，不建议在其中处理真实凭据。");
        }
        if env.developer_options {
            push(&mut hits, "developerOptions", Severity::Low, "开发者选项已开启", "开发者选项会放开一些调试能力，日常使用建议关闭。");
        }
        if hits > 0 {
            *deductions.entry(Dimension::Environment).or_default() +=
                cap_to(Dimension::Environment.cap(), Dimension::Environment.per_hit(), hits);
        }
    } else {
        skipped.insert(Dimension::Environment, true);
    }

    // ---------- 设置项 ----------
    let s = input.settings;
    let mut setting_hits = 0usize;
    let mut settings_finding = |hits: &mut usize, id: &str, severity: Severity, title: &str, description: &str, action: FindingAction| {
        *hits += 1;
        findings.push(Finding {
            id: format!("settings.{id}"),
            category: FindingCategory::Settings,
            severity,
            title: title.into(),
            description: description.into(),
            action,
            item_ids: Vec::new(),
            count: 1,
        });
    };
    if s.auto_lock_minutes == 0 {
        settings_finding(
            &mut setting_hits,
            "autoLock",
            Severity::High,
            "未启用自动锁定",
            "离开电脑时不锁定，保险库会一直保持解锁状态。",
            FindingAction::AutoLock,
        );
    }
    if !s.lock_on_exit {
        settings_finding(
            &mut setting_hits,
            "lockOnExit",
            Severity::Medium,
            "退出应用时不锁定",
            "关闭窗口后保险库仍处于解锁状态，下次打开无需验证。",
            FindingAction::AutoLock,
        );
    }
    if s.clipboard_clear_seconds == 0 {
        settings_finding(
            &mut setting_hits,
            "clipboard",
            Severity::Medium,
            "剪贴板不会自动清除",
            "复制出的密码会一直留在系统剪贴板里，可能被其他应用读取。",
            FindingAction::GeneralSettings,
        );
    }
    if s.biometrics_available && !s.biometrics_enabled {
        settings_finding(
            &mut setting_hits,
            "biometrics",
            Severity::Low,
            "可使用生物识别解锁",
            "本机支持指纹 / 人脸解锁，启用后解锁更快，且不必反复输入主密码。",
            FindingAction::Biometrics,
        );
    }
    if s.verbose_logs {
        settings_finding(
            &mut setting_hits,
            "verboseLogs",
            Severity::Low,
            "详细诊断日志已开启",
            "详细日志会记录更多运行细节，排查完问题后建议关闭。",
            FindingAction::GeneralSettings,
        );
    }
    if setting_hits > 0 {
        *deductions.entry(Dimension::Settings).or_default() +=
            cap_to(Dimension::Settings.cap(), Dimension::Settings.per_hit(), setting_hits);
    }

    // ---------- 汇总 ----------
    let dimensions: Vec<DimensionScore> = Dimension::ALL
        .iter()
        .map(|d| DimensionScore {
            dimension: *d,
            cap: d.cap(),
            deduction: deductions.get(d).copied().unwrap_or(0).min(d.cap()),
            skipped: skipped.get(d).copied().unwrap_or(false),
        })
        .collect();
    let total: u32 = dimensions.iter().map(|d| d.deduction).sum();
    let score = 100u32.saturating_sub(total.min(100));

    // 严重度高的排前面，同级按 id 稳定排序，保证界面顺序可复现。
    findings.sort_by(|a, b| b.severity.cmp(&a.severity).then_with(|| a.id.cmp(&b.id)));

    HealthReport {
        score,
        checked_at: now,
        dimensions,
        findings,
        scanned_passwords: password_fields,
        password_fields,
        unreadable_items: input.unreadable_items,
        breach_status: input.breach_status,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ItemData, ItemKind, PasswordHistoryEntry};

    fn login(id: &str, pw: &str) -> Item {
        let mut data = ItemData::new(ItemKind::Login, id);
        data.password = Some(pw.into());
        data.created_at = 1_000;
        data.updated_at = 1_000;
        Item { id: id.into(), vault_id: "v".into(), revision: 1, data }
    }

    const STRONG_A: &str = "vK9#qLm2$Zp8!wRt5@Yx";
    const STRONG_B: &str = "Hm4%Tb7&Ns1*Qe6^Uj3!Ld";

    fn report(
        items: &[Item],
        breaches: &HashMap<String, u64>,
        status: BreachStatus,
        env: EnvironmentReport,
        settings: SecuritySettings,
        now: i64,
    ) -> HealthReport {
        checkup(HealthInputs { items, breaches, breach_status: status, environment: env, settings, unreadable_items: 0, now })
    }

    fn dim(r: &HealthReport, d: Dimension) -> DimensionScore {
        *r.dimensions.iter().find(|x| x.dimension == d).unwrap()
    }

    #[test]
    fn clean_vault_scores_100_and_has_no_findings() {
        let items = vec![login("a", STRONG_A), login("b", STRONG_B)];
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        assert_eq!(r.score, 100);
        assert!(r.findings.is_empty(), "{:?}", r.findings);
        assert_eq!(r.scanned_passwords, 2);
        assert!(dim(&r, Dimension::Environment).skipped, "平台不支持探测时该维度应标记跳过");
        assert_eq!(dim(&r, Dimension::Environment).deduction, 0);
    }

    #[test]
    fn each_dimension_never_exceeds_its_cap() {
        // 大量命中：每个维度都必须停在 cap，而不是随数量线性增长。
        let mut items = Vec::new();
        for i in 0..40 {
            items.push(login(&format!("weak{i}"), "123456"));
        }
        let mut breaches = HashMap::new();
        for i in 0..40 {
            breaches.insert(format!("weak{i}"), 100);
        }
        let env = EnvironmentReport {
            supported: true,
            debugger_attached: true,
            emulator: true,
            adb_enabled: true,
            developer_options: true,
            device_secure: false,
            compromised: true,
        };
        let settings = SecuritySettings {
            auto_lock_minutes: 0,
            lock_on_exit: false,
            clipboard_clear_seconds: 0,
            biometrics_available: true,
            biometrics_enabled: false,
            verbose_logs: true,
        };
        let r = report(&items, &breaches, BreachStatus::Ok, env, settings, 1_000);
        for d in Dimension::ALL {
            let score = dim(&r, d);
            assert!(score.deduction <= d.cap(), "{d:?} 扣分 {} 超过上限 {}", score.deduction, d.cap());
        }
        assert_eq!(r.score, 0, "全部维度拉满时总分为 0");
        assert_eq!(dim(&r, Dimension::Breach).deduction, 50);
        assert_eq!(dim(&r, Dimension::Weak).deduction, 24);
        assert_eq!(dim(&r, Dimension::Reuse).deduction, 20);
        assert_eq!(dim(&r, Dimension::Environment).deduction, 30);
        assert_eq!(dim(&r, Dimension::Settings).deduction, 30);
    }

    #[test]
    fn score_is_100_minus_capped_deductions() {
        let items = vec![login("a", "123456")]; // 弱密码
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        // 弱密码一项命中：per_hit 6 → 94 分。
        assert_eq!(dim(&r, Dimension::Weak).deduction, 6);
        assert_eq!(r.score, 94);
    }

    #[test]
    fn breach_not_run_or_unavailable_skips_dimension_and_warns() {
        let items = vec![login("a", STRONG_A)];
        for (status, expect_unavailable) in [(BreachStatus::NotRun, false), (BreachStatus::Unavailable, true)] {
            let r = report(&items, &HashMap::new(), status, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
            assert!(dim(&r, Dimension::Breach).skipped);
            assert_eq!(dim(&r, Dimension::Breach).deduction, 0, "没跑过检测不应扣分");
            let f = r.findings.iter().find(|f| f.id == "breach.notRun").expect("应有提示");
            assert_eq!(f.severity, Severity::Medium);
            assert_eq!(f.action, FindingAction::OpenCheckup);
            assert_eq!(f.description.contains("网络或服务不可用"), expect_unavailable);
        }

        // 用户主动跳过：既不扣分也不提示。
        let r = report(
            &items,
            &HashMap::new(),
            BreachStatus::Skipped,
            EnvironmentReport::UNSUPPORTED,
            SecuritySettings::SECURE_DEFAULTS,
            1_000,
        );
        assert!(dim(&r, Dimension::Breach).skipped);
        assert!(r.findings.iter().all(|f| f.id != "breach.notRun"));
    }

    #[test]
    fn reuse_counts_all_members_of_a_shared_password() {
        let items = vec![login("a", STRONG_A), login("b", STRONG_A), login("c", STRONG_A), login("d", STRONG_B)];
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        let f = r.findings.iter().find(|f| f.id == "vault.reuse").unwrap();
        assert_eq!(f.count, 3, "同一密码的三个条目都应被列出");
        assert_eq!(f.item_ids, vec!["a", "b", "c"]);
        assert_eq!(dim(&r, Dimension::Reuse).deduction, 15, "3 × 5");
    }

    #[test]
    fn stale_uses_last_password_change_not_item_update() {
        let now = 400 * 24 * 60 * 60;
        let mut old = login("old", STRONG_A);
        old.data.updated_at = now; // 最近编辑过，但密码没换
        old.data.created_at = 0;
        let mut fresh = login("fresh", STRONG_B);
        fresh.data.created_at = now - 1000;
        fresh.data.password_history = vec![PasswordHistoryEntry { p: "prev".into(), t: now - 1000 }];

        let items = vec![old, fresh];
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, now);
        let f = r.findings.iter().find(|f| f.id == "vault.stale").unwrap();
        assert_eq!(f.item_ids, vec!["old"], "只看密码何时设置，不看条目何时编辑");
    }

    #[test]
    fn environment_findings_map_severity_and_skip_when_unsupported() {
        let items = vec![login("a", STRONG_A)];
        let env = EnvironmentReport {
            supported: true,
            debugger_attached: true,
            emulator: false,
            adb_enabled: false,
            developer_options: true,
            device_secure: false,
            compromised: false,
        };
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, env, SecuritySettings::SECURE_DEFAULTS, 1_000);
        let ids: Vec<&str> = r.findings.iter().filter(|f| f.category == FindingCategory::Environment).map(|f| f.id.as_str()).collect();
        assert_eq!(ids, vec!["environment.debugger", "environment.lockScreen", "environment.developerOptions"]);
        assert_eq!(dim(&r, Dimension::Environment).deduction, 18, "3 项 × 6");
        assert!(!dim(&r, Dimension::Environment).skipped);
    }

    #[test]
    fn settings_findings_point_at_the_right_screen() {
        let items = vec![login("a", STRONG_A)];
        let settings = SecuritySettings {
            auto_lock_minutes: 0,
            lock_on_exit: true,
            clipboard_clear_seconds: 0,
            biometrics_available: true,
            biometrics_enabled: false,
            verbose_logs: false,
        };
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, settings, 1_000);
        let action = |id: &str| r.findings.iter().find(|f| f.id == id).unwrap().action;
        assert_eq!(action("settings.autoLock"), FindingAction::AutoLock);
        assert_eq!(action("settings.clipboard"), FindingAction::GeneralSettings);
        assert_eq!(action("settings.biometrics"), FindingAction::Biometrics);
        assert_eq!(dim(&r, Dimension::Settings).deduction, 30, "3 项 × 10，正好到上限");
    }

    #[test]
    fn findings_are_sorted_by_severity_then_id() {
        let items = vec![login("a", "123456")];
        let settings = SecuritySettings { auto_lock_minutes: 0, ..SecuritySettings::SECURE_DEFAULTS };
        let r = report(&items, &HashMap::new(), BreachStatus::NotRun, EnvironmentReport::UNSUPPORTED, settings, 1_000);
        let severities: Vec<Severity> = r.findings.iter().map(|f| f.severity).collect();
        let mut sorted = severities.clone();
        sorted.sort_by(|a, b| b.cmp(a));
        assert_eq!(severities, sorted, "发现项应按严重度降序");
    }

    #[test]
    fn snooze_hides_findings_until_expiry_only() {
        let items = vec![login("a", "123456")];
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        assert_eq!(r.active_findings(&[], 1_000).len(), r.findings.len());

        let snoozes = vec![Snooze { finding_id: "vault.weak".into(), until: 2_000 }];
        assert!(r.active_findings(&snoozes, 1_500).iter().all(|f| f.id != "vault.weak"), "未到期应被隐藏");
        assert!(r.active_findings(&snoozes, 2_001).iter().any(|f| f.id == "vault.weak"), "到期后应重新出现");

        // 忽略不影响分数：分数是事实，忽略只是暂时不提示。
        assert_eq!(r.score, 94);
    }

    #[test]
    fn report_expires_after_24_hours() {
        let items = vec![login("a", STRONG_A)];
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        assert!(!r.is_stale(1_000));
        assert!(!r.is_stale(1_000 + REPORT_TTL_SECONDS));
        assert!(r.is_stale(1_000 + REPORT_TTL_SECONDS + 1));
    }

    #[test]
    fn items_without_password_are_not_scanned() {
        let mut note = ItemData::new(ItemKind::Note, "备注");
        note.notes = Some("没有密码".into());
        let items = vec![login("a", STRONG_A), Item { id: "n".into(), vault_id: "v".into(), revision: 1, data: note }];
        let r = report(&items, &HashMap::new(), BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        assert_eq!(r.password_fields, 1, "无密码条目不计入密码字段");
        assert_eq!(r.scanned_passwords, 1);
        assert_eq!(r.score, 100);
    }

    #[test]
    fn unreadable_items_are_reported_verbatim() {
        let items = vec![login("a", STRONG_A)];
        let r = checkup(HealthInputs {
            items: &items,
            breaches: &HashMap::new(),
            breach_status: BreachStatus::Ok,
            environment: EnvironmentReport::UNSUPPORTED,
            settings: SecuritySettings::SECURE_DEFAULTS,
            unreadable_items: 3,
            now: 1_000,
        });
        assert_eq!(r.unreadable_items, 3, "不可读条目如实计入，不假装扫描完整");
    }

    #[test]
    fn breach_finding_lists_items_sorted_by_id() {
        let items = vec![login("c", STRONG_A), login("a", STRONG_B), login("b", STRONG_A)];
        let mut breaches = HashMap::new();
        breaches.insert("c".to_string(), 5u64);
        breaches.insert("a".to_string(), 9u64);
        let r = report(&items, &breaches, BreachStatus::Ok, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        let f = r.findings.iter().find(|f| f.id == "breach.passwords").unwrap();
        assert_eq!(f.item_ids, vec!["a", "c"]);
        assert_eq!(f.count, 2);
        assert_eq!(dim(&r, Dimension::Breach).deduction, 50, "2 × 25 = 50，正好到上限");
    }

    #[test]
    fn report_roundtrips_through_json() {
        let items = vec![login("a", "123456")];
        let r =
            report(&items, &HashMap::new(), BreachStatus::NotRun, EnvironmentReport::UNSUPPORTED, SecuritySettings::SECURE_DEFAULTS, 1_000);
        let json = serde_json::to_string(&r).unwrap();
        let back: HealthReport = serde_json::from_str(&json).unwrap();
        assert_eq!(back, r);
    }
}
