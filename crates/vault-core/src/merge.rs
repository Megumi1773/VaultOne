//! 零知识同步下的**字段级三方合并**（自研核心算法，见 docs/01 "自研部分"）。
//!
//! 问题：服务端看不到明文，无法像普通同步服务那样在服务端合并；传统 E2EE 密码管理器
//! 因此只能"整条目后写覆盖"，两台设备离线编辑同一条目的不同字段时会静默丢失一方修改。
//!
//! 做法：客户端为每个条目保留"最后一次与服务端一致的密文"（base），冲突时在本地解密
//! base / local / remote 三个版本，逐字段执行三方合并：
//!
//! | base→local | base→remote | 结果 |
//! |---|---|---|
//! | 未变 | 未变 | base |
//! | 变 | 未变 | local |
//! | 未变 | 变 | remote |
//! | 变 | 变（且不同） | `updated_at` 较新者；记录冲突字段；若为密码，败者进入 `passwordHistory` |
//!
//! 结果满足计划书 F-06 "最新修改 + 保留历史版本"，并且比整条目覆盖少丢数据。
//! 该算法只在客户端内存中运行，不引入任何新的密码学构造。

use crate::item::{ItemData, PasswordHistoryEntry};

pub const PASSWORD_HISTORY_LIMIT: usize = 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeOutcome {
    pub data: ItemData,
    /// 双方都修改且取值不同的字段名
    pub conflicts: Vec<&'static str>,
}

/// 三方合并。`base` 为 None 表示没有共同祖先（例如两端各自新建了同 ID 条目，极少见）。
pub fn merge(base: Option<&ItemData>, local: &ItemData, remote: &ItemData) -> MergeOutcome {
    let local_newer = local.updated_at > remote.updated_at;
    let mut conflicts = Vec::new();

    // 条目类型不同：字段语义不可比，整条取较新者
    if local.kind != remote.kind {
        let winner = if local_newer { local } else { remote };
        return MergeOutcome { data: winner.clone(), conflicts: vec!["type"] };
    }

    let mut out = remote.clone();

    macro_rules! field {
        ($name:ident, $label:literal) => {{
            let l = &local.$name;
            let r = &remote.$name;
            out.$name = if l == r {
                l.clone()
            } else {
                match base.map(|b| &b.$name) {
                    Some(b) if b == l => r.clone(),
                    Some(b) if b == r => l.clone(),
                    _ => {
                        conflicts.push($label);
                        if local_newer {
                            l.clone()
                        } else {
                            r.clone()
                        }
                    }
                }
            };
        }};
    }

    field!(title, "title");
    field!(urls, "urls");
    field!(username, "username");
    field!(password, "password");
    field!(totp, "totp");
    field!(notes, "notes");
    field!(card, "card");
    field!(identity, "identity");
    field!(custom_fields, "customFields");
    field!(favorite, "favorite");
    field!(tags, "tags");
    field!(category, "category");

    // 密码历史：并集去重，按时间倒序截断
    let mut history: Vec<PasswordHistoryEntry> = Vec::new();
    for h in local.password_history.iter().chain(remote.password_history.iter()) {
        if !history.iter().any(|x| x.p == h.p && x.t == h.t) {
            history.push(h.clone());
        }
    }
    // 密码冲突的败者进入历史，保证不丢
    let merged_pw = out.password.clone();
    for (candidate, t) in [(&local.password, local.updated_at), (&remote.password, remote.updated_at)] {
        if let Some(p) = candidate.as_deref().filter(|p| !p.is_empty()) {
            if merged_pw.as_deref() != Some(p) && !history.iter().any(|x| x.p == p) {
                history.push(PasswordHistoryEntry { p: p.to_string(), t });
            }
        }
    }
    history.sort_by(|a, b| b.t.cmp(&a.t));
    history.truncate(PASSWORD_HISTORY_LIMIT);
    out.password_history = history;

    out.created_at = local.created_at.min(remote.created_at);
    out.updated_at = local.updated_at.max(remote.updated_at);
    MergeOutcome { data: out, conflicts }
}

