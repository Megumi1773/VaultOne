use super::*;
use crate::item::ItemKind;
use crate::sync::SyncReport;
use crate::vault::Enrollment;
use crate::KdfParams;
use vault_proto::{PullResponse, RemoteItem};

const PW: &str = "correct horse battery";
fn new_vault() -> (Vault, Enrollment) {
    let mut v = Vault::open_in_memory().unwrap();
    let e = v.create_account("test@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    (v, e)
}
fn remote(row: &ItemRow) -> RemoteItem {
    RemoteItem {
        id: row.id.clone(),
        kind: row.kind.clone(),
        blob: row.blob.clone().into(),
        revision: row.revision,
        deleted: row.deleted_at.is_some(),
        updated_at: row.updated_at,
    }
}
fn seed(v: &mut Vault) -> (String, RemoteItem) {
    let mut data = ItemData::new(ItemKind::Note, "保密标题-e4");
    data.notes = Some("共同基线-e4".into());
    let item = v.create_item(data).unwrap();
    let base = v.store.get_item(&item.id).unwrap().unwrap();
    assert!(v.store.mark_synced_snapshot(&base).unwrap());
    let mut local = item.data.clone();
    local.notes = Some("本机冲突秘密-e4".into());
    v.update_item(&item.id, local).unwrap();
    let mut other = item.data;
    other.notes = Some("远端冲突秘密-e4".into());
    other.updated_at += 3;
    let r = RemoteItem {
        id: item.id.clone(),
        kind: "note".into(),
        blob: v.seal_blob(&item.id, 2, &other).unwrap().into(),
        revision: 2,
        deleted: false,
        updated_at: other.updated_at,
    };
    (item.id, r)
}
fn fixture() -> (Vault, String, RemoteItem) {
    let (mut v, _) = new_vault();
    let (id, r) = seed(&mut v);
    (v, id, r)
}
fn apply(v: &mut Vault, r: &RemoteItem) {
    v.apply_remote(r, &mut SyncReport::default()).unwrap();
}
fn choose_local() -> ConflictResolution {
    ConflictResolution::Whole { side: ConflictSide::Local }
}

#[test]
fn records_exact_versions_blocks_push_and_replay_is_idempotent() {
    let (mut v, id, r) = fixture();
    let before = v.store.get_item(&id).unwrap().unwrap();
    apply(&mut v, &r);
    apply(&mut v, &r);
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), before);
    assert!(v.store.dirty_items().unwrap().is_empty());
    let list = v.list_conflicts(false).unwrap();
    assert_eq!(list.len(), 1);
    let d = &list[0];
    assert_eq!(d.fields, vec![ConflictField::Notes]);
    assert_eq!(d.base.as_ref().unwrap().data.notes.as_deref(), Some("共同基线-e4"));
    assert_eq!(d.local.data.notes.as_deref(), Some("本机冲突秘密-e4"));
    assert_eq!(d.remote.data.notes.as_deref(), Some("远端冲突秘密-e4"));
    assert!(!d.stale);
    let record = v.store.conflict(&d.id).unwrap().unwrap();
    let p = v.open_conflict(&record).unwrap();
    assert_eq!(p.local, before);
    assert_eq!(p.remote.blob, r.blob.0);
    assert_eq!(p.base.unwrap().blob, before.base_blob.unwrap());
}

