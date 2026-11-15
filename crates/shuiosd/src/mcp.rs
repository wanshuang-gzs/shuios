//! MCP 系统总线服务端。
//!
//! 在 `/run/shuios/mcp/system.sock` 上提供标准 MCP（JSON-RPC 2.0）。
//! 支持的方法：`initialize`、`ping`、`tools/list`、`tools/call`、
//! 以及 `notifications/initialized` 这类通知（收到即丢，不回包）。
//!
//! 设计取舍：这里**只暴露工具发现与调用**，不暴露控制平面的全部能力
//! （派生/击杀智能体、读日志、改配置都不在 MCP 上）。模型能用什么由系统决定，
//! 不由提示词决定——这是 shuios 的安全边界。

use crate::state::App;
use crate::tools;
use shuios_proto::mcp::{
    mcp_errcode, InitializeResult, McpCallToolResult, McpRequest, McpResponse, McpServerInfo,
    McpTool, ServerInfo, JSONRPC_VERSION, MCP_PROTOCOL_VERSION, SYSTEM_MCP_SOCKET,
};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::thread;

/// 总线对外自述的服务信息。
pub fn server_info() -> McpServerInfo {
    McpServerInfo {
        name: "system".to_string(),
        socket: SYSTEM_MCP_SOCKET.to_string(),
        protocol_version: MCP_PROTOCOL_VERSION.to_string(),
        tool_count: tools::list().len(),
    }
}

/// `initialize` 的返回。
fn initialize_result() -> InitializeResult {
    InitializeResult {
        protocol_version: MCP_PROTOCOL_VERSION.to_string(),
        capabilities: serde_json::json!({ "tools": { "listChanged": false } }),
        server_info: ServerInfo {
            name: "shuiosd".to_string(),
            version: shuios_proto::SHUIOS_VERSION.to_string(),
        },
    }
}

/// 把内部工具描述转换成 MCP 的 `tools/list` 形状。
fn tool_list() -> Vec<McpTool> {
    tools::list()
        .into_iter()
        .map(|t| McpTool {
            name: t.name,
            description: t.description,
            input_schema: t.schema,
        })
        .collect()
}

/// 处理一条 MCP 消息；通知返回 `None`（不回包）。
pub fn dispatch(app: &Arc<App>, req: &McpRequest) -> Option<McpResponse> {
    if req.is_notification() {
        // notifications/initialized、notifications/cancelled 等：无需回复。
        return None;
    }
    let id = req.id.clone();

    let resp = match req.method.as_str() {
        "initialize" => McpResponse::ok(
            id,
            serde_json::to_value(initialize_result()).unwrap_or(serde_json::Value::Null),
        ),
        "ping" => McpResponse::ok(id, serde_json::json!({})),
        "tools/list" => McpResponse::ok(id, serde_json::json!({ "tools": tool_list() })),
        "tools/call" => {
            #[derive(serde::Deserialize)]
            struct Params {
                name: String,
                #[serde(default)]
                arguments: serde_json::Value,
            }
            let v = if req.params.is_null() {
                serde_json::json!({})
            } else {
                req.params.clone()
            };
            match serde_json::from_value::<Params>(v) {
                Ok(p) => {
                    if !app.cfg.mcp_tools {
                        let r = McpCallToolResult::fail("内置 MCP 工具已禁用（mcp_tools=false）");
                        McpResponse::ok(id, serde_json::to_value(r).unwrap_or_default())
                    } else {
                        let r = tools::call(app, &p.name, &p.arguments);
                        // 工具执行失败在 MCP 里是正常响应 + isError=true，
                        // 只有协议层问题才用 JSON-RPC error。
                        let out = if r.ok {
                            McpCallToolResult::text(r.content)
                        } else {
                            McpCallToolResult::fail(r.content)
                        };
                        McpResponse::ok(id, serde_json::to_value(out).unwrap_or_default())
                    }
                }
                Err(e) => McpResponse::err(id, mcp_errcode::INVALID_PARAMS, e.to_string()),
            }
        }
        other => McpResponse::err(id, mcp_errcode::METHOD_NOT_FOUND, format!("未知方法 {other}")),
    };
    Some(resp)
}

/// 启动 MCP 总线（阻塞）。
pub fn serve(app: &Arc<App>) -> std::io::Result<()> {
    let path = SYSTEM_MCP_SOCKET;
    if let Some(parent) = Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if Path::new(path).exists() {
        let _ = std::fs::remove_file(path);
    }
    let listener = UnixListener::bind(path)?;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660));
    app.log(format!(
        "MCP 总线监听 {path}（{} 个工具，协议 {}）",
        tools::list().len(),
        MCP_PROTOCOL_VERSION
    ));

    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                let app = app.clone();
                thread::spawn(move || {
                    if let Err(e) = handle_conn(app, stream) {
                        eprintln!("MCP 连接结束: {e}");
                    }
                });
            }
            Err(e) => app.log(format!("MCP 接受连接失败: {e}")),
        }
    }
    Ok(())
}

fn handle_conn(app: Arc<App>, stream: UnixStream) -> std::io::Result<()> {
    let mut writer = stream.try_clone()?;
    let reader = BufReader::new(stream);
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                if e.kind() == std::io::ErrorKind::ConnectionReset {
                    return Ok(());
                }
                return Err(e);
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let req = match McpRequest::parse(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = McpResponse::err(None, mcp_errcode::PARSE_ERROR, e);
                write_resp(&mut writer, &resp)?;
                continue;
            }
        };
        if let Some(resp) = dispatch(&app, &req) {
            write_resp(&mut writer, &resp)?;
        }
    }
    Ok(())
}

fn write_resp(w: &mut UnixStream, resp: &McpResponse) -> std::io::Result<()> {
    let mut s = serde_json::to_string(resp)?;
    s.push('\n');
    w.write_all(s.as_bytes())?;
    w.flush()
}

/// 校验版本字符串常量，避免被误改（编译期即可发现）。
const _: () = {
    assert!(JSONRPC_VERSION.len() == 3);
};
