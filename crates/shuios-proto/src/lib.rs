//! # shuios-proto — 氵系统 协议与客户端库
//!
//! shuios 把「智能体」当作一等公民系统进程来管理。`shuiosd` 在
//! `/run/shuios/shuiosd.sock` 上暴露一个 **按行分隔的 JSON** 接口
//! （JSON Lines RPC），本 crate 是这套契约的唯一权威定义：
//!
//! * 请求/响应/错误信封：[`Request`] / [`Response`] / [`ErrorObj`]
//! * 业务数据结构：[`AgentSpec`] / [`AgentInfo`] / [`SystemInfo`] / [`ModelInfo`]
//! * 路径常量：见 [`DEFAULT_SOCKET`]、[`STATE_DIR`]、[`MODEL_DIR`] 等
//! * 同步客户端：[`client::Client`]（`shui` 与 `shui-ctl` 共用）
//!
//! 设计约束：**只依赖 `serde` / `serde_json`**。镜像要小、交叉编译要稳，
//! 因此这里不使用异步运行时、不使用 TLS 栈。

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// 协议主版本；不兼容变更时递增。
pub const PROTOCOL_VERSION: u32 = 1;
/// shuios 发行版版本号。
pub const SHUIOS_VERSION: &str = "0.1.0";
/// 发行版代号。
pub const SHUIOS_CODENAME: &str = "泉";

pub mod ai;
pub mod mcp;
pub mod models;

/// 控制平面默认套接字路径。
pub const DEFAULT_SOCKET: &str = "/run/shuios/shuiosd.sock";
/// MCP 总线目录（每个服务一个套接字）。
pub const MCP_DIR: &str = "/run/shuios/mcp";
/// 持久状态目录。
pub const STATE_DIR: &str = "/var/lib/shuios";
/// 本地模型仓库。
pub const MODEL_DIR: &str = "/var/lib/shuios/models";
/// 智能体日志目录。
pub const AGENT_LOG_DIR: &str = "/var/log/shuios/agents";
/// 默认配置文件。
pub const DEFAULT_CONFIG: &str = "/etc/shuios/shuios.json";
/// cgroup v2 挂载点。
pub const CGROUP_ROOT: &str = "/sys/fs/cgroup";
/// shuios 的 cgroup 子树名。
pub const CGROUP_SLICE: &str = "shuios";

// ---------------------------------------------------------------------------
// 信封
// ---------------------------------------------------------------------------

/// 一次 RPC 请求。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    /// 调用方生成的请求 id；响应会原样带回。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// 方法名，例如 `agent.spawn`。
    pub method: String,
    /// 方法参数；无参数时为 `null`。
    #[serde(default)]
    pub params: serde_json::Value,
}

impl Request {
    /// 构造一个请求。
    pub fn new(method: impl Into<String>, params: serde_json::Value) -> Self {
        Self { id: None, method: method.into(), params }
    }
}

/// 一次 RPC 响应：`result` 与 `error` 恰有一个非空。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorObj>,
}

impl Response {
    /// 成功响应。
    pub fn ok(result: serde_json::Value) -> Self {
        Self { id: None, result: Some(result), error: None }
    }

    /// 失败响应。
    pub fn err(code: i32, message: impl Into<String>) -> Self {
        Self { id: None, result: None, error: Some(ErrorObj { code, message: message.into(), data: None }) }
    }

    /// 判定是否成功。
    pub fn is_ok(&self) -> bool {
        self.error.is_none()
    }
}

/// 结构化错误。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorObj {
    /// 错误码（见 [`errcode`]）。
    pub code: i32,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

/// 错误码常量。
pub mod errcode {
    pub const BAD_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const BAD_PARAMS: i32 = -32602;
    pub const INTERNAL: i32 = -32603;
    /// 智能体不存在。
    pub const NO_SUCH_AGENT: i32 = -32001;
    /// 智能体已存在。
    pub const AGENT_EXISTS: i32 = -32002;
    /// 资源受限 / cgroup 不可用。
    pub const NO_CGROUP: i32 = -32003;
    /// AI 未就绪（远程端点缺少 API 密钥）。
    pub const AI_NOT_READY: i32 = -32004;
}

// ---------------------------------------------------------------------------
// 智能体
// ---------------------------------------------------------------------------