#[test]
fn field_resolution_is_durable_until_exact_ack_and_rejects_duplicate() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    assert!(v.resolve_conflict(&d.id, ConflictResolution::Fields { choices: vec![] }).is_err());
    assert!(v
        .resolve_conflict(
            &d.id,
            ConflictResolution::Fields { choices: vec![FieldDecision { field: ConflictField::Title, side: ConflictSide::Local }] }
        )
        .is_err());
    v.resolve_conflict(
        &d.id,
        ConflictResolution::Fields { choices: vec![FieldDecision { field: ConflictField::Notes, side: ConflictSide::Remote }] },
    )
    .unwrap();
    assert_eq!(v.get_item(&id).unwrap().data.notes, d.remote.data.notes);
    let sent = v.store.dirty_items().unwrap().remove(0);
    assert_eq!(sent.server_rev, r.revision);
    assert_eq!(sent.base_blob.as_ref().unwrap(), &r.blob.0);
    assert_eq!(v.get_conflict(&d.id).unwrap().state, ConflictState::ResolutionPending);
    assert!(matches!(v.resolve_conflict(&d.id, choose_local()), Err(VaultError::ConflictStale)));
    // 服务端已接受但 ACK 丢失：拉回完全相同的信封即可确认，无需另造版本。
    apply(&mut v, &remote(&sent));
    assert!(v.store.dirty_items().unwrap().is_empty());
    assert!(v.list_conflicts(false).unwrap().is_empty());
    assert_eq!(v.get_conflict(&d.id).unwrap().state, ConflictState::Resolved);
    assert_eq!(v.get_item(&id).unwrap().revision, sent.revision);
}

#[test]
fn edit_revert_delete_refresh_and_old_ack_cannot_reuse_candidates() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    let original = v.get_item(&id).unwrap().data;
    let mut changed = original.clone();
    changed.title = "改过".into();
    v.update_item(&id, changed).unwrap();
    v.update_item(&id, original).unwrap();
    assert!(v.get_conflict(&d.id).unwrap().stale);
    assert!(matches!(v.resolve_conflict(&d.id, choose_local()), Err(VaultError::ConflictStale)));
    let refreshed = v.refresh_conflict(&d.id).unwrap();
    assert_ne!(refreshed.id, d.id);
    assert_eq!(v.get_conflict(&d.id).unwrap().state, ConflictState::Superseded);
    v.delete_item(&id).unwrap();
    assert!(matches!(v.resolve_conflict(&refreshed.id, choose_local()), Err(VaultError::ConflictStale)));
    let refreshed = v.refresh_conflict(&refreshed.id).unwrap();
    v.resolve_conflict(&refreshed.id, choose_local()).unwrap();
    let sent = v.store.dirty_items().unwrap().remove(0);
    v.restore_item(&id).unwrap();
    let latest = v.store.get_item(&id).unwrap().unwrap();
    assert!(!v.acknowledge_snapshot(&sent).unwrap());
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), latest);
    assert!(latest.dirty);
}

#[test]
fn newer_remote_after_resolution_requires_new_decision_and_preserves_both() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let first = v.list_conflicts(false).unwrap().remove(0);
    v.resolve_conflict(&first.id, choose_local()).unwrap();
    let decision = v.store.get_item(&id).unwrap().unwrap();
    let mut data = v.get_item(&id).unwrap().data;
    // 模拟另一设备已提交新决定，哪怕只是非冲突字段变化也不自动套用旧决定。
    data.title = "另一设备的新裁决".into();
    let newer = RemoteItem {
        id: id.clone(),
        kind: "note".into(),
        revision: decision.revision + 1,
        blob: v.seal_blob(&id, decision.revision + 1, &data).unwrap().into(),
        deleted: false,
        updated_at: data.updated_at,
    };
    apply(&mut v, &newer);
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), decision);
    assert!(v.store.dirty_items().unwrap().is_empty());
    let active = v.list_conflicts(false).unwrap().remove(0);
    assert_ne!(first.id, active.id);
    assert_eq!(v.get_conflict(&first.id).unwrap().state, ConflictState::Superseded);
    assert!(matches!(v.resolve_conflict(&first.id, choose_local()), Err(VaultError::ConflictStale)));
    assert_eq!(active.local.revision, decision.revision);
    assert_eq!(active.remote.revision, newer.revision);
    assert_eq!(v.list_conflicts(true).unwrap().len(), 2);
}

