//! shuiosd 配置：`/etc/shuios/shuios.json`
//!
//! 选择 JSON 而不是 TOML，是为了让守护进程只依赖 `serde_json`——
//! 镜像要小，依赖越少越好；`shui config` 会把它格式化打印出来。

use serde::{Deserialize, Serialize};
use shuios_proto::{AgentSpec, Limits, AGENT_LOG_DIR, DEFAULT_SOCKET, MODEL_DIR, STATE_DIR};
use std::path::Path;

/// 推理端点默认值（`/etc` 静态配置只兜底；运行时配置见 `ai.json`）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Llm {
    /// 例如 `http://127.0.0.1:8080` 或 `https://api.deepseek.com/v1`。
    #[serde(default = "default_endpoint")]
    pub endpoint: String,
    /// 默认模型名，透传给推理服务。
    #[serde(default = "default_model")]
    pub model: String,
    /// 可选的 Bearer token。**不会被序列化**（`config.get` 不返回密钥）。
    #[serde(default, skip_serializing)]
    pub api_key: Option<String>,
    /// 单次请求超时（秒）。
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
    /// 采样温度。
    #[serde(default = "default_temp")]
    pub temperature: f64,
}

impl Default for Llm {
    fn default() -> Self {
        Self {
            endpoint: default_endpoint(),
            model: default_model(),
            api_key: None,
            timeout_secs: default_timeout(),
            temperature: default_temp(),
        }
    }
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
fn default_temp() -> f64 {
    0.2
}

/// 守护进程配置。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// 控制平面套接字。
    #[serde(default = "default_socket")]
    pub socket: String,
    /// 智能体默认资源上限。
    #[serde(default)]
    pub default_limits: Limits,
    /// 开机自启的智能体。
    #[serde(default)]
    pub autostart: Vec<AgentSpec>,
    /// 推理端点配置。
    #[serde(default)]
    pub llm: Llm,
    /// 智能体日志目录。
    #[serde(default = "default_log_dir")]
    pub agent_log_dir: String,
    /// 本地模型仓库。
    #[serde(default = "default_model_dir")]
    pub model_dir: String,
    /// 状态目录。
    #[serde(default = "default_state_dir")]
    pub state_dir: String,
    /// 是否启用内置 MCP 工具。
    #[serde(default = "yes")]
    pub mcp_tools: bool,
    /// 同时运行的智能体上限。
    #[serde(default = "default_max_agents")]
    pub max_agents: usize,
    /// 是否允许智能体自行派生子智能体。
    #[serde(default)]
    pub allow_nested_spawn: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            socket: default_socket(),
            default_limits: Limits::default(),
            autostart: Vec::new(),
            llm: Llm::default(),
            agent_log_dir: default_log_dir(),
            model_dir: default_model_dir(),
            state_dir: default_state_dir(),
            mcp_tools: true,
            max_agents: default_max_agents(),
            allow_nested_spawn: false,
        }
    }
}

fn default_socket() -> String {
    DEFAULT_SOCKET.to_string()
}
fn default_log_dir() -> String {
    AGENT_LOG_DIR.to_string()
}
fn default_model_dir() -> String {
    MODEL_DIR.to_string()
}
fn default_state_dir() -> String {
    STATE_DIR.to_string()
}
fn default_max_agents() -> usize {
    64
}
fn yes() -> bool {
    true
}

impl Config {
    /// 读取配置；文件不存在时返回内置默认值（不算错误）。
    pub fn load(path: &str) -> Result<Self, String> {
        let p = Path::new(path);
        if !p.exists() {
            return Ok(Self::default());
        }
        let text = std::fs::read_to_string(p).map_err(|e| format!("{path}: {e}"))?;
        if text.trim().is_empty() {
            return Ok(Self::default());
        }
        serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))
    }
}
