//! 控制平面：Unix 套接字上的 JSON Lines RPC 服务端。

use crate::state::App;
use crate::supervisor;
use crate::sysinfo;
use crate::tools;
use serde::de::DeserializeOwned;
use shuios_proto::ai::AI_PROVIDERS;
use shuios_proto::{errcode, AgentSpec, Limits, Request, Response};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

/// 启动控制平面，阻塞运行。
pub fn serve(app: &Arc<App>) -> std::io::Result<()> {
    let sock_path = app.cfg.socket.clone();
    let path = Path::new(&sock_path);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    let listener = UnixListener::bind(path)?;
    // 0660：root 与 wheel 组可访问。
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o660));
    app.log(format!("控制平面监听 {sock_path}"));

    for conn in listener.incoming() {
        match conn {
            Ok(stream) => {
                let app = app.clone();
                thread::spawn(move || {
                    if let Err(e) = handle_conn(app, stream) {
                        eprintln!("连接处理结束: {e}");
                    }
                });
            }
            Err(e) => app.log(format!("接受连接失败: {e}")),
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
                // 客户端断开是常态。
                if e.kind() == std::io::ErrorKind::ConnectionReset {
                    return Ok(());
                }
                return Err(e);
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                let resp = Response::err(errcode::BAD_REQUEST, format!("请求不是合法 JSON: {e}"));
                write_resp(&mut writer, &resp)?;
                continue;
            }
        };
        let id = req.id.clone();
        let mut resp = dispatch(&app, &req);
        resp.id = id;
        write_resp(&mut writer, &resp)?;
    }
    Ok(())
}

fn write_resp(w: &mut UnixStream, resp: &Response) -> std::io::Result<()> {
    let mut s = serde_json::to_string(resp)?;
    s.push('\n');
    w.write_all(s.as_bytes())?;
    w.flush()
}

fn parse<T: DeserializeOwned>(params: &serde_json::Value) -> Result<T, Response> {
    let v = if params.is_null() { serde_json::json!({}) } else { params.clone() };
    serde_json::from_value::<T>(v).map_err(|e| Response::err(errcode::BAD_PARAMS, format!("参数错误: {e}")))
}

