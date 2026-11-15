//! MCP（Model Context Protocol）系统级总线。
//!
//! shuios 把 MCP 从"某个 AI 应用内部的插件协议"提升为**操作系统级的 IPC**：
//! `shuiosd` 在 `/run/shuios/mcp/system.sock` 上提供符合 MCP 的 JSON-RPC 2.0 服务，
//! 任何智能体（本机的、SSH 进来的、甚至其他机器通过代理的）都能用同一套协议
//! 发现并调用这台机器的能力。
//!
//! 与 `shuiosd.sock`（我们自己的控制平面）的区别：
//!
//! | | 控制平面 `/run/shuios/shuiosd.sock` | MCP 总线 `/run/shuios/mcp/system.sock` |
//! | --- | --- | --- |
//! | 面向 | `shui` / `shui-ctl`（受信任的本地工具） | 任意 MCP 客户端（模型/智能体） |
//! | 协议 | 我们的 JSON Lines 信封 | 标准 JSON-RPC 2.0 + MCP 方法 |
//! | 能力 | 完整（派生子智能体、读日志…） | 受限：只暴露工具发现与调用 |
//!
//! 这种分层是刻意的：模型能用什么，由总线决定，而不是由提示词决定。

use serde::{Deserialize, Serialize};

/// 当前实现的 MCP 协议版本。
pub const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

/// 系统总线的默认套接字路径。
pub const SYSTEM_MCP_SOCKET: &str = "/run/shuios/mcp/system.sock";

/// JSON-RPC 2.0 版本字符串。
pub const JSONRPC_VERSION: &str = "2.0";

/// 一条入站 MCP 消息。请求带 `id`，通知不带。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpRequest {
    pub jsonrpc: String,
    /// 请求 id；为 `None` 时表示这是一条通知（不应回复）。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<serde_json::Value>,
    pub method: String,
    #[serde(default)]
    pub params: serde_json::Value,
}

impl McpRequest {
    /// 是否为通知（没有 id）。
    pub fn is_notification(&self) -> bool {
        self.id.is_none()
    }

    /// 从一行 JSON 解析。
    pub fn parse(line: &str) -> Result<Self, String> {
        let v: serde_json::Value =
            serde_json::from_str(line).map_err(|e| format!("不是合法 JSON: {e}"))?;
        let jsonrpc = v
            .get("jsonrpc")
            .and_then(|x| x.as_str())
            .ok_or_else(|| "缺少 jsonrpc 字段".to_string())?;
        if jsonrpc != JSONRPC_VERSION {
            return Err(format!("不支持的 jsonrpc 版本: {jsonrpc}"));
        }
        let method = v
            .get("method")
            .and_then(|x| x.as_str())
            .ok_or_else(|| "缺少 method 字段".to_string())?
            .to_string();
        Ok(Self {
            jsonrpc: jsonrpc.to_string(),
            id: v.get("id").cloned(),
            method,
            params: v.get("params").cloned().unwrap_or(serde_json::Value::Null),
        })
    }
}

/// 一条出站 MCP 响应。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpResponse {
    pub jsonrpc: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<McpError>,
}

impl McpResponse {
    /// 成功响应。
    pub fn ok(id: Option<serde_json::Value>, result: serde_json::Value) -> Self {
        Self { jsonrpc: JSONRPC_VERSION.to_string(), id, result: Some(result), error: None }
    }

    /// 错误响应。
    pub fn err(id: Option<serde_json::Value>, code: i64, message: impl Into<String>) -> Self {
        Self {
            jsonrpc: JSONRPC_VERSION.to_string(),
            id,
            result: None,
            error: Some(McpError { code, message: message.into(), data: None }),
        }
    }
}

/// JSON-RPC 错误对象。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpError {
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<serde_json::Value>,
}

/// JSON-RPC 2.0 标准错误码。
pub mod mcp_errcode {
    pub const PARSE_ERROR: i64 = -32700;
    pub const INVALID_REQUEST: i64 = -32600;
    pub const METHOD_NOT_FOUND: i64 = -32601;
    pub const INVALID_PARAMS: i64 = -32602;
    pub const INTERNAL_ERROR: i64 = -32603;
}

/// `initialize` 的结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InitializeResult {
    #[serde(rename = "protocolVersion")]
    pub protocol_version: String,
    pub capabilities: serde_json::Value,
    #[serde(rename = "serverInfo")]
    pub server_info: ServerInfo,
}

/// 服务端自述信息。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
}