/// 智能体可申请的系统能力。v0.1 里由 `shuiosd` 记录并在审计日志中体现。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    /// 只读文件系统。
    FsRead,
    /// 可写某目录（值形如 `fs_write:/workspace`）。
    FsWrite,
    /// 出网访问。
    Net,
    /// 访问模型仓库。
    Model,
    /// 访问 GPU 设备节点。
    Gpu,
    /// 允许再派生子智能体。
    Spawn,
}

/// 资源上限，直接映射到 cgroup v2 控制文件。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Limits {
    /// `/sys/fs/cgroup/.../memory.max`，取值如 `"2G"`、`"512M"`、`"max"`。
    #[serde(default)]
    pub memory_max: Option<String>,
    /// `pids.max`。
    #[serde(default)]
    pub pids_max: Option<u32>,
    /// `cpu.weight`（1..=10000）。
    #[serde(default)]
    pub cpu_weight: Option<u32>,
    /// `io.weight` 里的权重值（1..=1000）。
    #[serde(default)]
    pub io_weight: Option<u32>,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            memory_max: Some("2G".to_string()),
            pids_max: Some(512),
            cpu_weight: Some(100),
            io_weight: None,
        }
    }
}

impl Limits {
    /// 把 `"2G"` 之类的写法换算成字节数；`"max"`/非法值返回 `None`。
    pub fn memory_max_bytes(&self) -> Option<u64> {
        parse_size(self.memory_max.as_deref()?)
    }
}

/// 解析 `123`、`512K`、`2M`、`2G` 形式的尺寸。
pub fn parse_size(s: &str) -> Option<u64> {
    let s = s.trim();
    if s.is_empty() || s.eq_ignore_ascii_case("max") {
        return None;
    }
    let (num, mult) = match s.chars().last()? {
        'k' | 'K' => (&s[..s.len() - 1], 1024u64),
        'm' | 'M' => (&s[..s.len() - 1], 1024u64 * 1024),
        'g' | 'G' => (&s[..s.len() - 1], 1024u64 * 1024 * 1024),
        't' | 'T' => (&s[..s.len() - 1], 1024u64 * 1024 * 1024 * 1024),
        _ => (s, 1u64),
    };
    num.trim().parse::<u64>().ok().map(|v| v.saturating_mul(mult))
}

/// 智能体生命周期状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    /// 正在启动。
    Starting,
    /// 运行中。
    Running,
    /// 已退出（正常或异常，看 exit_code）。
    Exited,
    /// 启动失败。
    Failed,
}

impl AgentState {
    /// 是否处于可被终止的状态。
    pub fn is_live(self) -> bool {
        matches!(self, AgentState::Starting | AgentState::Running)
    }
}

/// 派生子智能体 / 声明式描述。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSpec {
    /// 唯一名字，同时作为 cgroup 与日志文件名。
    pub name: String,
    /// 命令行，`argv[0]` 为可执行文件。
    pub argv: Vec<String>,
    /// 工作目录。
    #[serde(default)]
    pub workdir: Option<String>,
    /// 追加环境变量。
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// 资源上限。
    #[serde(default)]
    pub limits: Limits,
    /// 申请的权限。
    #[serde(default)]
    pub capabilities: Vec<Capability>,
    /// 异常退出后是否自动重启。
    #[serde(default)]
    pub restart: bool,
    /// systemd 风格的服务描述，便于 `shui-ctl` 展示。
    #[serde(default)]
    pub description: Option<String>,
}

impl AgentSpec {
    /// 用 argv 快速构造一个智能体描述。
    pub fn new(name: impl Into<String>, argv: Vec<String>) -> Self {
        Self {
            name: name.into(),
            argv,
            workdir: None,
            env: BTreeMap::new(),
            limits: Limits::default(),
            capabilities: Vec::new(),
            restart: false,
            description: None,
        }
    }
}

/// 智能体运行时视图。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentInfo {
    pub name: String,
    /// 主进程 pid。
    pub pid: u32,
    pub state: AgentState,
    /// Unix 秒时间戳。
    pub started_at: u64,
    pub exit_code: Option<i32>,
    /// 当前内存用量（字节），来自 `memory.current`。
    pub memory_bytes: Option<u64>,
    /// 累计 CPU 时间（微秒），来自 `cpu.stat` 的 `usage_usec`。
    pub cpu_usage_usec: Option<u64>,
    pub limits: Limits,
    pub capabilities: Vec<Capability>,
    pub restart: bool,
    pub description: Option<String>,
    /// 日志文件路径。
    pub log_path: String,
}

// ---------------------------------------------------------------------------
// 系统 / 模型 / MCP
// ---------------------------------------------------------------------------

