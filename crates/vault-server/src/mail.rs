//! 邮件通知（计划书 F-01 / F-09）：新设备验证码、登录/设备/主密码变更/恢复告警。
//! SMTP 发送使用 `lettre`；`log` 模式仅供本地开发，把邮件写入日志。

use std::sync::{Arc, Mutex};

use lettre::message::header::ContentType;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};

use crate::config::MailConfig;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mail {
    pub to: String,
    pub subject: String,
    pub body: String,
}

#[derive(Clone)]
pub enum Mailer {
    Smtp {
        transport: AsyncSmtpTransport<Tokio1Executor>,
        from: String,
    },
    Log,
    /// 测试用：收集到内存
    Memory(Arc<Mutex<Vec<Mail>>>),
}

impl Mailer {
    pub fn from_config(cfg: &MailConfig) -> anyhow::Result<Self> {
        if cfg.mode != "smtp" {
            tracing::warn!("mail.mode=log：邮件只会写入日志，切勿用于生产环境");
            return Ok(Mailer::Log);
        }
        let mut builder = AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&cfg.smtp_host)?.port(cfg.smtp_port);
        if !cfg.smtp_username.is_empty() {
            builder = builder.credentials(Credentials::new(cfg.smtp_username.clone(), cfg.smtp_password.clone().unwrap_or_default()));
        }
        Ok(Mailer::Smtp { transport: builder.build(), from: cfg.from.clone() })
    }

    /// 异步发送，失败只记日志，不影响主流程。
    pub fn send(&self, mail: Mail) {
        match self {
            Mailer::Log => {
                tracing::info!(target: "mail", to = %mask(&mail.to), subject = %mail.subject, body = %mail.body, "mail (log mode)")
            }
            Mailer::Memory(store) => store.lock().expect("mail store").push(mail),
            Mailer::Smtp { transport, from } => {
                let transport = transport.clone();
                let from = from.clone();
                tokio::spawn(async move {
                    let msg = match (from.parse(), mail.to.parse()) {
                        (Ok(f), Ok(t)) => {
                            Message::builder().from(f).to(t).subject(&mail.subject).header(ContentType::TEXT_PLAIN).body(mail.body.clone())
                        }
                        _ => {
                            tracing::error!(target: "mail", "invalid mail address");
                            return;
                        }
                    };
                    match msg {
                        Ok(m) => {
                            if let Err(e) = transport.send(m).await {
                                tracing::error!(target: "mail", error = %e, "smtp send failed");
                            }
                        }
                        Err(e) => tracing::error!(target: "mail", error = %e, "build mail failed"),
                    }
                });
            }
        }
    }
}

/// 日志中的邮箱脱敏：a***@example.com
pub fn mask(email: &str) -> String {
    match email.split_once('@') {
        Some((l, d)) => format!("{}***@{d}", l.chars().next().unwrap_or('*')),
        None => "***".into(),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn masks_email() {
        assert_eq!(super::mask("alice@example.com"), "a***@example.com");
        assert_eq!(super::mask("bad"), "***");
    }
}
