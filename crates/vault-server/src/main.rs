//! vault-server 命令行入口。
//!
//! ```text
//! vault-server            启动服务（读取 vaultone.toml 与 VAULTONE_* 环境变量）
//! vault-server gen-secret 生成 32 字节服务端主密钥（十六进制）
//! vault-server check      校验配置并测试数据库连接后退出
//! ```

use tracing_subscriber::EnvFilter;
use vault_server::config::Config;
use vault_server::mail::Mailer;
use vault_server::AppState;

fn init_logging(cfg: &Config) {
    let filter = EnvFilter::try_from_env("VAULTONE_LOG").unwrap_or_else(|_| EnvFilter::new(&cfg.log_level));
    let builder = tracing_subscriber::fmt().with_env_filter(filter).with_target(true);
    if cfg.log_format == "json" {
        builder.json().flatten_event(true).init();
    } else {
        builder.init();
    }
}

#[tokio::main]
async fn main() {
    if let Err(e) = run().await {
        eprintln!("vault-server: {e:#}");
        std::process::exit(1);
    }
}

async fn run() -> anyhow::Result<()> {
    let cmd = std::env::args().nth(1).unwrap_or_default();
    if cmd == "gen-secret" {
        let bytes = vault_crypto::secret::random_bytes::<32>();
        println!("{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
        return Ok(());
    }
    let cfg = Config::load()?;
    init_logging(&cfg);
    let mailer = Mailer::from_config(&cfg.mail)?;
    let bind = cfg.bind;
    let state = AppState::new(cfg, mailer, false).await?;
    if cmd == "check" {
        tracing::info!("configuration and database OK");
        return Ok(());
    }
    let listener = tokio::net::TcpListener::bind(bind).await?;
    tracing::info!(%bind, version = env!("CARGO_PKG_VERSION"), "vault-server listening");
    vault_server::serve(state, listener).await
}
