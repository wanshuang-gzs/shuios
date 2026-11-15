//! # shui — shuios 的 AI 原生 shell
//!
//! 三种输入形态：
//! * `/命令` —— 内置命令（智能体、模型、系统、工具）
//! * `!命令` / `$命令` —— 直接交给 `/bin/sh` 执行
//! * 其它 —— 当作自然语言交给本地模型，模型通过 `mcp.call` 调用系统工具
//!
//! 设计原则：模型不是在"聊天"，它是这台机器的一个操作者；
//! 每个工具调用都会被 shuiosd 记录并受限。

use shui::render as R;
use shuios_proto::ai::AiStatus;
use shuios_proto::client::Client;
use shuios_proto::{AgentInfo, AgentSpec, ModelInfo, SystemInfo, ToolInfo};
use std::io::{self, BufRead, Write};
use std::time::Duration;

const HELP: &str = "\
内置命令：
  /help                 显示本帮助
  /sys                  系统概况（内核、内存、智能体、只读根状态）
  /agents               列出智能体
  /spawn <名字> <命令..> 派生智能体（例：/spawn echo sleep 300）
  /kill <名字>           终止智能体
  /logs <名字> [行数]    查看智能体日志
  /models               本地模型仓库
  /tools                可用 MCP 工具
  /run <工具> [json]     直接调用工具（例：/run fs.list {\"path\":\"/\"}）
  /agentsend <名字> <文本> 向智能体 stdin 写一行
  /ai                   查看 AI 提供商/端点/密钥状态
  /ai test              发一次真实请求测试连通性
  /config               打印守护进程配置（不含密钥）
  /quit                 退出

输入约定：
  /开头的行是内置命令      !或$开头的行交给 sh 执行
  其它任何内容都会作为自然语言发给 AI，由它调用系统工具完成任务。
  AI 的端点与 API 密钥在「设置 → AI」里配置（shui-ctl ai 也可）。
";

/// 一次交互会话。
struct Session {
    client: Option<Client>,
    ai: Option<AiStatus>,
    model_override: Option<String>,
    color: bool,
    model_dir_hint: String,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut model_override: Option<String> = None;
    let mut color = R::color_enabled();
    let mut one_shot: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--model" | "-m" => {
                i += 1;
                if let Some(v) = args.get(i) {
                    model_override = Some(v.clone());
                }
            }
            "--endpoint" | "-e" => {
                eprintln!(
                    "shui: 推理端点改在 设置 → AI 配置（或 shui-ctl ai set --endpoint …），不再支持命令行指定"
                );
                std::process::exit(2);
            }
            "--no-color" => color = false,
            "-c" | "--command" => {
                i += 1;
                one_shot = args.get(i).cloned();
            }
            "-V" | "--version" => {
                println!("shui {} ({} 系统)", shuios_proto::SHUIOS_VERSION, shuios_proto::SHUIOS_CODENAME);
                return;
            }
            "-h" | "--help" => {
                println!("{HELP}");
                return;
            }
            other => {
                eprintln!("shui: 未知参数 {other}（用 --help 查看用法）");
                std::process::exit(2);
            }
        }
        i += 1;
    }

    let client = match Client::connect_default() {
        Ok(c) => Some(c),
        Err(e) => {
            eprintln!("shui: 连接 shuiosd 失败（{e}），进入降级模式：只能执行 shell 命令");
            None
        }
    };

    let mut sess = Session {
        client,
        ai: None,
        model_override,
        color,
        model_dir_hint: shuios_proto::MODEL_DIR.to_string(),
    };
    sess.refresh_ai();

    // 模型目录只是提示信息；AI 端点/密钥/模型由 ai.* RPC 管理。
    if let Some(v) = sess.call_opt("config.get", serde_json::json!({})) {
        if let Some(d) = v.get("model_dir").and_then(|x| x.as_str()) {
            sess.model_dir_hint = d.to_string();
        }
    }

    if let Some(cmd) = one_shot {
        run_input(&mut sess, &cmd);
        return;
    }

    banner(&sess);
    let stdin = io::stdin();
    loop {
        print!("{}", R::cyan("氵 ", sess.color));
        let _ = io::stdout().flush();
        let mut line = String::new();
        match stdin.lock().read_line(&mut line) {
            Ok(0) => {
                println!();
                break;
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!("读取输入失败: {e}");
                break;
            }
        }
        let input = line.trim_end_matches(['\n', '\r']).to_string();
        if input.trim().is_empty() {
            continue;
        }
        if !run_input(&mut sess, &input) {
            break;
        }
    }
    println!("{}", R::dim("再见。水无常形。", sess.color));
}