fn dispatch(app: &Arc<App>, req: &Request) -> Response {
    match req.method.as_str() {
        "ping" => Response::ok(serde_json::json!({
            "pong": true,
            "version": shuios_proto::SHUIOS_VERSION,
            "protocol": shuios_proto::PROTOCOL_VERSION,
        })),
        "version" => Response::ok(serde_json::json!({
            "name": "shuiosd",
            "version": shuios_proto::SHUIOS_VERSION,
            "protocol": shuios_proto::PROTOCOL_VERSION,
            "codename": shuios_proto::SHUIOS_CODENAME,
            "uptime_secs": crate::state::now_secs().saturating_sub(app.started_at),
        })),
        "config.get" => {
            let mut v = serde_json::to_value(&app.cfg).unwrap_or(serde_json::Value::Null);
            if let Some(obj) = v.as_object_mut() {
                let legacy_key = app
                    .cfg
                    .llm
                    .api_key
                    .as_deref()
                    .map(|s| !s.trim().is_empty())
                    .unwrap_or(false);
                if let Some(llm) = obj.get_mut("llm").and_then(|x| x.as_object_mut()) {
                    // 密钥不是可打印配置：只报告是否设置过。
                    llm.insert("api_key".into(), serde_json::Value::Null);
                    llm.insert("api_key_set".into(), serde_json::Value::Bool(legacy_key));
                }
                obj.insert(
                    "ai".into(),
                    serde_json::to_value(app.ai_status()).unwrap_or(serde_json::Value::Null),
                );
            }
            Response::ok(v)
        }

        "ai.status" => Response::ok(
            serde_json::to_value(app.ai_status()).unwrap_or(serde_json::Value::Null),
        ),
        "ai.providers" => Response::ok(
            serde_json::to_value(AI_PROVIDERS).unwrap_or(serde_json::Value::Null),
        ),
        "ai.configure" => {
            #[derive(serde::Deserialize)]
            struct P {
                #[serde(default)]
                provider: Option<String>,
                #[serde(default)]
                endpoint: Option<String>,
                #[serde(default)]
                model: Option<String>,
                #[serde(default)]
                api_key: Option<String>,
                #[serde(default)]
                clear_key: Option<bool>,
                #[serde(default)]
                timeout_secs: Option<u64>,
                #[serde(default)]
                temperature: Option<f64>,
            }
            match parse::<P>(&req.params) {
                Ok(p) => {
                    let mut next = app.ai_config();
                    if let Some(v) = p.provider {
                        if v.trim().is_empty() {
                            return Response::err(errcode::BAD_PARAMS, "提供商不能为空");
                        }
                        next.provider = v.trim().to_string();
                    }
                    if let Some(v) = p.endpoint {
                        match shui_llm::validate_endpoint(&v) {
                            Ok(url) => next.endpoint = url,
                            Err(e) => return Response::err(errcode::BAD_PARAMS, e),
                        }
                    }
                    if let Some(v) = p.model {
                        if v.trim().is_empty() {
                            return Response::err(errcode::BAD_PARAMS, "模型名不能为空");
                        }
                        next.model = v.trim().to_string();
                    }
                    if let Some(v) = p.api_key {
                        let k = v.trim();
                        if k.is_empty() {
                            return Response::err(
                                errcode::BAD_PARAMS,
                                "api_key 不能为空；要清除请用 clear_key=true",
                            );
                        }
                        next.api_key = k.to_string();
                    }
                    if p.clear_key == Some(true) {
                        next.api_key.clear();
                    }
                    if let Some(v) = p.timeout_secs {
                        next.timeout_secs = v;
                    }
                    if let Some(v) = p.temperature {
                        next.temperature = v;
                    }
                    if let Err(e) = next.validate() {
                        return Response::err(errcode::BAD_PARAMS, e);
                    }
                    if let Err(e) = crate::ai::save(&next) {
                        app.log(format!("AI 配置保存失败: {e}"));
                        return Response::err(errcode::INTERNAL, e);
                    }
                    app.log(format!(
                        "AI 配置已更新: provider={} endpoint={} model={} key={}",
                        next.provider,
                        next.endpoint,
                        next.model,
                        next.key_hint().as_deref().unwrap_or("未设置")
                    ));
                    app.set_ai_config(next.clone());
                    Response::ok(serde_json::json!({
                        "saved": true,
                        "status": next.status(),
                    }))
                }
                Err(r) => r,
            }
        }
        "ai.chat" => {
            #[derive(serde::Deserialize)]
            struct P {
                messages: Vec<serde_json::Value>,
                #[serde(default)]
                model: Option<String>,
                #[serde(default)]
                temperature: Option<f64>,
                #[serde(default)]
                max_tokens: Option<u32>,
            }
            match parse::<P>(&req.params) {
                Ok(p) => {
                    if p.messages.is_empty() {
                        return Response::err(errcode::BAD_PARAMS, "messages 不能为空");
                    }
                    let raw_len = serde_json::to_string(&p.messages).map(|s| s.len()).unwrap_or(0);
                    if p.messages.len() > 200 || raw_len > 512 * 1024 {
                        return Response::err(errcode::BAD_PARAMS, "对话上下文过大");
                    }
                    let cfg = app.ai_config();
                    if !cfg.is_local() && !cfg.key_set() {
                        return Response::err(
                            errcode::AI_NOT_READY,
                            "未配置 API 密钥：打开 设置 → AI，或运行 shui-ctl ai set --key-stdin",
                        );
                    }
                    let model = p
                        .model
                        .as_deref()
                        .map(str::trim)
                        .filter(|s| !s.is_empty())
                        .unwrap_or(&cfg.model)
                        .to_string();
                    let temperature = p.temperature.unwrap_or(cfg.temperature);
                    if !(0.0..=2.0).contains(&temperature) {
                        return Response::err(errcode::BAD_PARAMS, "temperature 必须在 0 到 2 之间");
                    }
                    if let Some(n) = p.max_tokens {
                        if n == 0 || n > 32768 {
                            return Response::err(errcode::BAD_PARAMS, "max_tokens 超出范围");
                        }
                    }
                    let started = Instant::now();
                    match shui_llm::chat(
                        &cfg.endpoint,
                        Some(cfg.api_key.as_str()),
                        &model,
                        &p.messages,
                        temperature,
                        Duration::from_secs(cfg.timeout_secs.max(5)),
                        p.max_tokens,
                    ) {
                        Ok(reply) => {
                            let elapsed = started.elapsed().as_millis() as u64;
                            app.log(format!(
                                "ai.chat model={model} messages={} 耗时={elapsed}ms",
                                p.messages.len()
                            ));
                            Response::ok(serde_json::json!({
                                "content": reply.content,
                                "model": model,
                                "usage": reply.usage,
                                "elapsed_ms": elapsed,
                            }))
                        }
                        Err(e) => {
                            app.log(format!("ai.chat 失败 model={model}: {e}"));
                            Response::err(errcode::INTERNAL, e)
                        }
                    }
                }
                Err(r) => r,
            }
        }
        "ai.test" => {
            let cfg = app.ai_config();
            if !cfg.is_local() && !cfg.key_set() {
                return Response::ok(serde_json::json!({
                    "ok": false,
                    "error": "未配置 API 密钥：在下方填入密钥并保存后再测试",
                    "model": cfg.model,
                    "endpoint": cfg.endpoint,
                }));
            }
            let messages = vec![serde_json::json!({
                "role": "user",
                "content": "这是一次连通性测试。请只回复 OK 两个字母。"
            })];
            let started = Instant::now();
            let timeout = Duration::from_secs(cfg.timeout_secs.clamp(5, 30));
            match shui_llm::chat(
                &cfg.endpoint,
                Some(cfg.api_key.as_str()),
                &cfg.model,
                &messages,
                0.0,
                timeout,
                Some(16),
            ) {
                Ok(reply) => {
                    let elapsed = started.elapsed().as_millis() as u64;
                    app.log(format!(
                        "ai.test 成功 model={} 耗时={elapsed}ms",
                        cfg.model
                    ));
                    Response::ok(serde_json::json!({
                        "ok": true,
                        "reply": reply.content.trim(),
                        "model": cfg.model,
                        "endpoint": cfg.endpoint,
                        "latency_ms": elapsed,
                        "usage": reply.usage,
                    }))
                }
                Err(e) => {
                    app.log(format!("ai.test 失败 model={}: {e}", cfg.model));
                    Response::ok(serde_json::json!({
                        "ok": false,
                        "error": e,
                        "model": cfg.model,
                        "endpoint": cfg.endpoint,
                        "latency_ms": started.elapsed().as_millis() as u64,
                    }))
                }
            }
        }

        "system.info" => {
            let (total, running) = app.count();
            let info = sysinfo::system_info(total, running);
            Response::ok(serde_json::to_value(info).unwrap_or(serde_json::Value::Null))
        }

        "agent.spawn" => match parse::<AgentSpec>(&req.params) {
            Ok(mut spec) => {
                merge_default_limits(&mut spec.limits, &app.cfg.default_limits);
                match supervisor::spawn(app, spec) {
                    Ok(info) => Response::ok(serde_json::to_value(info).unwrap_or_default()),
                    Err(e) => Response::err(errcode::INTERNAL, e),
                }
            }
            Err(r) => r,
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
            Response::ok(serde_json::to_value(infos).unwrap_or_default())
        }
        "agent.get" => {
            #[derive(serde::Deserialize)]
            struct P {
                name: String,
            }
            match parse::<P>(&req.params) {
                Ok(p) => match app.get(&p.name) {
                    Some(h) => {
                        let info = match h.lock() {
                            Ok(g) => g.info(),
                            Err(pp) => pp.into_inner().info(),
                        };
                        Response::ok(serde_json::to_value(info).unwrap_or_default())
                    }
                    None => Response::err(errcode::NO_SUCH_AGENT, format!("智能体 {} 不存在", p.name)),
                },
                Err(r) => r,
            }
        }
        "agent.kill" => {
            #[derive(serde::Deserialize)]
            struct P {
                name: String,
            }
            match parse::<P>(&req.params) {
                Ok(p) => match supervisor::kill(app, &p.name) {
                    Ok(info) => Response::ok(serde_json::to_value(info).unwrap_or_default()),
                    Err(e) => Response::err(errcode::NO_SUCH_AGENT, e),
                },
                Err(r) => r,
            }
        }
        "agent.forget" => {
            #[derive(serde::Deserialize)]
            struct P {
                name: String,
            }
            match parse::<P>(&req.params) {
                Ok(p) => {
                    let removed = supervisor::forget(app, &p.name);
                    Response::ok(serde_json::json!({ "removed": removed }))
                }
                Err(r) => r,
            }
        }
        "agent.logs" => {
            #[derive(serde::Deserialize)]
            struct P {
                name: String,
                #[serde(default)]
                lines: Option<usize>,
            }
            match parse::<P>(&req.params) {
                Ok(p) => match app.get(&p.name) {
                    Some(h) => {
                        let l = supervisor::tail(&h, p.lines.unwrap_or(80));
                        Response::ok(serde_json::json!(l))
                    }
                    None => Response::err(errcode::NO_SUCH_AGENT, format!("智能体 {} 不存在", p.name)),
                },
                Err(r) => r,
            }
        }
        "agent.send" => {
            #[derive(serde::Deserialize)]
            struct P {
                name: String,
                data: String,
            }
            match parse::<P>(&req.params) {
                Ok(p) => match app.get(&p.name) {
                    Some(h) => match supervisor::send(&p.name, &h, &p.data) {
                        Ok(()) => Response::ok(serde_json::json!({ "sent": true })),
                        Err(e) => Response::err(errcode::INTERNAL, e),
                    },
                    None => Response::err(errcode::NO_SUCH_AGENT, format!("智能体 {} 不存在", p.name)),
                },
                Err(r) => r,
            }
        }

        "model.list" => {
            let models = tools::scan_models(&app.cfg.model_dir);
            Response::ok(serde_json::to_value(models).unwrap_or_default())
        }
        "model.select" => {
            let models = tools::scan_models(&app.cfg.model_dir);
            let mem = sysinfo::mem_available();
            let picked = shuios_proto::models::pick_model(&models, mem);
            let reason = match picked {
                Some(m) => shuios_proto::models::explain(&models, mem, m),
                None => {
                    "模型仓库为空（把 .gguf 放进 /var/lib/shuios/models/）".to_string()
                }
            };
            app.log(format!("模型挑选: {reason}"));
            Response::ok(serde_json::json!({
                "selected": picked,
                "reason": reason,
                "count": models.len(),
                "available_bytes": mem,
                "budget_bytes": (mem as f64 * shuios_proto::models::MEMORY_BUDGET_RATIO) as u64,
            }))
        }
        "mcp.tools" => Response::ok(serde_json::to_value(tools::list()).unwrap_or_default()),
        "mcp.servers" => Response::ok(serde_json::json!([crate::mcp::server_info()])),
        "mcp.info" => Response::ok(serde_json::json!({
            "socket": shuios_proto::mcp::SYSTEM_MCP_SOCKET,
            "protocol_version": shuios_proto::mcp::MCP_PROTOCOL_VERSION,
            "tool_count": tools::list().len(),
            "enabled": app.cfg.mcp_tools,
        })),
        "mcp.call" => {
            #[derive(serde::Deserialize)]
            struct P {
                #[serde(alias = "name")]
                tool: String,
                #[serde(default, alias = "args")]
                arguments: serde_json::Value,
            }
            match parse::<P>(&req.params) {
                Ok(p) => {
                    if !app.cfg.mcp_tools {
                        return Response::err(errcode::INTERNAL, "内置 MCP 工具已禁用".to_string());
                    }
                    let r = tools::call(app, &p.tool, &p.arguments);
                    Response::ok(serde_json::to_value(r).unwrap_or_default())
                }
                Err(r) => r,
            }
        }

        other => Response::err(errcode::METHOD_NOT_FOUND, format!("未知方法 {other}")),
    }
}

/// 未显式指定的限额从全局默认值补齐。
fn merge_default_limits(limits: &mut Limits, defaults: &Limits) {
    if limits.memory_max.is_none() {
        limits.memory_max = defaults.memory_max.clone();
    }
    if limits.pids_max.is_none() {
        limits.pids_max = defaults.pids_max;
    }
    if limits.cpu_weight.is_none() {
        limits.cpu_weight = defaults.cpu_weight;
    }
    if limits.io_weight.is_none() {
        limits.io_weight = defaults.io_weight;
    }
}