#[test]
fn corrupt_remote_does_not_advance_cursor_and_corrupt_base_is_not_absent() {
    let (mut v, id, r) = fixture();
    let vault = v.session().unwrap().account.vault_id.clone();
    let before = v.store.get_item(&id).unwrap().unwrap();
    let mut bad = r.clone();
    *bad.blob.0.last_mut().unwrap() ^= 1;
    let page = PullResponse { items: vec![bad], cursor: 9, has_more: false, vk_gen: None };
    assert!(v.apply_pull_page(&page, 0, &mut SyncReport::default()).is_err());
    assert_eq!(v.store.cursor(&vault).unwrap(), 0);
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), before);
    let mut broken = before.clone();
    *broken.base_blob.as_mut().unwrap().last_mut().unwrap() ^= 1;
    v.store.put_item(&broken).unwrap();
    assert!(v.apply_remote(&r, &mut SyncReport::default()).is_err());
    assert!(v.list_conflicts(false).unwrap().is_empty());
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), broken);
    v.store.put_item(&before).unwrap();
    let page = PullResponse { items: vec![r], cursor: 9, has_more: false, vk_gen: None };
    v.apply_pull_page(&page, 0, &mut SyncReport::default()).unwrap();
    assert_eq!(v.store.cursor(&vault).unwrap(), 9);
    assert_eq!(v.list_conflicts(false).unwrap().len(), 1);
}

#[test]
fn nonconflicting_edits_still_merge_and_unknown_tombstone_is_conservative() {
    let (mut v, id, mut r) = fixture();
    let mut data = v.get_item(&id).unwrap().data;
    data.notes = Some("共同基线-e4".into());
    data.title = "远端改标题".into();
    r.blob = v.seal_blob(&id, r.revision, &data).unwrap().into();
    apply(&mut v, &r);
    assert!(v.list_conflicts(false).unwrap().is_empty());
    let merged = v.get_item(&id).unwrap();
    assert_eq!(merged.data.title, "远端改标题");
    assert_eq!(merged.data.notes.as_deref(), Some("本机冲突秘密-e4"));
    assert_eq!(v.store.dirty_items().unwrap().len(), 1);
    let mut row = v.store.get_item(&id).unwrap().unwrap();
    row.base_deleted = None;
    v.store.put_item(&row).unwrap();
    r.revision = row.revision + 1;
    r.deleted = true;
    r.blob = v.seal_blob(&id, r.revision, &data).unwrap().into();
    apply(&mut v, &r);
    assert!(v.list_conflicts(false).unwrap()[0].fields.contains(&ConflictField::Deleted));
}

#[test]
fn tombstone_races_are_explicit_and_whole_remote_can_delete() {
    let (mut v, id, mut r) = fixture();
    r.deleted = true;
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    assert!(d.fields.contains(&ConflictField::Deleted));
    assert!(v
        .resolve_conflict(
            &d.id,
            ConflictResolution::Fields { choices: vec![FieldDecision { field: ConflictField::Notes, side: ConflictSide::Local }] }
        )
        .is_err());
    v.resolve_conflict(&d.id, ConflictResolution::Whole { side: ConflictSide::Remote }).unwrap();
    assert!(v.list_items().unwrap().is_empty());
    assert_eq!(v.list_trash().unwrap()[0].id, id);
    assert!(v.store.dirty_items().unwrap()[0].deleted_at.is_some());
}

