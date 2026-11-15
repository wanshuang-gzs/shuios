//! sway IPC 客户端（够用就好）。
//!
//! 协议：unix socket 上 6 字节魔数 `i3-ipc` + u32 长度 + u32 类型 + JSON 负载，
//! 全部**本机字节序**。事件消息的类型 = 0x8000_0000 | 原类型。
//!
//! 为什么自己写而不是加 crate：需求只有"读窗口树 + 订阅窗口事件"两条，
//! 协议不到 100 行；镜像里的依赖表越短越好。

use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

const MAGIC: &[u8; 6] = b"i3-ipc";
const MSG_SUBSCRIBE: u32 = 2;
const MSG_GET_TREE: u32 = 4;
/// 窗口事件（0x8000_0000 | 3）
pub const EVENT_WINDOW: u32 = 0x8000_0003;

/// 一个「窗口」（任务栏按钮要的信息）。
#[derive(Debug, Clone, PartialEq)]
pub struct WinInfo {
    pub app_id: String,
    pub title: String,
    pub focused: bool,
    pub con_id: u64,
    pub workspace: String,
}

/// 找到 sway 的 IPC socket。优先环境变量 `SWAYSOCK`，否则扫运行目录。
pub fn socket_path() -> Result<PathBuf, String> {
    if let Ok(p) = std::env::var("SWAYSOCK") {
        if !p.trim().is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    for dir in ["/run/shuios/compositor", "/run/user/0", "/tmp"] {
        let Ok(rd) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in rd.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("sway-ipc.") && name.ends_with(".sock") {
                return Ok(entry.path());
            }
        }
    }
    Err("找不到 sway IPC socket（SWAYSOCK 未设置，且运行目录里没有 sway-ipc.*.sock）".into())
}

fn connect() -> Result<UnixStream, String> {
    let path = socket_path()?;
    UnixStream::connect(&path)
        .map_err(|e| format!("连接 sway IPC {} 失败：{e}", path.display()))
}

fn send(stream: &mut UnixStream, mtype: u32, payload: &str) -> Result<(), String> {
    stream
        .write_all(MAGIC)
        .and_then(|_| stream.write_all(&(payload.len() as u32).to_ne_bytes()))
        .and_then(|_| stream.write_all(&mtype.to_ne_bytes()))
        .and_then(|_| stream.write_all(payload.as_bytes()))
        .and_then(|_| stream.flush())
        .map_err(|e| format!("写入 sway IPC 失败：{e}"))
}

fn recv(stream: &mut UnixStream) -> Result<(u32, Vec<u8>), String> {
    let mut head = [0u8; 14];
    stream
        .read_exact(&mut head)
        .map_err(|e| format!("读取 sway IPC 失败：{e}"))?;
    if &head[..6] != MAGIC {
        return Err("sway IPC 魔数不对（协议版本不匹配？）".into());
    }
    let len = u32::from_ne_bytes([head[6], head[7], head[8], head[9]]) as usize;
    let mtype = u32::from_ne_bytes([head[10], head[11], head[12], head[13]]);
    if len > 32 * 1024 * 1024 {
        return Err(format!("sway IPC 负载过大：{len} 字节"));
    }
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .map_err(|e| format!("读取 sway IPC 负载失败：{e}"))?;
    Ok((mtype, body))
}

/// 取整棵窗口树。
pub fn get_tree() -> Result<Value, String> {
    let mut s = connect()?;
    send(&mut s, MSG_GET_TREE, "")?;
    let (_, body) = recv(&mut s)?;
    serde_json::from_slice(&body).map_err(|e| format!("窗口树不是合法 JSON：{e}"))
}

