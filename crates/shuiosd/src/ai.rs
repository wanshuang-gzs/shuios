//! AI 配置的持久化。
//!
//! 密钥只落在 `/var/lib/shuios/state/ai.json`（0600，原子写入）；
//! `/etc/shuios/shuios.json` 的 `llm` 段只用来提供首次启动默认值。

use crate::config::Config;
use shuios_proto::ai::{endpoint_is_loopback, AiConfig, AI_CONFIG};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// 读取运行时配置；文件不存在时沿用 `/etc` 的 llm 默认值。
pub fn load(cfg: &Config) -> AiConfig {
    let path = Path::new(AI_CONFIG);
    match fs::read_to_string(path) {
        Ok(text) if !text.trim().is_empty() => match serde_json::from_str::<AiConfig>(&text) {
            Ok(mut c) => {
                normalize(&mut c);
                tighten_permissions(path);
                c
            }
            Err(e) => {
                eprintln!("shuiosd: 解析 {AI_CONFIG} 失败（{e}），使用 /etc 默认值");
                from_config(cfg)
            }
        },
        Ok(_) => from_config(cfg),
        Err(e) if e.kind() == io::ErrorKind::NotFound => from_config(cfg),
        Err(e) => {
            eprintln!("shuiosd: 读取 {AI_CONFIG} 失败（{e}），使用 /etc 默认值");
            from_config(cfg)
        }
    }
}

/// 原子写入；先写 0600 临时文件再 rename，避免读到半个配置。
pub fn save(cfg: &AiConfig) -> Result<(), String> {
    cfg.validate()?;
    let path = Path::new(AI_CONFIG);
    let dir = path
        .parent()
        .ok_or_else(|| "AI 配置路径没有父目录".to_string())?;
    fs::create_dir_all(dir).map_err(|e| format!("创建 {dir:?} 失败: {e}"))?;

    let text = serde_json::to_string_pretty(cfg).map_err(|e| e.to_string())? + "\n";
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let tmp = dir.join(format!(".ai.json.tmp.{}.{nanos}", std::process::id()));

    let write = (|| -> io::Result<()> {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(text.as_bytes())?;
        f.flush()?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        if let Ok(d) = File::open(dir) {
            let _ = d.sync_all();
        }
        Ok(())
    })();
    if let Err(e) = write {
        let _ = fs::remove_file(&tmp);
        return Err(format!("写入 {AI_CONFIG} 失败: {e}"));
    }
    Ok(())
}

/// 文件权限过宽时收紧到 0600（例如从旧版本/手工拷贝来的文件）。
fn tighten_permissions(path: &Path) {
    if let Ok(meta) = fs::metadata(path) {
        if meta.permissions().mode() & 0o077 != 0 {
            if let Err(e) = fs::set_permissions(path, fs::Permissions::from_mode(0o600)) {
                eprintln!("shuiosd: 无法把 {AI_CONFIG} 收紧到 0600: {e}");
            }
        }
    }
}

fn from_config(cfg: &Config) -> AiConfig {
    let endpoint = cfg.llm.endpoint.trim().trim_end_matches('/').to_string();
    AiConfig {
        provider: if endpoint_is_loopback(&endpoint) {
            "local".to_string()
        } else {
            "custom".to_string()
        },
        endpoint,
        model: cfg.llm.model.trim().to_string(),
        api_key: cfg.llm.api_key.clone().unwrap_or_default().trim().to_string(),
        timeout_secs: cfg.llm.timeout_secs.max(5),
        temperature: cfg.llm.temperature,
    }
}

fn normalize(c: &mut AiConfig) {
    c.provider = c.provider.trim().to_string();
    c.endpoint = c.endpoint.trim().trim_end_matches('/').to_string();
    c.model = c.model.trim().to_string();
    c.api_key = c.api_key.trim().to_string();
}