#[test]
fn reopen_retains_ciphertext_candidates_and_resolution_outbox() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("vault.db");
    let mut v = Vault::open(&path).unwrap();
    let e = v.create_account("t@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    let (id, r) = seed(&mut v);
    apply(&mut v, &r);
    let conflict_id = v.list_conflicts(false).unwrap()[0].id.clone();
    drop(v);
    let mut v = Vault::open(&path).unwrap();
    assert!(matches!(v.list_conflicts(false), Err(VaultError::Locked)));
    v.unlock(PW, &e.secret_key).unwrap();
    assert_eq!(v.list_conflicts(false).unwrap()[0].id, conflict_id);
    v.resolve_conflict(&conflict_id, choose_local()).unwrap();
    drop(v);
    let mut v = Vault::open(&path).unwrap();
    v.unlock(PW, &e.secret_key).unwrap();
    assert_eq!(v.get_conflict(&conflict_id).unwrap().state, ConflictState::ResolutionPending);
    assert_eq!(v.store.dirty_items().unwrap()[0].id, id);
    drop(v);
    let bytes = std::fs::read(&path).unwrap();
    for text in ["保密标题-e4", "共同基线-e4", "本机冲突秘密-e4", "远端冲突秘密-e4"] {
        assert!(!bytes.windows(text.len()).any(|w| w == text.as_bytes()));
    }
}

#[test]
fn transaction_failure_rolls_back_resolution_and_keeps_original_snapshots() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("vault.db");
    let mut v = Vault::open(&path).unwrap();
    v.create_account("t@example.com", PW, KdfParams::insecure_for_tests()).unwrap();
    let (id, r) = seed(&mut v);
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    let before = v.store.get_item(&id).unwrap().unwrap();
    let record = v.store.conflict(&d.id).unwrap().unwrap();
    let conn = rusqlite::Connection::open(&path).unwrap();
    conn.execute_batch("CREATE TRIGGER fail_resolution BEFORE UPDATE ON item_conflicts WHEN NEW.state='resolution_pending' BEGIN SELECT RAISE(ABORT,'injected'); END;").unwrap();
    assert!(v.resolve_conflict(&d.id, choose_local()).is_err());
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), before);
    assert_eq!(v.store.conflict(&d.id).unwrap().unwrap(), record);
    conn.execute_batch("DROP TRIGGER fail_resolution").unwrap();
    v.resolve_conflict(&d.id, choose_local()).unwrap();
}

#[test]
fn tampered_conflict_rejects_details_decision_and_sync() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    let mut row = v.store.conflict(&d.id).unwrap().unwrap();
    *row.blob.last_mut().unwrap() ^= 1;
    v.store.put_conflict(&row).unwrap();
    let before = v.store.get_item(&id).unwrap().unwrap();
    assert!(v.get_conflict(&d.id).is_err());
    assert!(v.resolve_conflict(&d.id, choose_local()).is_err());
    assert!(v.apply_remote(&r, &mut SyncReport::default()).is_err());
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), before);
    assert!(v.store.dirty_items().unwrap().is_empty());
}

#[test]
fn partial_page_restarts_without_duplicate_records_or_skipped_bad_item() {
    let (mut v, _, r) = fixture();
    let vault = v.session().unwrap().account.vault_id.clone();
    let id = Uuid::new_v4().to_string();
    let data = ItemData::new(ItemKind::Note, "第二条");
    let good = RemoteItem {
        id: id.clone(),
        kind: "note".into(),
        revision: 1,
        blob: v.seal_blob(&id, 1, &data).unwrap().into(),
        deleted: false,
        updated_at: 0,
    };
    let mut bad = good.clone();
    *bad.blob.0.last_mut().unwrap() ^= 1;
    let page = PullResponse { items: vec![r.clone(), bad], cursor: 20, has_more: false, vk_gen: None };
    assert!(v.apply_pull_page(&page, 0, &mut SyncReport::default()).is_err());
    assert_eq!(v.store.cursor(&vault).unwrap(), 0);
    let old_id = v.list_conflicts(false).unwrap()[0].id.clone();
    let retry = PullResponse { items: vec![r, good], cursor: 20, has_more: false, vk_gen: None };
    v.apply_pull_page(&retry, 0, &mut SyncReport::default()).unwrap();
    assert_eq!(v.store.cursor(&vault).unwrap(), 20);
    assert_eq!(v.list_conflicts(false).unwrap().len(), 1);
    assert_eq!(v.list_conflicts(false).unwrap()[0].id, old_id);
    assert_eq!(v.get_item(&id).unwrap().data.title, "第二条");
}