/// 墓碑三方合并。返回（删除结果，是否需要人工裁决）。未知基线保守处理。
/// 一方删除/恢复且另一方完全未改可以自动采用；删除与内容编辑并发必须留给用户。
pub(crate) fn merge_deleted(
    base: Option<&ItemData>,
    base_deleted: Option<bool>,
    local: &ItemData,
    local_deleted: bool,
    remote: &ItemData,
    remote_deleted: bool,
) -> (bool, bool) {
    if local_deleted == remote_deleted {
        return (local_deleted, false);
    }
    if let (Some(base), Some(deleted)) = (base, base_deleted) {
        let b = base.clone().into_import_content();
        if local_deleted == deleted && local.clone().into_import_content() == b {
            return (remote_deleted, false);
        }
        if remote_deleted == deleted && remote.clone().into_import_content() == b {
            return (local_deleted, false);
        }
    }
    (local_deleted, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ItemKind, ItemUrl};

    fn base() -> ItemData {
        let mut d = ItemData::new(ItemKind::Login, "GitHub");
        d.username = Some("alice".into());
        d.password = Some("pw-0".into());
        d.notes = Some("n0".into());
        d.created_at = 100;
        d.updated_at = 100;
        d
    }

    #[test]
    fn disjoint_edits_are_both_kept() {
        let b = base();
        let mut l = b.clone();
        l.username = Some("alice2".into());
        l.updated_at = 200;
        let mut r = b.clone();
        r.notes = Some("n1".into());
        r.urls.push(ItemUrl { url: "https://github.com".into(), ..Default::default() });
        r.updated_at = 300;
        let m = merge(Some(&b), &l, &r);
        assert!(m.conflicts.is_empty());
        assert_eq!(m.data.username.as_deref(), Some("alice2"));
        assert_eq!(m.data.notes.as_deref(), Some("n1"));
        assert_eq!(m.data.urls.len(), 1);
        assert_eq!(m.data.updated_at, 300);
        assert_eq!(m.data.created_at, 100);
    }

    #[test]
    fn same_field_conflict_newer_wins_and_loser_password_kept() {
        let b = base();
        let mut l = b.clone();
        l.password = Some("pw-local".into());
        l.updated_at = 500;
        let mut r = b.clone();
        r.password = Some("pw-remote".into());
        r.updated_at = 400;
        let m = merge(Some(&b), &l, &r);
        assert_eq!(m.conflicts, vec!["password"]);
        assert_eq!(m.data.password.as_deref(), Some("pw-local"));
        assert!(m.data.password_history.iter().any(|h| h.p == "pw-remote"));
    }

    #[test]
    fn tags_and_category_merge_like_other_fields() {
        let b = base();

        // 只有本地改了标签：直接采用本地，不算冲突。
        let mut l = b.clone();
        l.tags = vec!["工作".into()];
        l.updated_at = 200;
        let m = merge(Some(&b), &l, &b);
        assert!(m.conflicts.is_empty());
        assert_eq!(m.data.tags, vec!["工作"]);

        // 两端都改标签且取值不同：记为冲突，取较新者。
        let mut r = b.clone();
        r.tags = vec!["个人".into()];
        r.updated_at = 300;
        let m = merge(Some(&b), &l, &r);
        assert_eq!(m.conflicts, vec!["tags"]);
        assert_eq!(m.data.tags, vec!["个人"], "远端更新，应取远端标签");

        // 分类同理，且 None 与 Some 的差异也算改动。
        let mut l2 = b.clone();
        l2.category = Some("金融".into());
        l2.updated_at = 400;
        let mut r2 = b.clone();
        r2.category = Some("工作".into());
        r2.updated_at = 500;
        let m = merge(Some(&b), &l2, &r2);
        assert_eq!(m.conflicts, vec!["category"]);
        assert_eq!(m.data.category.as_deref(), Some("工作"));
    }

    #[test]
    fn identical_changes_are_not_conflicts() {
        let b = base();
        let mut l = b.clone();
        l.title = "GitHub Work".into();
        l.updated_at = 200;
        let mut r = l.clone();
        r.updated_at = 210;
        let m = merge(Some(&b), &l, &r);
        assert!(m.conflicts.is_empty());
        assert_eq!(m.data.title, "GitHub Work");
    }

    #[test]
    fn without_base_differences_are_conflicts() {
        let mut l = base();
        l.title = "A".into();
        l.updated_at = 1;
        let mut r = base();
        r.title = "B".into();
        r.updated_at = 2;
        let m = merge(None, &l, &r);
        assert_eq!(m.data.title, "B");
        assert_eq!(m.conflicts, vec!["title"]);
    }

    #[test]
    fn history_is_union_and_bounded() {
        let b = base();
        let mut l = b.clone();
        let mut r = b.clone();
        for i in 0..15 {
            l.password_history.push(PasswordHistoryEntry { p: format!("l{i}"), t: i });
            r.password_history.push(PasswordHistoryEntry { p: format!("r{i}"), t: 100 + i });
        }
        let m = merge(Some(&b), &l, &r);
        assert_eq!(m.data.password_history.len(), PASSWORD_HISTORY_LIMIT);
        assert_eq!(m.data.password_history[0].p, "r14");
    }

    #[test]
    fn kind_change_takes_newer_whole_item() {
        let b = base();
        let mut l = b.clone();
        l.kind = ItemKind::Note;
        l.updated_at = 900;
        let m = merge(Some(&b), &l, &b);
        assert_eq!(m.data.kind, ItemKind::Note);
    }
}
