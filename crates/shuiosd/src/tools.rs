//! 内置 MCP 工具集。
//!
//! shuios 的立意是「模型能看见、能操作这台机器」。这些工具由 `shuiosd`
//! 直接提供，通过 `mcp.call` 调用，天然继承守护进程的权限与审计。
//! 写入类工具只允许落在白名单目录内——根文件系统本来也是只读的。

use crate::state::App;
use crate::supervisor;
use crate::sysinfo;
use shuios_proto::{AgentSpec, ModelInfo, ToolInfo, ToolResult};
use std::sync::Arc;

/// 允许智能体写入的路径前缀。
const WRITE_ALLOW: [&str; 5] = ["/tmp/", "/workspace/", "/var/lib/shuios/", "/var/tmp/", "/run/shuios/"];

/// 列出全部内置工具。
pub fn list() -> Vec<ToolInfo> {
    vec![
        ToolInfo {
            name: "sys.info".into(),
            description: "读取系统概况：主机名、内核、内存、负载、智能体数量、cgroup 与只读根状态".into(),
            schema: obj(&[], None),
        },
        ToolInfo {
            name: "fs.list".into(),
            description: "列出目录内容（名称/类型/大小）".into(),
            schema: obj(&["path"], Some("path")),
        },
        ToolInfo {
            name: "fs.read".into(),
            description: "读取文本文件内容".into(),
            schema: obj(&["path", "max_bytes"], Some("path")),
        },
        ToolInfo {
            name: "fs.write".into(),
            description: "写入文本文件（仅限 /tmp、/workspace、/var/lib/shuios 等白名单目录）".into(),
            schema: obj(&["path", "content"], Some("path")),
        },
        ToolInfo {
            name: "proc.list".into(),
            description: "列出当前进程（pid/cmdline）".into(),
            schema: obj(&[], None),
        },
        ToolInfo {
            name: "agent.list".into(),
            description: "列出由 shuiosd 托管的智能体及其资源用量".into(),
            schema: obj(&[], None),
        },
        ToolInfo {
            name: "agent.spawn".into(),
            description: "派生一个新的智能体进程（受 cgroup 限额）".into(),
            schema: obj(&["name", "command"], Some("name")),
        },
        ToolInfo {
            name: "agent.kill".into(),
            description: "终止指定智能体（整组击杀）".into(),
            schema: obj(&["name"], Some("name")),
        },
        ToolInfo {
            name: "model.list".into(),
            description: "列出本地模型仓库中的模型文件".into(),
            schema: obj(&[], None),
        },
        ToolInfo {
            name: "pkg.list".into(),
            description: "列出软件仓库里可安装的软件包（名字、版本、体积、摘要）".into(),
            schema: obj(&["query"], None),
        },
        ToolInfo {
            name: "pkg.install".into(),
            description: "从软件仓库安装一个软件包（自动解析依赖；会真的往数据分区写文件）".into(),
            schema: obj(&["name"], Some("name")),
        },
        ToolInfo {
            name: "pkg.remove".into(),
            description: "卸载一个已安装的软件包（卸载挂载、删除软链与包文件）".into(),
            schema: obj(&["name"], Some("name")),
        },
        ToolInfo {
            name: "pkg.installed".into(),
            description: "列出已经安装的软件包及其挂载点".into(),
            schema: obj(&[], None),
        },
        ToolInfo {
            name: "web.fetch".into(),
            description: "抓取一个网址并返回正文（去掉 HTML 标签后的纯文本，最长 2 万字符）".into(),
            schema: obj(&["url"], Some("url")),
        },
    ]
}

fn obj(keys: &[&str], required: Option<&str>) -> serde_json::Value {
    let mut props = serde_json::Map::new();
    for k in keys {
        props.insert(
            (*k).to_string(),
            serde_json::json!({ "type": if *k == "max_bytes" { "integer" } else { "string" } }),
        );
    }
    let mut schema = serde_json::Map::new();
    schema.insert("type".into(), serde_json::json!("object"));
    schema.insert("properties".into(), serde_json::Value::Object(props));
    if let Some(r) = required {
        schema.insert("required".into(), serde_json::json!([r]));
    }
    serde_json::Value::Object(schema)
}

