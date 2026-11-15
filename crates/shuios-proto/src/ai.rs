//! AI 推理接入配置。
//!
//! 运行时的权威配置在 `/var/lib/shuios/state/ai.json`（0600，由 shuiosd
//! 写入并持有）；`/etc/shuios/shuios.json` 里的 `llm` 段只作为首次启动
//! 的默认值。控制平面只返回 [`AiStatus`]（密钥只给后四位），完整密钥
//! 永远不经过 RPC。

use serde::{Deserialize, Serialize};

/// 持久化的 AI 配置路径。
pub const AI_CONFIG: &str = "/var/lib/shuios/state/ai.json";

/// 内置的推理服务预设。
#[derive(Debug, Clone, Copy, Serialize)]
pub struct AiProvider {
    pub id: &'static str,
    pub name: &'static str,
    pub endpoint: &'static str,
    pub model: &'static str,
    /// 是否本地回环（不需要 API key）。
    pub local: bool,
}

pub const AI_PROVIDERS: &[AiProvider] = &[
    AiProvider {
        id: "local",
        name: "本地模型（llama.cpp）",
        endpoint: "http://127.0.0.1:8080",
        model: "local",
        local: true,
    },
    AiProvider {
        id: "deepseek",
        name: "DeepSeek",
        endpoint: "https://api.deepseek.com/v1",
        model: "deepseek-chat",
        local: false,
    },
    AiProvider {
        id: "qwen",
        name: "通义千问（DashScope）",
        endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
        model: "qwen-plus",
        local: false,
    },
    AiProvider {
        id: "moonshot",
        name: "Moonshot（Kimi）",
        endpoint: "https://api.moonshot.cn/v1",
        model: "moonshot-v1-8k",
        local: false,
    },
    AiProvider {
        id: "openai",
        name: "OpenAI",
        endpoint: "https://api.openai.com/v1",
        model: "gpt-4o-mini",
        local: false,
    },
    AiProvider {
        id: "custom",
        name: "自定义（OpenAI 兼容）",
        endpoint: "",
        model: "",
        local: false,
    },
];

/// 按 id 查预设。
pub fn find_provider(id: &str) -> Option<&'static AiProvider> {
    AI_PROVIDERS.iter().find(|p| p.id == id)
}

/// 端点的 host 是否为本机回环。
pub fn endpoint_is_loopback(endpoint: &str) -> bool {
    let s = endpoint.trim();
    let rest = s
        .strip_prefix("http://")
        .or_else(|| s.strip_prefix("https://"))
        .unwrap_or(s);
    let authority = rest.split('/').next().unwrap_or("");
    let host = if let Some(h) = authority.strip_prefix('[') {
        h.split(']').next().unwrap_or("")
    } else {
        authority.rsplit_once(':').map(|(h, _)| h).unwrap_or(authority)
    };
    matches!(host, "127.0.0.1" | "localhost" | "::1")
}

/// 完整配置（含密钥；只在 daemon 内存与 0600 文件中存在）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiConfig {
    /// 预设 id，例如 `deepseek`、`local`、`custom`。
    #[serde(default = "default_provider")]
    pub provider: String,
    /// OpenAI 兼容基础地址，可带 `/v1`。
    #[serde(default = "default_endpoint")]
    pub endpoint: String,
    /// 透传给服务商的模型名。
    #[serde(default = "default_model")]
    pub model: String,
    /// Bearer token；本地回环端点可为空。
    #[serde(default)]
    pub api_key: String,
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
    #[serde(default = "default_temperature")]
    pub temperature: f64,
}

impl Default for AiConfig {
    fn default() -> Self {
        Self {
            provider: default_provider(),
            endpoint: default_endpoint(),
            model: default_model(),
            api_key: String::new(),
            timeout_secs: default_timeout(),
            temperature: default_temperature(),
        }
    }
}

fn default_provider() -> String {
    "local".to_string()
}
fn default_endpoint() -> String {
    "http://127.0.0.1:8080".to_string()
}
fn default_model() -> String {
    "local".to_string()
}
fn default_timeout() -> u64 {
    120
}
fn default_temperature() -> f64 {
    0.2
}

impl AiConfig {
    pub fn is_local(&self) -> bool {
        endpoint_is_loopback(&self.endpoint)
    }

    pub fn key_set(&self) -> bool {
        !self.api_key.trim().is_empty()
    }