/// 系统概况，供 `shui` 启动横幅与 `shui-ctl status` 使用。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemInfo {
    pub hostname: String,
    pub os_name: String,
    pub os_version: String,
    pub kernel: String,
    pub arch: String,
    pub uptime_secs: u64,
    pub load1: f64,
    pub mem_total_bytes: u64,
    pub mem_available_bytes: u64,
    pub agents_running: usize,
    pub agents_total: usize,
    /// cgroup v2 是否可用。
    pub cgroup_v2: bool,
    /// 根文件系统是否为只读（不可变根）。
    pub immutable_root: bool,
}

/// 本地模型条目。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    /// 文件名（含扩展名）。
    pub name: String,
    /// 绝对路径。
    pub path: String,
    pub size_bytes: u64,
}

/// MCP 工具描述（v0.1 为 `shuiosd` 内置工具）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolInfo {
    /// 形如 `fs.read`。
    pub name: String,
    pub description: String,
    /// 参数 JSON Schema（简化版）。
    #[serde(default)]
    pub schema: serde_json::Value,
}

/// `mcp.call` 的返回：文本内容作为模型可读结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolResult {
    pub ok: bool,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_error: Option<bool>,
}

impl ToolResult {
    /// 成功结果。
    pub fn text(s: impl Into<String>) -> Self {
        Self { ok: true, content: s.into(), is_error: None }
    }

    /// 失败结果。
    pub fn fail(s: impl Into<String>) -> Self {
        Self { ok: false, content: s.into(), is_error: Some(true) }
    }
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

#[cfg(unix)]
pub mod client {
    //! 面向 shuiosd 的同步 JSON Lines 客户端。

    use super::{Request, Response};
    use serde::de::DeserializeOwned;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::time::Duration;

    /// 已连接的控制平面客户端。
    pub struct Client {
        reader: BufReader<UnixStream>,
        writer: UnixStream,
        next_id: u64,
    }

    impl Client {
        /// 连接默认套接字。
        pub fn connect_default() -> std::io::Result<Self> {
            Self::connect(super::DEFAULT_SOCKET)
        }

        /// 连接指定套接字。
        pub fn connect(path: &str) -> std::io::Result<Self> {
            let stream = UnixStream::connect(path)?;
            stream.set_read_timeout(Some(Duration::from_secs(30)))?;
            stream.set_write_timeout(Some(Duration::from_secs(30)))?;
            let writer = stream.try_clone()?;
            Ok(Self { reader: BufReader::new(stream), writer, next_id: 1 })
        }

        /// 调整读超时；长耗时 RPC（如 `ai.chat`）在调用前显式放宽。
        pub fn set_read_timeout(&mut self, timeout: Duration) -> std::io::Result<()> {
            self.reader.get_ref().set_read_timeout(Some(timeout))
        }