fn banner(sess: &Session) {
    println!(
        "{}  {}   {}\n{}",
        R::bold("shui", sess.color),
        R::dim(
            &format!(
                "shuios / 氵系统 {} 「{}」",
                shuios_proto::SHUIOS_VERSION,
                shuios_proto::SHUIOS_CODENAME
            ),
            sess.color
        ),
        R::dim("输入 /help 查看命令，或直接用一句话描述你要做的事。", sess.color),
        R::dim(
            &match &sess.ai {
                Some(a) => format!("AI  {} · {} · {}", a.provider_name, a.model, a.endpoint),
                None => "AI  未连接 shuiosd（仅 shell 直通）".to_string(),
            },
            sess.color
        )
    );
    if let Some(a) = &sess.ai {
        if !a.ready {
            println!(
                "{}",
                R::yellow(
                    "⚠ 尚未配置 API 密钥：打开 设置 → AI，或运行 shui-ctl ai set --key-stdin",
                    sess.color
                )
            );
        }
    }
    println!();
}

/// 处理一行输入；返回 false 表示要退出。
fn run_input(sess: &mut Session, input: &str) -> bool {
    let trimmed = input.trim();
    if let Some(cmd) = trimmed.strip_prefix('/') {
        return !handle_builtin(sess, cmd);
    }
    if let Some(cmd) = trimmed.strip_prefix('!').or_else(|| trimmed.strip_prefix('$')) {
        shell_passthrough(cmd, sess.color);
        return true;
    }
    match ask(sess, trimmed) {
        Ok(()) => true,
        Err(e) => {
            println!("{} {}", R::red("✗", sess.color), e);
            println!(
                "{}",
                R::dim(
                    "  提示：自然语言需要 AI 推理。先 /ai 查看端点与密钥状态，或 /run fs.list {\"path\":\"/workspace\"} 直接调工具。",
                    sess.color
                )
            );
            true
        }
    }
}

fn shell_passthrough(cmd: &str, color: bool) {
    let cmd = cmd.trim();
    if cmd.is_empty() {
        return;
    }
    let status = std::process::Command::new("sh").arg("-c").arg(cmd).status();
    match status {
        Ok(s) if !s.success() => {
            println!("{}", R::dim(&format!("[退出码 {:?}]", s.code()), color));
        }
        Ok(_) => {}
        Err(e) => println!("{} 无法执行 sh: {e}", R::red("✗", color)),
    }
}

impl Session {
    /// 调用守护进程；失败返回 None（降级模式）。
    fn call_opt(&mut self, method: &str, params: serde_json::Value) -> Option<serde_json::Value> {
        let client = self.client.as_mut()?;
        match client.call_raw(method, params) {
            Ok(resp) => {
                if let Some(e) = resp.error {
                    println!("{} {}: {}", R::red("✗", self.color), method, e.message);
                    None
                } else {
                    resp.result
                }
            }
            Err(e) => {
                println!("{} 与 shuiosd 通信失败: {e}", R::red("✗", self.color));
                None
            }
        }
    }

    /// 刷新 AI 状态；静默失败（daemon 不在时保留旧值）。
    fn refresh_ai(&mut self) {
        let Some(client) = self.client.as_mut() else {
            return;
        };
        if let Ok(resp) = client.call_raw("ai.status", serde_json::json!({})) {
            if let Some(v) = resp.result {
                if let Ok(s) = serde_json::from_value::<AiStatus>(v) {
                    self.ai = Some(s);
                }
            }
        }
    }

