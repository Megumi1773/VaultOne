//! 通知（计划书 §6）。
//!
//! **本模块只负责「本机安全提醒」**：把体检任务清单里未完成的项投影成通知，供通知中心与铃铛展示。
//! 服务端公告 / 弹窗（`[云]` 部分）需要 Java 侧的通知表与接口，不在这里。
//!
//! 为什么是「投影」而不是另写一套判定：清单项本身已经带了稳定 id、标题、说明与动作，
//! 通知要的就是同一批事实。再写一份「什么时候该提醒」就会立刻出现
//! 「总览说该备份、通知中心不吭声」这类矛盾——上一轮修文档矛盾时刚踩过一次。
//!
//! 阅读状态（已读）不在这里：那是**每台设备各自**的状态，存在本机设置里，
//! 与通知内容本身无关。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::health::{ChecklistItem, FindingAction, HealthReport};

/// 通知类型（计划书 §6.1）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NotificationType {
    /// 公告。服务端下发，本模块不产生。
    Announcement,
    /// 弹窗。服务端下发，本模块不产生。
    Popup,
    /// 个人消息。服务端下发，本模块不产生。
    Personal,
    /// 安全提醒。由本机体检结果派生。
    Security,
}

/// 通知级别（计划书 §6.1）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NotificationLevel {
    Info,
    Important,
    Critical,
}

/// 动作类型（计划书 §6.1）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NotificationActionKind {
    /// 无动作。
    None,
    /// 内部路由。`value` 是 [`FindingAction`] 的 wire 值，界面据此跳转。
    Route,
    /// 外链。`value` 是 http(s) 地址。
    Url,
}

/// 通知上的动作按钮（计划书 §6.1「含动作文案」）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NotificationAction {
    pub kind: NotificationActionKind,
    pub label: String,
    /// `kind` 为 route / url 时的目标；none 时为空串。
    pub value: String,
}

impl NotificationAction {
    pub fn none() -> Self {
        Self { kind: NotificationActionKind::None, label: String::new(), value: String::new() }
    }

    /// 内部跳转，目标用 [`FindingAction`] 的 wire 值表达——界面已经认识这套动作，不必再学一套。
    pub fn route(action: FindingAction, label: impl Into<String>) -> Self {
        Self { kind: NotificationActionKind::Route, label: label.into(), value: finding_action_wire(action) }
    }
}

/// [`FindingAction`] 的线协议取值。与 `health.rs` 的 serde 输出保持一致。
fn finding_action_wire(action: FindingAction) -> String {
    serde_json::to_value(action).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

/// 一条通知。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppNotification {
    /// 稳定 id。本机提醒用 `local.` 前缀，与服务端 id 不会撞。
    pub id: String,
    #[serde(rename = "type")]
    pub kind: NotificationType,
    pub level: NotificationLevel,
    pub title: String,
    /// 纯文本正文，不渲染 HTML（计划书 §6.1）。
    pub body: String,
    /// 产生时间（Unix 秒）。
    pub at: i64,
    pub action: NotificationAction,
}

impl AppNotification {
    /// 是否必须确认才能关掉（计划书 §6.3 的 `mustAck`）。
    ///
    /// 只对**严重**级别成立：把「弱密码」也做成关不掉的弹窗，用户会直接学会无视弹窗，
    /// 那比不弹更糟。
    pub fn must_ack(&self) -> bool {
        self.level == NotificationLevel::Critical
    }

    /// 分类计数用的类别键（计划书 §6.1「总未读 / 公告 / 个人 / 安全」）。
    pub fn category(&self) -> &'static str {
        match self.kind {
            NotificationType::Announcement => "announcement",
            NotificationType::Popup => "popup",
            NotificationType::Personal => "personal",
            NotificationType::Security => "security",
        }
    }
}

/// 未读分类计数（计划书 §6.1）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UnreadCounts {
    pub total: u32,
    pub announcement: u32,
    pub personal: u32,
    pub security: u32,
}