/// `tools/list` 里的一个工具。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpTool {
    pub name: String,
    pub description: String,
    #[serde(rename = "inputSchema")]
    pub input_schema: serde_json::Value,
}

/// `tools/call` 返回的内容块。目前只支持文本。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpTextContent {
    /// 固定为 `"text"`。
    #[serde(rename = "type")]
    pub kind: String,
    pub text: String,
}

/// `tools/call` 的结果。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpCallToolResult {
    pub content: Vec<McpTextContent>,
    #[serde(rename = "isError", default)]
    pub is_error: bool,
}

impl McpCallToolResult {
    /// 成功文本结果。
    pub fn text(s: impl Into<String>) -> Self {
        Self {
            content: vec![McpTextContent { kind: "text".to_string(), text: s.into() }],
            is_error: false,
        }
    }

    /// 失败结果（注意：MCP 约定"工具执行失败"是正常响应 + isError=true，
    /// 只有协议层错误才走 JSON-RPC error）。
    pub fn fail(s: impl Into<String>) -> Self {
        Self {
            content: vec![McpTextContent { kind: "text".to_string(), text: s.into() }],
            is_error: true,
        }
    }
}

/// 总线上的服务描述（用于 `shui-ctl mcp` 展示）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct McpServerInfo {
    pub name: String,
    pub socket: String,
    pub protocol_version: String,
    pub tool_count: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_request_with_id() {
        let line = r#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#;
        let req = McpRequest::parse(line).unwrap();
        assert_eq!(req.method, "tools/list");
        assert!(!req.is_notification());
        assert_eq!(req.id, Some(serde_json::json!(1)));
    }

    #[test]
    fn parses_notification_without_id() {
        let line = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
        let req = McpRequest::parse(line).unwrap();
        assert!(req.is_notification());
        assert_eq!(req.method, "notifications/initialized");
    }

    #[test]
    fn rejects_bad_envelope() {
        assert!(McpRequest::parse("not json").is_err());
        assert!(McpRequest::parse(r#"{"id":1,"method":"x"}"#).is_err(), "缺 jsonrpc");
        assert!(
            McpRequest::parse(r#"{"jsonrpc":"1.0","method":"x"}"#).is_err(),
            "版本不对"
        );
        assert!(
            McpRequest::parse(r#"{"jsonrpc":"2.0","id":1}"#).is_err(),
            "缺 method"
        );
    }

    #[test]
    fn response_omits_empty_fields() {
        let r = McpResponse::ok(Some(serde_json::json!(7)), serde_json::json!({"a": 1}));
        let s = serde_json::to_string(&r).unwrap();
        assert!(s.contains("\"result\""));
        assert!(!s.contains("\"error\""));
        assert!(s.contains("\"id\":7"));

        let e = McpResponse::err(Some(serde_json::json!(8)), mcp_errcode::METHOD_NOT_FOUND, "nope");
        let s = serde_json::to_string(&e).unwrap();
        assert!(s.contains("-32601"));
        assert!(!s.contains("\"result\""));
    }

    #[test]
    fn tool_call_result_uses_is_error_camelcase() {
        let ok = McpCallToolResult::text("hello");
        let v = serde_json::to_value(&ok).unwrap();
        assert_eq!(v["content"][0]["type"], serde_json::json!("text"));
        assert_eq!(v["content"][0]["text"], serde_json::json!("hello"));
        assert_eq!(v["isError"], serde_json::json!(false));

        let bad = McpCallToolResult::fail("boom");
        let v = serde_json::to_value(&bad).unwrap();
        assert_eq!(v["isError"], serde_json::json!(true));
    }

    #[test]
    fn tool_descriptor_uses_input_schema_camelcase() {
        let t = McpTool {
            name: "fs.list".into(),
            description: "列出目录".into(),
            input_schema: serde_json::json!({"type": "object"}),
        };
        let v = serde_json::to_value(&t).unwrap();
        assert!(v.get("inputSchema").is_some(), "MCP 要求 camelCase 的 inputSchema");
    }

    #[test]
    fn initialize_result_shape() {
        let r = InitializeResult {
            protocol_version: MCP_PROTOCOL_VERSION.to_string(),
            capabilities: serde_json::json!({"tools": {}}),
            server_info: ServerInfo { name: "shuiosd".into(), version: "0.1.0".into() },
        };
        let v = serde_json::to_value(&r).unwrap();
        assert_eq!(v["protocolVersion"], serde_json::json!(MCP_PROTOCOL_VERSION));
        assert_eq!(v["serverInfo"]["name"], serde_json::json!("shuiosd"));
    }
}