    /// 通过守护进程发一次 chat/completions（密钥只在 shuiosd 里）。
    fn ai_chat(&mut self, messages: &[serde_json::Value]) -> Result<String, String> {
        let timeout = self.ai.as_ref().map(|a| a.timeout_secs).unwrap_or(120);
        let model_override = self.model_override.clone();
        let client = self
            .client
            .as_mut()
            .ok_or_else(|| "shuiosd 未运行，无法使用 AI".to_string())?;
        client
            .set_read_timeout(Duration::from_secs(timeout.saturating_add(30)))
            .map_err(|e| format!("设置超时失败: {e}"))?;
        let mut params = serde_json::json!({ "messages": messages });
        if let Some(m) = model_override {
            params["model"] = serde_json::json!(m);
        }
        let resp = client
            .call_raw("ai.chat", params)
            .map_err(|e| format!("与 shuiosd 通信失败: {e}"));
        let _ = client.set_read_timeout(Duration::from_secs(30));
        let resp = resp?;
        if let Some(e) = resp.error {
            return Err(e.message);
        }
        let v = resp.result.unwrap_or(serde_json::Value::Null);
        v.get("content")
            .and_then(|c| c.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| format!("ai.chat 响应缺少 content: {v}"))
    }

    fn ai_test(&mut self) -> Result<serde_json::Value, String> {
        let client = self
            .client
            .as_mut()
            .ok_or_else(|| "shuiosd 未运行，无法测试 AI".to_string())?;
        client
            .set_read_timeout(Duration::from_secs(45))
            .map_err(|e| format!("设置超时失败: {e}"))?;
        let resp = client
            .call_raw("ai.test", serde_json::json!({}))
            .map_err(|e| format!("与 shuiosd 通信失败: {e}"));
        let _ = client.set_read_timeout(Duration::from_secs(30));
        let resp = resp?;
        if let Some(e) = resp.error {
            return Err(e.message);
        }
        Ok(resp.result.unwrap_or(serde_json::Value::Null))
    }

    fn call_typed<T: serde::de::DeserializeOwned>(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> Option<T> {
        let v = self.call_opt(method, params)?;
        match serde_json::from_value(v) {
            Ok(t) => Some(t),
            Err(e) => {
                println!("{} 解析 {method} 结果失败: {e}", R::red("✗", self.color));
                None
            }
        }
    }

    fn tools(&mut self) -> Vec<ToolInfo> {
        self.call_typed("mcp.tools", serde_json::json!({})).unwrap_or_default()
    }

    fn call_tool(&mut self, tool: &str, args: &serde_json::Value) -> Result<String, String> {
        let v = self
            .call_opt(
                "mcp.call",
                serde_json::json!({ "tool": tool, "arguments": args }),
            )
            .ok_or_else(|| format!("工具 {tool} 调用失败（shuiosd 不可用？）"))?;
        let ok = v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false);
        let content = v
            .get("content")
            .and_then(|x| x.as_str())
            .unwrap_or("(空结果)")
            .to_string();
        if ok {
            Ok(content)
        } else {
            Err(content)
        }
    }
}

/// 自然语言入口：让 AI 通过系统工具完成任务。
fn ask(sess: &mut Session, input: &str) -> Result<(), String> {
    if sess.client.is_none() {
        return Err("shuiosd 未运行，无法使用智能体能力".to_string());
    }
    sess.refresh_ai();
    if let Some(a) = &sess.ai {
        if !a.ready {
            return Err(format!(
                "{} 尚未就绪：请打开 设置 → AI 填入 API 密钥，或运行 shui-ctl ai set --key-stdin",
                a.provider_name
            ));
        }
    }
    let tools = sess.tools();
    let system = system_prompt(&tools);
    let mut messages: Vec<serde_json::Value> = vec![
        serde_json::json!({ "role": "system", "content": system }),
        serde_json::json!({ "role": "user", "content": input }),
    ];

    for round in 0..6 {
        let reply = sess.ai_chat(&messages)?;
        if let Some((tool, args)) = shui_llm::extract_tool_call(&reply) {
            println!(
                "{} {}",
                R::dim(&format!("⚙ 第{}轮 调用", round + 1), sess.color),
                R::cyan(&format!("{tool} {}", args), sess.color)
            );
            let result = sess.call_tool(&tool, &args)?;
            let preview: String = result.chars().take(400).collect();
            println!("{}", R::dim(&format!("  ↳ {}", preview.replace('\n', "\n     ")), sess.color));
            messages.push(serde_json::json!({ "role": "assistant", "content": reply }));
            messages.push(serde_json::json!({
                "role": "user",
                "content": format!(
                    "工具 {tool} 的执行结果：\n{result}\n\n若目标已达成，用简洁中文给出结论；若还需更多信息，继续以 JSON 形式调用工具。"
                )
            }));
            continue;
        }
        println!("{reply}");
        return Ok(());
    }
    Err("工具调用超过 6 轮，已中止（可能存在循环）".to_string())
}