/// 按已读集合统计未读（计划书 §6.1）。
pub fn unread_counts(notifications: &[AppNotification], read: &HashMap<String, i64>) -> UnreadCounts {
    let mut c = UnreadCounts::default();
    for n in notifications {
        if read.contains_key(&n.id) {
            continue;
        }
        c.total += 1;
        match n.kind {
            NotificationType::Announcement | NotificationType::Popup => c.announcement += 1,
            NotificationType::Personal => c.personal += 1,
            NotificationType::Security => c.security += 1,
        }
    }
    c
}

/// 级别：只按**后果**分档，不按「这个设置项是不是没开」分档。
///
/// 已泄露密码是唯一一个 Critical —— 它是唯一一条「现在已经有人在用你的密码」的信息。
fn level_for(item_id: &str) -> NotificationLevel {
    match item_id {
        "task.noBreach" => NotificationLevel::Critical,
        "task.noWeak" | "task.noReuse" | "task.backup" | "task.environment" => NotificationLevel::Important,
        _ => NotificationLevel::Info,
    }
}

/// 把未完成的体检任务清单项投影成本机安全提醒（计划书 §6.1 的 SECURITY 类型）。
///
/// 已完成项**不产生通知**：通知中心不是任务清单的第二份副本，它只放「现在需要你注意的事」。
/// 要看待办全貌去安全总览。
pub fn from_checklist(items: &[ChecklistItem], report: &HealthReport) -> Vec<AppNotification> {
    let mut out: Vec<AppNotification> = items
        .iter()
        .filter(|t| !t.done)
        .map(|t| AppNotification {
            id: format!("local.{}", t.id),
            kind: NotificationType::Security,
            level: level_for(&t.id),
            title: t.title.clone(),
            body: t.description.clone(),
            at: report.checked_at,
            action: NotificationAction::route(t.action, action_label(t.action)),
        })
        .collect();

    // 严重的排前面：通知中心默认按时间倒序，但同一时刻产生的这批提醒里，
    // 「密码已泄露」必须排在「没开剪贴板清除」之前。
    out.sort_by(|a, b| b.level.cmp(&a.level).then_with(|| a.id.cmp(&b.id)));
    out
}

