//! 配置：默认值 → 配置文件（`VAULTONE_CONFIG`，默认 `vaultone.toml`，可缺省）→ 环境变量 `VAULTONE_*`。
//! 使用 `figment` 分层加载。服务端主密钥**没有默认值**，缺失即拒绝启动（禁止硬编码密钥）。

use std::net::SocketAddr;

use figment::providers::{Env, Format, Serialized, Toml};
use figment::Figment;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// 监听地址
    pub bind: SocketAddr,
    /// `sqlite://path?mode=rwc` 或 `postgres://user:pass@host/db`
    pub database_url: String,
    /// 服务端主密钥（64 位十六进制 = 32 字节），用于邮箱 HMAC 索引、邮箱 AES-256-GCM 加密、
    /// SRP 握手临时状态加密。生成：`vault-server gen-secret`
    #[serde(default)]
    pub server_secret: Option<String>,
    pub session_ttl_days: i64,
    /// 反向代理之后部署时置 true，按 X-Forwarded-For 识别客户端 IP 做限流
    pub trust_proxy: bool,
    /// 登录/注册/恢复等认证接口：每 IP 每 N 毫秒补充 1 次，突发上限 burst
    pub auth_rate_ms: u64,
    pub auth_burst: u32,
    /// 其他接口
    pub api_rate_ms: u64,
    pub api_burst: u32,
    /// 日志：`pretty` | `json`
    pub log_format: String,
    /// tracing EnvFilter，例如 `info,vault_server=debug`
    pub log_level: String,
    /// 允许的浏览器来源（CORS），逗号分隔；为空表示不开放 CORS
    pub cors_origins: String,
    pub mail: MailConfig,
    /// 条目历史版本保留天数（计划书 P1：30 天）
    pub version_retention_days: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MailConfig {
    /// `smtp` | `log`（仅开发环境：把邮件正文写入日志）
    pub mode: String,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub smtp_username: String,
    #[serde(default)]
    pub smtp_password: Option<String>,
    pub from: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            bind: "0.0.0.0:8787".parse().expect("static addr"),
            database_url: "sqlite://vaultone.db?mode=rwc".into(),
            server_secret: None,
            session_ttl_days: 60,
            trust_proxy: false,
            auth_rate_ms: 3000,
            auth_burst: 10,
            api_rate_ms: 100,
            api_burst: 120,
            log_format: "pretty".into(),
            log_level: "info".into(),
            cors_origins: String::new(),
            mail: MailConfig {
                mode: "log".into(),
                smtp_host: String::new(),
                smtp_port: 587,
                smtp_username: String::new(),
                smtp_password: None,
                from: "VaultOne <no-reply@vaultone.app>".into(),
            },
            version_retention_days: 30,
        }
    }
}

impl Config {
    pub fn load() -> anyhow::Result<Self> {
        let file = std::env::var("VAULTONE_CONFIG").unwrap_or_else(|_| "vaultone.toml".into());
        let cfg: Config = Figment::from(Serialized::defaults(Config::default()))
            .merge(Toml::file(file))
            .merge(Env::prefixed("VAULTONE_").split("__"))
            .extract()?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        let secret = self.secret_bytes()?;
        anyhow::ensure!(secret.len() == 32, "server_secret 必须是 32 字节（64 位十六进制）");
        anyhow::ensure!(secret.iter().any(|b| *b != secret[0]), "server_secret 熵不足");
        anyhow::ensure!((1..=365).contains(&self.session_ttl_days), "session_ttl_days 需在 1-365");
        anyhow::ensure!(matches!(self.mail.mode.as_str(), "smtp" | "log"), "mail.mode 只能是 smtp 或 log");
        if self.mail.mode == "smtp" {
            anyhow::ensure!(!self.mail.smtp_host.is_empty(), "mail.smtp_host 未配置");
        }
        Ok(())
    }

    pub fn secret_bytes(&self) -> anyhow::Result<Vec<u8>> {
        let hex = self
            .server_secret
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("缺少 VAULTONE_SERVER_SECRET（运行 `vault-server gen-secret` 生成）"))?;
        decode_hex(hex.trim()).ok_or_else(|| anyhow::anyhow!("server_secret 不是合法的十六进制"))
    }

    pub fn is_sqlite(&self) -> bool {
        self.database_url.starts_with("sqlite:")
    }
}

fn decode_hex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_or_weak_secret_is_rejected() {
        let mut c = Config::default();
        assert!(c.validate().is_err());
        c.server_secret = Some("00".repeat(32));
        assert!(c.validate().is_err());
        c.server_secret = Some("zz".repeat(32));
        assert!(c.validate().is_err());
        c.server_secret = Some("0123456789abcdef".repeat(4));
        assert!(c.validate().is_ok());
    }
}