#[test]
fn manual_decision_validates_before_writing_and_retains_originals() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    let before = v.store.get_item(&id).unwrap().unwrap();
    let mut manual = d.suggested.clone();
    manual.title.clear();
    assert!(v.resolve_conflict(&d.id, ConflictResolution::Manual { data: Box::new(manual.clone()), deleted: false }).is_err());
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), before);
    manual.title = "手工合并".into();
    manual.notes = Some("两端都采纳".into());
    v.resolve_conflict(&d.id, ConflictResolution::Manual { data: Box::new(manual), deleted: false }).unwrap();
    assert_eq!(v.get_item(&id).unwrap().data.title, "手工合并");
    let history = v.get_conflict(&d.id).unwrap();
    assert_eq!(history.local.data, d.local.data);
    assert_eq!(history.remote.data, d.remote.data);
}

#[test]
fn same_revision_different_ciphertext_ack_does_not_clear_new_head() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    v.resolve_conflict(&d.id, choose_local()).unwrap();
    let sent = v.store.dirty_items().unwrap().remove(0);
    // 模拟另一连接写入同版本的不同信封，证明 CAS 不只是 revision。
    let mut newer = sent.clone();
    let mut data = v.get_item(&id).unwrap().data;
    data.notes = Some("另一连接写入".into());
    newer.blob = v.seal_blob(&id, newer.revision, &data).unwrap();
    v.store.put_item(&newer).unwrap();
    assert!(!v.acknowledge_snapshot(&sent).unwrap());
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), newer);
    assert_eq!(v.get_conflict(&d.id).unwrap().state, ConflictState::ResolutionPending);
}

#[test]
fn locked_conflict_apis_all_reject_and_overflow_has_no_side_effects() {
    let (mut v, id, mut r) = fixture();
    let data = v.decrypt_blob(&id, r.revision, &r.blob).unwrap();
    r.revision = i64::MAX;
    r.blob = v.seal_blob(&id, r.revision, &data).unwrap().into();
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    let before = v.store.get_item(&id).unwrap().unwrap();
    assert!(matches!(v.resolve_conflict(&d.id, choose_local()), Err(VaultError::Integrity)));
    assert_eq!(v.store.get_item(&id).unwrap().unwrap(), before);
    assert_eq!(v.get_conflict(&d.id).unwrap().state, ConflictState::Pending);
    v.lock();
    assert!(matches!(v.list_conflicts(false), Err(VaultError::Locked)));
    assert!(matches!(v.list_conflicts(true), Err(VaultError::Locked)));
    assert!(matches!(v.get_conflict(&d.id), Err(VaultError::Locked)));
    assert!(matches!(v.refresh_conflict(&d.id), Err(VaultError::Locked)));
    assert!(matches!(v.resolve_conflict(&d.id, choose_local()), Err(VaultError::Locked)));
}

#[test]
fn v1_exports_block_active_conflicts_until_ack_but_not_resolved_history() {
    let (mut v, _, r) = fixture();
    assert!(v.export_backup().is_ok());
    apply(&mut v, &r);
    let d = v.list_conflicts(false).unwrap().remove(0);
    assert!(matches!(v.export_backup(), Err(VaultError::ConflictPending)));
    assert!(matches!(v.export_csv(), Err(VaultError::ConflictPending)));
    assert_eq!(VaultError::ConflictPending.code(), "conflict_pending");
    v.resolve_conflict(&d.id, choose_local()).unwrap();
    assert!(matches!(v.export_backup(), Err(VaultError::ConflictPending)));
    assert!(matches!(v.export_csv(), Err(VaultError::ConflictPending)));
    let sent = v.store.dirty_items().unwrap().remove(0);
    apply(&mut v, &remote(&sent));
    let backup = v.export_backup().unwrap();
    assert!(v.export_csv().is_ok());
    assert_eq!(&backup[..crate::export::MAGIC.len()], crate::export::MAGIC);
    let session = v.session().unwrap();
    let items = crate::export::restore(&session.vault_key, &session.account.account_id, &backup).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(v.list_conflicts(true).unwrap().len(), 1);
    assert!(v.list_conflicts(false).unwrap().is_empty());
}