        /// 发送请求并读取响应。
        pub fn call_raw(
            &mut self,
            method: &str,
            params: serde_json::Value,
        ) -> std::io::Result<Response> {
            let id = format!("c{}", self.next_id);
            self.next_id += 1;
            let mut req = Request::new(method, params);
            req.id = Some(id.clone());

            let mut line = serde_json::to_string(&req)?;
            line.push('\n');
            self.writer.write_all(line.as_bytes())?;
            self.writer.flush()?;

            let mut buf = String::new();
            let n = self.reader.read_line(&mut buf)?;
            if n == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "shuiosd 关闭了连接",
                ));
            }
            let mut resp: Response = serde_json::from_str(buf.trim_end())?;
            resp.id = Some(id);
            Ok(resp)
        }

        /// 把结果反序列化成具体类型；`error` 会转成 io::Error。
        pub fn call<T: DeserializeOwned>(
            &mut self,
            method: &str,
            params: serde_json::Value,
        ) -> std::io::Result<T> {
            let resp = self.call_raw(method, params)?;
            if let Some(e) = resp.error {
                return Err(std::io::Error::other(format!("[{}] {}", e.code, e.message)));
            }
            let value = resp.result.unwrap_or(serde_json::Value::Null);
            serde_json::from_value(value)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))
        }
    }
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_size_understands_units() {
        assert_eq!(parse_size("1024"), Some(1024));
        assert_eq!(parse_size("1K"), Some(1024));
        assert_eq!(parse_size("512M"), Some(512 * 1024 * 1024));
        assert_eq!(parse_size("2G"), Some(2 * 1024 * 1024 * 1024));
        assert_eq!(parse_size("1T"), Some(1024u64 * 1024 * 1024 * 1024));
        assert_eq!(parse_size(" 256 m "), Some(256 * 1024 * 1024));
    }

    #[test]
    fn parse_size_rejects_nonsense() {
        assert_eq!(parse_size("max"), None);
        assert_eq!(parse_size(""), None);
        assert_eq!(parse_size("abc"), None);
    }

    #[test]
    fn limits_expose_memory_bytes() {
        let l = Limits { memory_max: Some("3G".into()), ..Default::default() };
        assert_eq!(l.memory_max_bytes(), Some(3 * 1024 * 1024 * 1024));

        let l = Limits { memory_max: Some("max".into()), ..Default::default() };
        assert_eq!(l.memory_max_bytes(), None);

        let l = Limits { memory_max: None, ..Default::default() };
        assert_eq!(l.memory_max_bytes(), None);
    }

    #[test]
    fn default_limits_are_sane() {
        let l = Limits::default();
        assert_eq!(l.memory_max.as_deref(), Some("2G"));
        assert_eq!(l.pids_max, Some(512));
        assert_eq!(l.memory_max_bytes(), Some(2 * 1024 * 1024 * 1024));
    }

    #[test]
    fn request_envelope_omits_null_id() {
        let req = Request::new("agent.list", serde_json::json!({}));
        let s = serde_json::to_string(&req).unwrap();
        assert!(s.contains("\"method\":\"agent.list\""));
        assert!(!s.contains("\"id\""), "id 为 None 时不应出现在 JSON 里: {s}");

        let back: Request = serde_json::from_str(&s).unwrap();
        assert_eq!(back.method, "agent.list");
        assert!(back.id.is_none());
    }

    #[test]
    fn response_success_and_error_are_exclusive() {
        let ok = Response::ok(serde_json::json!({"a": 1}));
        let s = serde_json::to_string(&ok).unwrap();
        assert!(s.contains("\"result\""));
        assert!(!s.contains("\"error\""));
        assert!(ok.is_ok());

        let err = Response::err(errcode::NO_SUCH_AGENT, "智能体不存在");
        let s = serde_json::to_string(&err).unwrap();
        assert!(s.contains("\"code\":-32001"), "got {s}");
        assert!(!s.contains("\"result\""));
        assert!(!err.is_ok());
    }

    #[test]
    fn agent_state_uses_snake_case() {
        assert_eq!(serde_json::to_string(&AgentState::Running).unwrap(), "\"running\"");
        assert_eq!(serde_json::to_string(&AgentState::Exited).unwrap(), "\"exited\"");
        assert!(AgentState::Running.is_live());
        assert!(AgentState::Starting.is_live());
        assert!(!AgentState::Exited.is_live());
        assert!(!AgentState::Failed.is_live());
    }

    #[test]
    fn capability_uses_snake_case() {
        assert_eq!(serde_json::to_string(&Capability::FsRead).unwrap(), "\"fs_read\"");
        assert_eq!(serde_json::to_string(&Capability::Net).unwrap(), "\"net\"");
    }

    #[test]
    fn agent_spec_has_lenient_defaults() {
        let spec: AgentSpec =
            serde_json::from_str(r#"{"name":"x","argv":["/bin/true"]}"#).unwrap();
        assert_eq!(spec.name, "x");
        assert_eq!(spec.argv, vec!["/bin/true".to_string()]);
        assert!(spec.env.is_empty());
        assert!(spec.capabilities.is_empty());
        assert!(!spec.restart);
        assert!(spec.workdir.is_none());
        // limits 缺省时用 Limits::default
        assert_eq!(spec.limits.memory_max.as_deref(), Some("2G"));
    }

    #[test]
    fn tool_result_shape_is_stable() {
        let r = ToolResult::fail("boom");
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["ok"], serde_json::json!(false));
        assert_eq!(v["is_error"], serde_json::json!(true));
        assert_eq!(v["content"], serde_json::json!("boom"));

        let r = ToolResult::text("hello");
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["ok"], serde_json::json!(true));
        assert!(v.get("is_error").is_none(), "成功结果不应带 is_error 字段");
    }

    #[test]
    fn protocol_constants_are_stable() {
        assert_eq!(PROTOCOL_VERSION, 1);
        assert!(DEFAULT_SOCKET.ends_with("shuiosd.sock"));
        assert!(MODEL_DIR.starts_with("/var/lib/shuios"));
    }
}