fn system_prompt(tools: &[ToolInfo]) -> String {
    let mut list = String::new();
    for t in tools {
        list.push_str(&format!("- {}：{}\n", t.name, t.description));
    }
    format!(
        "你是 shuios（氵系统）的系统助手，运行在一个面向 AI 的极简 Linux 发行版里。\n\
         你只能通过工具观察和操作这台机器，不要臆造命令输出。\n\n\
         可用工具：\n{list}\n\
         调用工具的唯一方式：在回复中输出一个 JSON 对象，形如\n\
         {{\"tool\":\"fs.list\",\"arguments\":{{\"path\":\"/workspace\"}}}}\n\
         一次只输出一个工具调用；拿到结果后再决定下一步。\n\
         根文件系统是只读的，可写目录只有 /tmp、/workspace、/var/lib/shuios。\n\
         最终答复用简洁中文，不要输出多余 JSON。"
    )
}

fn handle_builtin(sess: &mut Session, cmd: &str) -> bool {
    let (name, rest) = match cmd.split_once(char::is_whitespace) {
        Some((n, r)) => (n, r.trim()),
        None => (cmd, ""),
    };
    match name {
        "help" | "h" | "?" => print!("{HELP}"),
        "quit" | "exit" | "q" => return true,
        "sys" | "status" => {
            if let Some(s) = sess.call_typed::<SystemInfo>("system.info", serde_json::json!({})) {
                print!("{}", R::system_summary(&s, sess.color));
            }
        }
        "agents" | "a" => {
            if let Some(list) = sess.call_typed::<Vec<AgentInfo>>("agent.list", serde_json::json!({})) {
                print!("{}", R::agent_table(&list, sess.color));
            }
        }
        "spawn" => {
            let mut words = rest.split_whitespace();
            match (words.next(), words.next()) {
                (Some(agent_name), Some(_)) => {
                    let argv: Vec<String> = rest
                        .split_whitespace()
                        .skip(1)
                        .map(|s| s.to_string())
                        .collect();
                    let mut spec = AgentSpec::new(agent_name, argv);
                    spec.description = Some(format!("由 shui 派生：{rest}"));
                    if let Some(v) = sess
                        .call_opt("agent.spawn", serde_json::to_value(&spec).unwrap_or_default())
                    {
                        println!(
                            "{} 已派生 {} pid={}",
                            R::green("✓", sess.color),
                            agent_name,
                            v.get("pid").and_then(|x| x.as_u64()).unwrap_or(0)
                        );
                    }
                }
                _ => println!("用法：/spawn <名字> <命令...>"),
            }
        }
        "kill" => {
            if rest.is_empty() {
                println!("用法：/kill <名字>");
            } else if sess
                .call_opt("agent.kill", serde_json::json!({ "name": rest }))
                .is_some()
            {
                println!("{} 已终止 {}", R::green("✓", sess.color), rest);
            }
        }
        "logs" => {
            let mut it = rest.split_whitespace();
            let Some(agent_name) = it.next() else {
                println!("用法：/logs <名字> [行数]");
                return false;
            };
            let lines: usize = it.next().and_then(|s| s.parse().ok()).unwrap_or(40);
            if let Some(v) = sess.call_opt(
                "agent.logs",
                serde_json::json!({ "name": agent_name, "lines": lines }),
            ) {
                if let Some(arr) = v.as_array() {
                    for l in arr {
                        if let Some(s) = l.as_str() {
                            println!("{s}");
                        }
                    }
                    if arr.is_empty() {
                        println!("{}", R::dim("（日志为空）", sess.color));
                    }
                }
            }
        }
        "agentsend" => {
            let mut it = rest.splitn(2, char::is_whitespace);
            let (Some(agent_name), Some(text)) = (it.next(), it.next()) else {
                println!("用法：/agentsend <名字> <文本>");
                return false;
            };
            if sess
                .call_opt(
                    "agent.send",
                    serde_json::json!({ "name": agent_name, "data": text }),
                )
                .is_some()
            {
                println!("{} 已发送", R::green("✓", sess.color));
            }
        }
        "models" | "model" => {
            if let Some(list) = sess.call_typed::<Vec<ModelInfo>>("model.list", serde_json::json!({})) {
                print!("{}", R::model_table(&list, &sess.model_dir_hint, sess.color));
            }
        }
        "tools" => {
            let tools = sess.tools();
            print!("{}", R::tool_table(&tools, sess.color));
        }
        "run" => {
            let (tool, json_args) = match rest.split_once(char::is_whitespace) {
                Some((t, j)) => (t, j.trim()),
                None => (rest, ""),
            };
            if tool.is_empty() {
                println!("用法：/run <工具> [json 参数]");
                return false;
            }
            let args: serde_json::Value = if json_args.is_empty() {
                serde_json::json!({})
            } else {
                match serde_json::from_str(json_args) {
                    Ok(v) => v,
                    Err(e) => {
                        println!("参数不是合法 JSON: {e}");
                        return false;
                    }
                }
            };
            match sess.call_tool(tool, &args) {
                Ok(s) => println!("{s}"),
                Err(e) => println!("{} {e}", R::red("✗", sess.color)),
            }
        }
        "ai" => {
            sess.refresh_ai();
            let status = sess.ai.clone();
            let Some(a) = status else {
                println!("{} shuiosd 未运行，无法读取 AI 配置", R::red("✗", sess.color));
                return false;
            };
            if rest == "test" {
                match sess.ai_test() {
                    Ok(v) if v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false) => {
                        println!(
                            "{} 连通（{} ms，{}）",
                            R::green("✓", sess.color),
                            v.get("latency_ms").and_then(|x| x.as_u64()).unwrap_or(0),
                            v.get("model").and_then(|x| x.as_str()).unwrap_or(&a.model)
                        );
                        println!(
                            "{}",
                            R::dim(
                                &format!("  回复：{}", v.get("reply").and_then(|x| x.as_str()).unwrap_or("(空)")),
                                sess.color
                            )
                        );
                    }
                    Ok(v) => println!(
                        "{} 测试失败：{}",
                        R::red("✗", sess.color),
                        v.get("error").and_then(|x| x.as_str()).unwrap_or("未知错误")
                    ),
                    Err(e) => println!("{} {e}", R::red("✗", sess.color)),
                }
                return false;
            }
            println!("AI 提供商   {}", a.provider_name);
            println!("推理端点    {}", a.endpoint);
            println!("模型        {}", a.model);
            println!(
                "API 密钥    {}",
                a.key_hint
                    .as_deref()
                    .map(|h| format!("已设置（{h}）"))
                    .unwrap_or_else(|| "未设置".to_string())
            );
            println!("状态        {}", if a.ready { "就绪" } else { "需要 API 密钥" });
            println!(
                "传输        {}",
                if a.secure { "HTTPS / 本机回环" } else { "不安全（远程明文 HTTP）" }
            );
            println!("配置文件    {}", a.config_path);
            if !a.ready {
                println!(
                    "{}",
                    R::yellow(
                        "  打开 设置 → AI 填入密钥，或运行：echo 'sk-…' | shui-ctl ai set --key-stdin",
                        sess.color
                    )
                );
            }
            println!(
                "{}",
                R::dim("/ai test 发一次真实请求；/help 查看其它命令。", sess.color)
            );
        }
        "config" => {
            if let Some(v) = sess.call_opt("config.get", serde_json::json!({})) {
                println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default());
            }
        }
        other => println!("未知内置命令 /{other}（/help 查看帮助）"),
    }
    false
}