#[test]
fn editing_deleting_or_restoring_resolution_creates_new_blocked_candidate() {
    for action in ["edit", "delete", "restore"] {
        let (mut v, id, r) = fixture();
        apply(&mut v, &r);
        let first = v.list_conflicts(false).unwrap().remove(0);
        let choice = if action == "restore" {
            ConflictResolution::Manual { data: Box::new(first.local.data.clone()), deleted: true }
        } else {
            choose_local()
        };
        v.resolve_conflict(&first.id, choice).unwrap();
        let result = v.store.get_item(&id).unwrap().unwrap();
        match action {
            "edit" => {
                let mut d = v.get_item(&id).unwrap().data;
                d.title = "裁决后再改".into();
                v.update_item(&id, d).unwrap();
            }
            "delete" => v.delete_item(&id).unwrap(),
            _ => v.restore_item(&id).unwrap(),
        }
        let latest = v.store.get_item(&id).unwrap().unwrap();
        let next = v.list_conflicts(false).unwrap().remove(0);
        assert_ne!(next.id, first.id);
        assert_eq!(next.state, ConflictState::Pending);
        assert_eq!(v.get_conflict(&first.id).unwrap().state, ConflictState::Superseded);
        let old = v.store.conflict(&first.id).unwrap().unwrap();
        assert_eq!(v.open_conflict(&old).unwrap().result, Some(result.clone()));
        assert!(v.store.dirty_items().unwrap().is_empty());
        assert!(!v.acknowledge_snapshot(&latest).unwrap());
        assert!(!v.acknowledge_snapshot(&result).unwrap());
        assert!(matches!(v.export_backup(), Err(VaultError::ConflictPending)));
        v.resolve_conflict(&next.id, choose_local()).unwrap();
        let confirmed = v.store.get_item(&id).unwrap().unwrap();
        assert!(v.acknowledge_snapshot(&confirmed).unwrap());
        assert!(v.export_backup().is_ok());
    }
}

#[test]
fn legacy_stale_resolution_cannot_be_acked_but_can_be_refreshed() {
    let (mut v, id, r) = fixture();
    apply(&mut v, &r);
    let first = v.list_conflicts(false).unwrap().remove(0);
    v.resolve_conflict(&first.id, choose_local()).unwrap();
    let mut changed = v.store.get_item(&id).unwrap().unwrap();
    let mut data = v.get_item(&id).unwrap().data;
    data.title = "旧版遗留编辑".into();
    changed.revision += 1;
    changed.blob = v.seal_blob(&id, changed.revision, &data).unwrap();
    v.store.put_item(&changed).unwrap();
    assert!(matches!(v.validate_outgoing_snapshot(&changed), Err(VaultError::ConflictStale)));
    assert!(!v.acknowledge_snapshot(&changed).unwrap());
    assert_eq!(v.get_conflict(&first.id).unwrap().state, ConflictState::ResolutionPending);
    assert!(matches!(v.export_backup(), Err(VaultError::ConflictPending)));
    let fresh = v.refresh_conflict(&first.id).unwrap();
    assert_ne!(fresh.id, first.id);
    assert_eq!(fresh.state, ConflictState::Pending);
    assert!(v.store.dirty_items().unwrap().is_empty());
}