/// 调用一个内置工具。
pub fn call(app: &Arc<App>, tool: &str, args: &serde_json::Value) -> ToolResult {
    let arg_str = |k: &str| -> Option<String> {
        args.get(k).and_then(|v| v.as_str()).map(|s| s.to_string())
    };
    match tool {
        "sys.info" => {
            let (total, running) = app.count();
            let info = sysinfo::system_info(total, running);
            match serde_json::to_string_pretty(&info) {
                Ok(s) => ToolResult::text(s),
                Err(e) => ToolResult::fail(e.to_string()),
            }
        }
        "fs.list" => {
            let path = arg_str("path").unwrap_or_else(|| "/".to_string());
            match std::fs::read_dir(&path) {
                Ok(rd) => {
                    let mut out = String::new();
                    let mut entries: Vec<(String, bool, u64)> = Vec::new();
                    for e in rd.flatten() {
                        let meta = e.metadata().ok();
                        let is_dir = meta.as_ref().map(|m| m.is_dir()).unwrap_or(false);
                        let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
                        entries.push((e.file_name().to_string_lossy().to_string(), is_dir, size));
                    }
                    entries.sort_by(|a, b| (b.1, a.0.clone()).cmp(&(a.1, b.0.clone())));
                    for (name, is_dir, size) in entries {
                        if is_dir {
                            out.push_str(&format!("{name}/\n"));
                        } else {
                            out.push_str(&format!("{name}\t{size}\n"));
                        }
                    }
                    ToolResult::text(out)
                }
                Err(e) => ToolResult::fail(format!("读取目录 {path} 失败: {e}")),
            }
        }
        "fs.read" => {
            let Some(path) = arg_str("path") else {
                return ToolResult::fail("缺少参数 path".to_string());
            };
            let max = args
                .get("max_bytes")
                .and_then(|v| v.as_u64())
                .unwrap_or(64 * 1024) as usize;
            match std::fs::read(&path) {
                Ok(bytes) => {
                    let truncated = bytes.len() > max;
                    let slice = &bytes[..bytes.len().min(max)];
                    let body = String::from_utf8_lossy(slice).to_string();
                    if truncated {
                        ToolResult::text(format!(
                            "{body}\n\n[已截断：文件 {} 字节，仅显示前 {max} 字节]",
                            bytes.len()
                        ))
                    } else {
                        ToolResult::text(body)
                    }
                }
                Err(e) => ToolResult::fail(format!("读取 {path} 失败: {e}")),
            }
        }
        "fs.write" => {
            let Some(path) = arg_str("path") else {
                return ToolResult::fail("缺少参数 path".to_string());
            };
            let content = arg_str("content").unwrap_or_default();
            if !WRITE_ALLOW.iter().any(|p| path.starts_with(p)) {
                return ToolResult::fail(format!(
                    "拒绝写入 {path}：只允许 {}",
                    WRITE_ALLOW.join(", ")
                ));
            }
            if let Some(parent) = std::path::Path::new(&path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            match std::fs::write(&path, content.as_bytes()) {
                Ok(()) => ToolResult::text(format!("已写入 {path}（{} 字节）", content.len())),
                Err(e) => ToolResult::fail(format!("写入 {path} 失败: {e}")),
            }
        }
        "proc.list" => match std::fs::read_dir("/proc") {
            Ok(rd) => {
                let mut rows = Vec::new();
                for e in rd.flatten() {
                    let name = e.file_name().to_string_lossy().to_string();
                    if !name.chars().all(|c| c.is_ascii_digit()) {
                        continue;
                    }
                    let cmd = std::fs::read(format!("/proc/{name}/cmdline"))
                        .map(|b| {
                            b.split(|c| *c == 0)
                                .map(|s| String::from_utf8_lossy(s).to_string())
                                .collect::<Vec<_>>()
                                .join(" ")
                                .trim()
                                .to_string()
                        })
                        .unwrap_or_default();
                    if !cmd.is_empty() {
                        rows.push(format!("{name}\t{cmd}"));
                    }
                }
                rows.sort();
                ToolResult::text(rows.join("\n"))
            }
            Err(e) => ToolResult::fail(format!("读取 /proc 失败: {e}")),
        },
        "agent.list" => {
            let infos: Vec<_> = app
                .snapshot()
                .iter()
                .map(|h| match h.lock() {
                    Ok(g) => g.info(),
                    Err(p) => p.into_inner().info(),
                })
                .collect();
            match serde_json::to_string_pretty(&infos) {
                Ok(s) => ToolResult::text(s),
                Err(e) => ToolResult::fail(e.to_string()),
            }
        }
        "agent.spawn" => {
            let Some(name) = arg_str("name") else {
                return ToolResult::fail("缺少参数 name".to_string());
            };
            let Some(command) = arg_str("command") else {
                return ToolResult::fail("缺少参数 command".to_string());
            };
            let argv: Vec<String> = command.split_whitespace().map(|s| s.to_string()).collect();
            let mut spec = AgentSpec::new(name, argv);
            spec.limits = app.cfg.default_limits.clone();
            match supervisor::spawn(app, spec) {
                Ok(info) => ToolResult::text(format!("已派生智能体 {}，pid={}", info.name, info.pid)),
                Err(e) => ToolResult::fail(e),
            }
        }
        "agent.kill" => {
            let Some(name) = arg_str("name") else {
                return ToolResult::fail("缺少参数 name".to_string());
            };
            match supervisor::kill(app, &name) {
                Ok(info) => ToolResult::text(format!("已终止 {} （exit={:?}）", info.name, info.exit_code)),
                Err(e) => ToolResult::fail(e),
            }
        }
        "model.list" => {
            let models = scan_models(&app.cfg.model_dir);
            match serde_json::to_string_pretty(&models) {
                Ok(s) => ToolResult::text(s),
                Err(e) => ToolResult::fail(e.to_string()),
            }
        }
        "pkg.list" => {
            let query = arg_str("query").unwrap_or_default();
            let repo = shui_pkg::resolve_repo();
            let raw = match shui_pkg::read_repo_file(&repo, "index.json") {
                Ok(b) => b,
                Err(e) => return ToolResult::fail(format!("读取仓库索引失败：{e}")),
            };
            let idx = match shui_pkg::Index::parse(&raw) {
                Ok(i) => i,
                Err(e) => return ToolResult::fail(e),
            };
            let installed = shui_pkg::Paths::default_state().load_installed();
            let mut out = String::new();
            for e in idx.packages.iter().filter(|e| e.matches(&query)) {
                let mark = if installed.get(&e.name).is_some() {
                    "[已装]"
                } else {
                    "[    ]"
                };
                out.push_str(&format!(
                    "{mark} {} {} ({}): {}\n",
                    e.name,
                    e.version,
                    e.size_human(),
                    e.summary
                ));
            }
            if out.is_empty() {
                out = format!("仓库里没有匹配 `{query}` 的包");
            }
            ToolResult::text(out)
        }
        "pkg.installed" => {
            let installed = shui_pkg::Paths::default_state().load_installed();
            if installed.packages.is_empty() {
                return ToolResult::text("还没有安装任何软件包".to_string());
            }
            let mut out = String::new();
            for p in &installed.packages {
                out.push_str(&format!("{} {} → {}\n", p.name, p.version, p.mount));
            }
            ToolResult::text(out)
        }
        // 装/卸走命令行：挂载与软链逻辑只在 shui-pkg 里实现一份，避免两处漂移。
        "pkg.install" | "pkg.remove" => {
            let Some(name) = arg_str("name") else {
                return ToolResult::fail("缺少参数 name".to_string());
            };
            // 包名只允许安全字符，防止被拼成别的命令行
            if !name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
            {
                return ToolResult::fail(format!("包名非法：{name}"));
            }
            let sub = if tool == "pkg.install" { "install" } else { "remove" };
            match std::process::Command::new("/usr/bin/shui-pkg")
                .arg(sub)
                .arg(&name)
                .output()
            {
                Ok(out) => {
                    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
                    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
                    if out.status.success() {
                        ToolResult::text(format!("{stdout}{stderr}"))
                    } else {
                        ToolResult::fail(format!("shui-pkg {sub} {name} 失败：\n{stdout}{stderr}"))
                    }
                }
                Err(e) => ToolResult::fail(format!("执行 shui-pkg 失败：{e}")),
            }
        }
        // 抓网页：用镜像里的 wget（它带 TLS，能抓 https），再把 HTML 抽成正文。
        // 不在 shuiosd 里塞 TLS 库，理由和 shui-pkg 一样：镜像要小。
        "web.fetch" => {
            let Some(url) = arg_str("url") else {
                return ToolResult::fail("缺少参数 url".to_string());
            };
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return ToolResult::fail(format!("只支持 http/https 网址：{url}"));
            }
            match std::process::Command::new("/usr/bin/wget")
                .args(["-q", "-O", "-", "-T", "20", "--max-redirect=5", &url])
                .output()
            {
                Ok(out) => {
                    if !out.status.success() {
                        let err = String::from_utf8_lossy(&out.stderr);
                        return ToolResult::fail(format!(
                            "抓取失败（wget {}）：{}",
                            out.status,
                            err.trim()
                        ));
                    }
                    let html = String::from_utf8_lossy(&out.stdout).to_string();
                    let text = crate::htmltext::html_to_text(&html);
                    if text.is_empty() {
                        return ToolResult::fail(format!("{url} 没有可读正文（空页或纯脚本页）"));
                    }
                    ToolResult::text(format!("{url}\n\n{text}"))
                }
                Err(e) => ToolResult::fail(format!("执行 wget 失败：{e}")),
            }
        }
        other => ToolResult::fail(format!("未知工具 {other}")),
    }
}

/// 扫描模型仓库目录，返回 `.gguf` / `.bin` / `.safetensors` 文件。
pub fn scan_models(dir: &str) -> Vec<ModelInfo> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(dir) else {
        return out;
    };
    for e in rd.flatten() {
        let path = e.path();
        if !path.is_file() {
            continue;
        }
        let name = e.file_name().to_string_lossy().to_string();
        let lower = name.to_ascii_lowercase();
        if !(lower.ends_with(".gguf") || lower.ends_with(".bin") || lower.ends_with(".safetensors")) {
            continue;
        }
        let size = e.metadata().map(|m| m.len()).unwrap_or(0);
        out.push(ModelInfo { name, path: path.display().to_string(), size_bytes: size });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}
