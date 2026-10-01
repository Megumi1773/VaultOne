//! 云账户入口；本地秘密准备不等于云注册成功。
use super::vault::{with_vault, EnrollmentDto};
use super::BridgeResult;

pub fn prepare_registration(server_url: String, email: String, password: String, device_name: String) -> BridgeResult<EnrollmentDto> {
    with_vault(|v| {
        v.prepare_cloud_registration(&server_url, &email, &password, &device_name, vault_core::KdfParams::recommended()).map(Into::into)
    })
}

pub fn complete_registration(
    server_url: String,
    password: String,
    secret_key: String,
    device_name: String,
) -> BridgeResult<Option<EnrollmentDto>> {
    with_vault(|v| Ok(v.complete_cloud_registration(&server_url, &password, &secret_key, &device_name)?.map(Into::into)))
}

pub fn pending_enrollment() -> BridgeResult<Option<EnrollmentDto>> {
    with_vault(|v| Ok(v.pending_cloud_enrollment()?.map(Into::into)))
}

pub fn pending_operation() -> BridgeResult<Option<String>> {
    with_vault(|v| v.pending_cloud_operation())
}

pub fn confirm_enrollment() -> BridgeResult<()> {
    with_vault(|v| v.confirm_cloud_enrollment())
}

pub fn reconnect(server_url: String, password: String, secret_key: String) -> BridgeResult<()> {
    with_vault(|v| v.reconnect_cloud(&server_url, &password, &secret_key))
}

pub fn logout() -> BridgeResult<()> {
    with_vault(|v| v.logout_cloud())
}

pub fn change_password(current: String, secret_key: String, new_password: String) -> BridgeResult<()> {
    with_vault(|v| v.change_cloud_password(&current, &secret_key, &new_password))
}

pub fn recover(
    server_url: String,
    email: String,
    recovery_code: String,
    secret_key: String,
    new_password: String,
    device_name: String,
) -> BridgeResult<EnrollmentDto> {
    with_vault(|v| v.recover_cloud_account(&server_url, &email, &recovery_code, &secret_key, &new_password, &device_name).map(Into::into))
}