#[test]
fn active_conflicts_reject_disconnect_and_cloud_delete_before_side_effects() {
    use base64::Engine;
    let (mut v, _, r) = fixture();
    apply(&mut v, &r);
    let session = v.session().unwrap();
    let record = crate::store::RemoteRecord {
        server_url: "http://127.0.0.1:1".into(),
        device_id: Uuid::new_v4().to_string(),
        device_name: "test".into(),
        expires_at: i64::MAX,
        token_enc: base64::engine::general_purpose::STANDARD.encode(
            sealed::seal(&session.vault_key, b"session-token", &crate::vault::aad("session-token", &session.account.account_id)).unwrap(),
        ),
    };
    let vault = session.account.vault_id.clone();
    v.store.save_remote(&record).unwrap();
    v.store.set_cursor(&vault, 99, 123).unwrap();
    let id = v.list_conflicts(false).unwrap()[0].id.clone();
    for state in [ConflictState::Pending, ConflictState::ResolutionPending] {
        assert_eq!(v.get_conflict(&id).unwrap().state, state);
        assert!(matches!(v.disconnect(), Err(VaultError::ConflictPending)));
        // 连凭据校验之前就拒绝，不能先发送 DELETE 或清除 remote 再报错。
        assert!(matches!(v.delete_remote_account("wrong", "wrong"), Err(VaultError::ConflictPending)));
        assert_eq!(v.store.load_remote().unwrap(), Some(record.clone()));
        assert_eq!(v.store.cursor(&vault).unwrap(), 99);
        assert_eq!(v.get_conflict(&id).unwrap().state, state);
        if state == ConflictState::Pending {
            v.resolve_conflict(&id, choose_local()).unwrap();
        }
    }
}

#[test]
fn offline_disconnect_keeps_items_but_failed_cloud_delete_keeps_remote() {
    use base64::Engine;
    let (mut v, enrollment) = new_vault();
    let item = v.create_item(ItemData::new(ItemKind::Note, "离线条目保留")).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let session = v.session().unwrap();
    let record = crate::store::RemoteRecord {
        server_url: format!("http://{address}"),
        device_id: Uuid::new_v4().to_string(),
        device_name: "test".into(),
        expires_at: i64::MAX,
        token_enc: base64::engine::general_purpose::STANDARD.encode(
            sealed::seal(&session.vault_key, b"session-token", &crate::vault::aad("session-token", &session.account.account_id)).unwrap(),
        ),
    };
    let vault = session.account.vault_id.clone();
    v.store.save_remote(&record).unwrap();
    v.store.set_cursor(&vault, 99, 123).unwrap();
    assert!(matches!(v.delete_remote_account(PW, &enrollment.secret_key), Err(VaultError::Network(_))));
    assert_eq!(v.store.load_remote().unwrap(), Some(record));
    assert_eq!(v.store.cursor(&vault).unwrap(), 99);
    v.store.transaction(|s| s.set_setting("rollback_verified", "yes")).unwrap();
    v.disconnect().unwrap();
    assert_eq!(v.store.load_remote().unwrap(), None);
    assert_eq!(v.store.cursor(&vault).unwrap(), 0);
    assert_eq!(v.get_item(&item.id).unwrap(), item);
}