    /// 只暴露末四位，给状态页与日志用。
    pub fn key_hint(&self) -> Option<String> {
        let k = self.api_key.trim();
        if k.is_empty() {
            None
        } else if k.chars().count() <= 4 {
            Some("…".to_string())
        } else {
            let tail: String = k
                .chars()
                .rev()
                .take(4)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            Some(format!("…{tail}"))
        }
    }

    /// 预设的中文名；未匹配时退回 id 或“自定义”。
    pub fn provider_name(&self) -> String {
        if let Some(p) = find_provider(&self.provider) {
            return p.name.to_string();
        }
        if self.provider.trim().is_empty() || self.provider == "custom" {
            "自定义（OpenAI 兼容）".to_string()
        } else {
            self.provider.clone()
        }
    }

    /// 基础字段校验；端点安全校验在 shui-llm 里（需要 http/https 规则）。
    pub fn validate(&self) -> Result<(), String> {
        if self.provider.trim().is_empty() {
            return Err("提供商不能为空".to_string());
        }
        if self.endpoint.trim().is_empty() {
            return Err("推理端点不能为空".to_string());
        }
        if self.model.trim().is_empty() {
            return Err("模型名不能为空".to_string());
        }
        if !(5..=600).contains(&self.timeout_secs) {
            return Err("超时必须在 5 到 600 秒之间".to_string());
        }
        if !(0.0..=2.0).contains(&self.temperature) {
            return Err("temperature 必须在 0 到 2 之间".to_string());
        }
        Ok(())
    }

    pub fn status(&self) -> AiStatus {
        AiStatus {
            provider: self.provider.clone(),
            provider_name: self.provider_name(),
            endpoint: self.endpoint.clone(),
            model: self.model.clone(),
            key_set: self.key_set(),
            key_hint: self.key_hint(),
            timeout_secs: self.timeout_secs,
            temperature: self.temperature,
            local: self.is_local(),
            secure: self.is_local() || self.endpoint.starts_with("https://"),
            ready: self.is_local() || self.key_set(),
            configured: find_provider(&self.provider).is_some() || !self.provider.is_empty(),
            config_path: AI_CONFIG.to_string(),
        }
    }
}

/// 可安全展示的 AI 状态（不含密钥）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiStatus {
    pub provider: String,
    pub provider_name: String,
    pub endpoint: String,
    pub model: String,
    pub key_set: bool,
    pub key_hint: Option<String>,
    pub timeout_secs: u64,
    pub temperature: f64,
    pub local: bool,
    pub secure: bool,
    pub ready: bool,
    pub configured: bool,
    pub config_path: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_hint_never_reveals_more_than_tail() {
        let mut c = AiConfig::default();
        c.api_key = "sk-1234567890abcd".into();
        assert_eq!(c.key_hint().as_deref(), Some("…abcd"));
        c.api_key = "abc".into();
        assert_eq!(c.key_hint().as_deref(), Some("…"));
        c.api_key.clear();
        assert!(c.key_hint().is_none());
    }

    #[test]
    fn local_default_is_ready_without_key() {
        let s = AiConfig::default().status();
        assert!(s.local);
        assert!(s.secure);
        assert!(s.ready);
        assert!(!s.key_set);
    }

    #[test]
    fn remote_without_key_is_not_ready() {
        let c = AiConfig {
            provider: "deepseek".into(),
            endpoint: "https://api.deepseek.com/v1".into(),
            model: "deepseek-chat".into(),
            ..Default::default()
        };
        let s = c.status();
        assert!(!s.local);
        assert!(s.secure);
        assert!(!s.ready);
        assert_eq!(s.provider_name, "DeepSeek");
    }

    #[test]
    fn loopback_detection_handles_ports_and_ipv6() {
        assert!(endpoint_is_loopback("http://127.0.0.1:8080"));
        assert!(endpoint_is_loopback("http://localhost:8080/v1"));
        assert!(endpoint_is_loopback("http://[::1]:8080"));
        assert!(!endpoint_is_loopback("https://api.deepseek.com/v1"));
    }

    #[test]
    fn config_round_trips_through_json() {
        let mut c = AiConfig::default();
        c.provider = "deepseek".into();
        c.endpoint = "https://api.deepseek.com/v1".into();
        c.api_key = "sk-test".into();
        let text = serde_json::to_string(&c).unwrap();
        let back: AiConfig = serde_json::from_str(&text).unwrap();
        assert_eq!(back.api_key, "sk-test");
        assert_eq!(back.model, "local");
    }
}