/// 订阅窗口事件，返回一个可以持续 `recv_event` 的连接。
pub fn subscribe_windows() -> Result<UnixStream, String> {
    let mut s = connect()?;
    send(&mut s, MSG_SUBSCRIBE, r#"["window"]"#)?;
    let (_, body) = recv(&mut s)?; // 订阅成功回 {"success":true}
    let _ = body;
    Ok(s)
}

/// 读一条事件，返回 (change, 窗口信息)；不是窗口事件返回 None。
pub fn recv_event(stream: &mut UnixStream) -> Result<Option<(String, Option<WinInfo>)>, String> {
    let (mtype, body) = recv(stream)?;
    if mtype != EVENT_WINDOW {
        return Ok(None);
    }
    let v: Value = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
    let change = v
        .get("change")
        .and_then(|c| c.as_str())
        .unwrap_or("unknown")
        .to_string();
    let win = v.get("container").map(win_of).filter(|w| !w.app_id.is_empty());
    Ok(Some((change, win)))
}

/// 递归收集树里所有应用窗口。
pub fn collect_windows(tree: &Value) -> Vec<WinInfo> {
    let mut out = Vec::new();
    walk(tree, &mut out, "");
    out
}

fn walk(node: &Value, out: &mut Vec<WinInfo>, workspace: &str) {
    // 工作区节点：记住名字，传给子节点
    let node_type = node.get("type").and_then(|t| t.as_str()).unwrap_or("");
    let ws = if node_type == "workspace" {
        node.get("name").and_then(|n| n.as_str()).unwrap_or(workspace)
    } else {
        workspace
    };

    if node_type == "con" || node_type == "floating_con" {
        let w = win_of(node);
        if !w.app_id.is_empty() {
            out.push(WinInfo {
                workspace: ws.to_string(),
                ..w
            });
        }
    }

    for key in ["nodes", "floating_nodes"] {
        if let Some(arr) = node.get(key).and_then(|v| v.as_array()) {
            for child in arr {
                walk(child, out, ws);
            }
        }
    }
}

/// 单个节点 → 窗口信息。app_id 优先，取不到就退化成 class。
fn win_of(node: &Value) -> WinInfo {
    let app_id = node
        .get("app_id")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .or_else(|| {
            node.get("window_properties")
                .and_then(|p| p.get("class"))
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        })
        .unwrap_or_default();
    WinInfo {
        app_id,
        title: node
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        focused: node.get("focused").and_then(|v| v.as_bool()).unwrap_or(false),
        con_id: node.get("id").and_then(|v| v.as_u64()).unwrap_or(0),
        workspace: String::new(),
    }
}

/// 输出一行 TSV：`app_id \t title \t focused \t con_id \t workspace`
/// （标题里的制表符会换成空格，避免把列冲乱）
pub fn to_tsv(w: &WinInfo) -> String {
    format!(
        "{}\t{}\t{}\t{}\t{}",
        w.app_id,
        w.title.replace('\t', " ").replace('\n', " "),
        if w.focused { 1 } else { 0 },
        w.con_id,
        w.workspace
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 解析窗口树() {
        let tree = serde_json::json!({
            "type": "root",
            "nodes": [{
                "type": "output",
                "nodes": [{
                    "type": "workspace",
                    "name": "1",
                    "nodes": [{
                        "type": "con",
                        "app_id": "foot",
                        "name": "shui 氵",
                        "focused": true,
                        "id": 401,
                        "nodes": []
                    }],
                    "floating_nodes": [{
                        "type": "floating_con",
                        "app_id": "shui-panel",
                        "name": "shui-panel",
                        "focused": false,
                        "id": 402
                    }]
                }]
            }]
        });
        let wins = collect_windows(&tree);
        assert_eq!(wins.len(), 2, "应当收集到两个窗口：{wins:?}");
        assert_eq!(wins[0].app_id, "foot");
        assert_eq!(wins[0].title, "shui 氵");
        assert!(wins[0].focused);
        assert_eq!(wins[0].con_id, 401);
        assert_eq!(wins[0].workspace, "1");
        assert_eq!(wins[1].app_id, "shui-panel");
    }

    #[test]
    fn 没有_app_id_的节点被忽略() {
        let tree = serde_json::json!({
            "type":"root",
            "nodes":[{"type":"con","name":"无 app_id","id":1}]
        });
        assert!(collect_windows(&tree).is_empty());
    }

    #[test]
    fn tsv_把标题里的制表符压掉() {
        let w = WinInfo {
            app_id: "foot".into(),
            title: "a\tb\nc".into(),
            focused: true,
            con_id: 7,
            workspace: "2".into(),
        };
        assert_eq!(to_tsv(&w), "foot\ta b c\t1\t7\t2");
    }

    #[test]
    fn 没有_swaysock_时返回错误() {
        // 清掉环境变量后，找不到 socket 应当返回 Err
        let old = std::env::var("SWAYSOCK").ok();
        std::env::remove_var("SWAYSOCK");
        let r = socket_path();
        if let Some(v) = old {
            std::env::set_var("SWAYSOCK", v);
        }
        // 测试机（Windows/WSL）上通常没有 sway socket
        assert!(r.is_err(), "没有 socket 却返回了 {:?}", r.ok());
    }
}