#[test]
fn unauthorized_logout_still_disconnects_but_cloud_delete_is_not_reported_successful() {
    use base64::Engine;
    use std::io::{Read, Write};
    let (mut v, enrollment) = new_vault();
    let item = v.create_item(ItemData::new(ItemKind::Note, "会话过期仍保留条目")).unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let mut requests = Vec::new();
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
            let mut request = [0; 4096];
            let n = stream.read(&mut request).unwrap();
            requests.push(String::from_utf8_lossy(&request[..n]).into_owned());
            let body = r#"{"code":"unauthorized","message":"expired"}"#;
            write!(
                stream,
                "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        }
        requests
    });
    let session = v.session().unwrap();
    let record = crate::store::RemoteRecord {
        server_url: format!("http://{address}"),
        device_id: Uuid::new_v4().to_string(),
        device_name: "test".into(),
        expires_at: 0,
        token_enc: base64::engine::general_purpose::STANDARD.encode(
            sealed::seal(&session.vault_key, b"expired-token", &crate::vault::aad("session-token", &session.account.account_id)).unwrap(),
        ),
    };
    let vault = session.account.vault_id.clone();
    v.store.save_remote(&record).unwrap();
    v.store.set_cursor(&vault, 99, 123).unwrap();
    assert!(matches!(v.delete_remote_account(PW, &enrollment.secret_key), Err(VaultError::Server { status: 401, .. })));
    assert_eq!(v.store.load_remote().unwrap(), Some(record));
    assert_eq!(v.store.cursor(&vault).unwrap(), 99);
    v.disconnect().unwrap();
    assert_eq!(v.store.load_remote().unwrap(), None);
    assert_eq!(v.store.cursor(&vault).unwrap(), 0);
    assert_eq!(v.get_item(&item.id).unwrap(), item);
    let requests = server.join().unwrap();
    assert!(requests[0].starts_with("DELETE /v1/account "));
    assert!(requests[1].starts_with("POST /v1/auth/logout "));
}

#[test]
fn serialized_contract_is_explicit_and_roundtrips() {
    let resolution =
        ConflictResolution::Fields { choices: vec![FieldDecision { field: ConflictField::CustomFields, side: ConflictSide::Remote }] };
    let value = serde_json::to_value(&resolution).unwrap();
    assert_eq!(value["mode"], "fields");
    assert_eq!(value["choices"][0]["field"], "customFields");
    assert_eq!(value["choices"][0]["side"], "remote");
    let _: ConflictResolution = serde_json::from_value(value).unwrap();
    assert!(serde_json::from_str::<ConflictResolution>(r#"{"mode":"whole","side":"local","ignored":true}"#).is_err());
    assert!(serde_json::from_str::<FieldDecision>(r#"{"field":"notes","side":"local","ignored":true}"#).is_err());
}

/// 冲突字段的 wire 名是跨语言契约：Dart 侧 `ConflictField` 用 `values.byName` 解析这些
/// 字符串，多一个少一个都会在运行期抛异常。这里把清单钉死，改枚举必须同步改 Dart
/// （对应断言在 `app/test/conflict_field_contract_test.dart`）。
#[test]
fn conflict_field_wire_names_are_a_frozen_contract() {
    const EXPECTED: [&str; 15] = [
        "type",
        "title",
        "urls",
        "username",
        "password",
        "totp",
        "notes",
        "card",
        "identity",
        "customFields",
        "favorite",
        "tags",
        "category",
        "deleted",
        "resolution",
    ];
    let actual: Vec<String> = [
        ConflictField::Type,
        ConflictField::Title,
        ConflictField::Urls,
        ConflictField::Username,
        ConflictField::Password,
        ConflictField::Totp,
        ConflictField::Notes,
        ConflictField::Card,
        ConflictField::Identity,
        ConflictField::CustomFields,
        ConflictField::Favorite,
        ConflictField::Tags,
        ConflictField::Category,
        ConflictField::Deleted,
        ConflictField::Resolution,
    ]
    .iter()
    .map(|f| serde_json::to_value(f).unwrap().as_str().unwrap().to_string())
    .collect();
    assert_eq!(actual, EXPECTED);

    // 反向：合并器会返回的标签必须都能被 `from_merge` 识别，否则会 panic 在 unreachable。
    // `deleted` 与 `resolution` 不参与内容合并（前者由墓碑合并单独处理，后者要求整条裁决），
    // 因此不在 `from_merge` 的可接受集合里。
    for name in [
        "type",
        "title",
        "urls",
        "username",
        "password",
        "totp",
        "notes",
        "card",
        "identity",
        "customFields",
        "favorite",
        "tags",
        "category",
    ] {
        let _ = ConflictField::from_merge(name);
    }
}