/// 动作按钮的文案。与界面 `_actionLabel` 用的是同一套动作，因此文案也在这里定一次。
fn action_label(action: FindingAction) -> &'static str {
    match action {
        FindingAction::OpenItem => "打开条目",
        FindingAction::OpenCheckup => "去体检",
        FindingAction::Biometrics => "去开启",
        FindingAction::AutoLock => "去设置",
        FindingAction::Autofill => "去开启",
        FindingAction::PrivateKey => "查看私钥",
        FindingAction::GeneralSettings => "去设置",
        FindingAction::SystemSettings => "系统设置",
        FindingAction::OpenBackup => "立即备份",
        FindingAction::None => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::health::{checklist, checkup, BreachStatus, EnvironmentReport, HealthInputs, SecuritySettings};
    use crate::item::{Item, ItemData, ItemKind};

    fn login(id: &str, password: &str) -> Item {
        let mut data = ItemData::new(ItemKind::Login, id);
        data.password = Some(password.into());
        data.created_at = 1_000;
        data.updated_at = 1_000;
        Item { id: id.into(), vault_id: "v".into(), revision: 1, data }
    }

    /// 强密码版本：配合 `SECURE_DEFAULTS` 才真的代表「一切都已妥善配置」。
    const STRONG: &str = "vK9#qLm2$Zp8!wRt5@Yx";

    fn overview(settings: SecuritySettings, now: i64) -> (Vec<ChecklistItem>, HealthReport) {
        overview_with(settings, now, &[], &HashMap::new())
    }

    fn overview_with(
        settings: SecuritySettings,
        now: i64,
        items: &[Item],
        breaches: &HashMap<String, u64>,
    ) -> (Vec<ChecklistItem>, HealthReport) {
        let owned;
        let items = if items.is_empty() {
            owned = vec![login("a", STRONG)];
            &owned[..]
        } else {
            items
        };
        let report = checkup(HealthInputs {
            items,
            breaches,
            breach_status: BreachStatus::Ok,
            environment: EnvironmentReport::UNSUPPORTED,
            settings,
            unreadable_items: 0,
            now,
        });
        let list = checklist(&settings, &report);
        (list, report)
    }

    #[test]
    fn only_unfinished_items_become_notifications() {
        let (list, report) = overview(SecuritySettings::SECURE_DEFAULTS, 1_700_000_000);
        let notes = from_checklist(&list, &report);
        // SECURE_DEFAULTS + 强密码 → 全部完成 → 不该有任何提醒。
        assert!(notes.is_empty(), "已完成项不该产生通知：{notes:?}");

        let weak = SecuritySettings { auto_lock_minutes: 0, ..SecuritySettings::SECURE_DEFAULTS };
        let (list, report) = overview(weak, 1_700_000_000);
        let notes = from_checklist(&list, &report);
        assert!(notes.iter().any(|n| n.id == "local.task.autoLock"));
        assert!(notes.iter().all(|n| n.kind == NotificationType::Security));
    }

    #[test]
    fn leaked_passwords_outrank_settings_hygiene() {
        // 一个弱密码 + 该条目已确认泄露 → noWeak(Important) 与 noBreach(Critical) 同时未完成。
        let items = vec![login("a", "123456")];
        let breaches: HashMap<String, u64> = [("a".to_string(), 7u64)].into_iter().collect();
        let weak = SecuritySettings { auto_lock_minutes: 0, clipboard_clear_seconds: 0, ..SecuritySettings::SECURE_DEFAULTS };
        let (list, report) = overview_with(weak, 1_700_000_000, &items, &breaches);
        let notes = from_checklist(&list, &report);

        let first = notes.first().expect("至少有一条");
        assert_eq!(first.id, "local.task.noBreach", "已泄露密码必须排最前：{notes:?}");
        assert_eq!(first.level, NotificationLevel::Critical);
        assert!(first.must_ack(), "只有严重级别需要强制确认");

        // 弱密码是 Important，但同样不强制确认——满屏关不掉的弹窗只会让人学会无视弹窗。
        let weak_note = notes.iter().find(|n| n.id == "local.task.noWeak").expect("弱密码应有提醒");
        assert_eq!(weak_note.level, NotificationLevel::Important);
        assert!(!weak_note.must_ack());

        // 设置类提醒是 Info 且不强制确认。
        let lock = notes.iter().find(|n| n.id == "local.task.autoLock").unwrap();
        assert_eq!(lock.level, NotificationLevel::Info);
        assert!(!lock.must_ack());
    }

    #[test]
    fn action_points_at_the_same_destination_as_the_checklist() {
        let (list, report) =
            overview(SecuritySettings { backup_reminder: true, last_backup_at: 0, ..SecuritySettings::SECURE_DEFAULTS }, 1_700_000_000);
        let notes = from_checklist(&list, &report);
        let backup = notes.iter().find(|n| n.id == "local.task.backup").unwrap();
        assert_eq!(backup.action.kind, NotificationActionKind::Route);
        assert_eq!(backup.action.value, "openBackup", "路由值必须与 FindingAction 的 serde 输出一致");
        assert_eq!(backup.action.label, "立即备份");
    }

    #[test]
    fn unread_counts_split_by_category() {
        let (list, report) = overview(SecuritySettings { auto_lock_minutes: 0, ..SecuritySettings::SECURE_DEFAULTS }, 1_700_000_000);
        let notes = from_checklist(&list, &report);
        assert!(!notes.is_empty());

        let all = unread_counts(&notes, &HashMap::new());
        assert_eq!(all.total as usize, notes.len());
        assert_eq!(all.security as usize, notes.len(), "本机提醒都是安全类");
        assert_eq!(all.announcement, 0);
        assert_eq!(all.personal, 0);

        // 读过一半：总数与分类计数一起减。
        let read: HashMap<String, i64> = notes.iter().take(1).map(|n| (n.id.clone(), 1)).collect();
        let half = unread_counts(&notes, &read);
        assert_eq!(half.total as usize, notes.len() - 1);
        assert_eq!(half.security as usize, notes.len() - 1);
    }
}
