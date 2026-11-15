//! # shui-ctl — shuios 控制 CLI
//!
//! `shui` 是给人用的交互式 shell；`shui-ctl` 是给脚本和智能体用的
//! 一次性命令。所有子命令都通过控制平面套接字与 `shuiosd` 通信，
//! 没有直接魔法，输出尽量稳定（便于 `grep`/`jq`）。

use shuios_proto::ai::AiStatus;
use shuios_proto::client::Client;
use shuios_proto::{AgentInfo, AgentSpec, ModelInfo, SystemInfo, ToolInfo};
use std::io::{Read, Write};
use std::time::Duration;

mod swayipc;

const USAGE: &str = "\
shui-ctl — shuios (氵系统) 控制工具

用法: shui-ctl <子命令> [参数]

  status                 系统概况 + 智能体清单
  sys                    仅系统概况
  agents                 列出智能体
  spawn <名字> <命令...> 派生智能体
  kill <名字>            终止智能体
  forget <名字>          从登记表移除（不杀进程）
  logs <名字> [行数]     打印智能体日志
  send <名字> <文本>     向智能体 stdin 写一行
  tools                  列出内置 MCP 工具
  mcp                    查看 MCP 系统总线状态
  call <工具> [json]     调用工具
  models                 本地模型仓库
  model-select           输出应使用的模型路径（供 shuios-llama 调用）
  ai status              AI 提供商/端点/密钥状态（不含密钥）
  ai providers           内置提供商预设
  ai set [选项]          更新 AI 配置（密钥走 stdin 或 0600 文件）
  ai test                发一次真实请求测试连通性
  ai clear-key           删除已保存的 API 密钥
  bar                    给 swaybar 的状态行（JSON）
  windows [--follow]     当前窗口列表（TSV）；--follow 持续输出窗口事件
  config                 打印守护进程配置（密钥已脱敏）
  ping                   探活
  version                版本

ai set 选项:
  --provider <id>        预设 id（local/deepseek/qwen/moonshot/openai/custom）
  --endpoint <url>       OpenAI 兼容基础地址（远程必须 https://）
  --model <name>         模型名
  --timeout <秒>         请求超时（5..600）
  --temperature <0..2>   采样温度
  --key-stdin            从 stdin 读取 API 密钥（不回显）
  --key-file <path>      从 0600 文件读取 API 密钥
  --clear-key            清除已保存的密钥

示例:
  shui-ctl spawn watcher fs.list '{\"path\":\"/workspace\"}'
  shui-ctl call fs.read '{\"path\":\"/etc/os-release\"}'
  echo 'sk-…' | shui-ctl ai set --provider deepseek \\
      --endpoint https://api.deepseek.com/v1 --model deepseek-chat --key-stdin
  shui-ctl ai test
";

fn main() {    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        print!("{USAGE}");
        std::process::exit(2);
    }
    let sub = args[0].as_str();
    let rest: Vec<String> = args[1..].to_vec();

    if matches!(sub, "-h" | "--help" | "help") {
        print!("{USAGE}");
        return;
    }
    if matches!(sub, "-V" | "--version" | "version") {
        println!(
            "shui-ctl {} (shuios {}, 协议 {})",
            shuios_proto::SHUIOS_VERSION,
            shuios_proto::SHUIOS_CODENAME,
            shuios_proto::PROTOCOL_VERSION
        );
        return;
    }

    // 窗口命令直接读 sway IPC，不经过 shuiosd，所以在连守护进程之前处理
    if sub == "windows" {
        let follow = rest.iter().any(|a| a == "--follow");
        std::process::exit(cmd_windows(follow));
    }

    let mut client = match Client::connect_default() {
        Ok(c) => c,
        Err(e) => die(&format!(
            "连接 {} 失败: {e}\n（shuiosd 未运行？试试 systemctl status shuiosd）",
            shuios_proto::DEFAULT_SOCKET
        )),
    };

    match sub {
        "ping" => {
            let v: serde_json::Value = call(&mut client, "ping", serde_json::json!({}));
            println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default());
        }
        "sys" => {
            let s: SystemInfo = call(&mut client, "system.info", serde_json::json!({}));
            println!("主机名    {}", s.hostname);
            println!("系统      {} {} ({})", s.os_name, s.os_version, s.arch);
            println!("内核      {}", s.kernel);
            println!("运行时长  {}s", s.uptime_secs);
            println!("负载      {:.2}", s.load1);
            println!(
                "内存      {} / {}",
                human(s.mem_total_bytes.saturating_sub(s.mem_available_bytes)),
                human(s.mem_total_bytes)
            );
            println!("智能体    {} 运行 / {} 登记", s.agents_running, s.agents_total);
            println!("cgroup v2 {}", if s.cgroup_v2 { "可用" } else { "不可用" });
            println!(
                "只读根    {}",
                if s.immutable_root { "是（不可变）" } else { "否" }
            );
        }
        "agents" => {
            let list: Vec<AgentInfo> = call(&mut client, "agent.list", serde_json::json!({}));
            if list.is_empty() {
                println!("（没有智能体）");
                return;
            }
            println!("{:<18} {:<10} {:>10} {:>10} {:>8}", "名字", "状态", "内存", "CPU", "PID");
            for a in list {
                println!(
                    "{:<18} {:<10} {:>10} {:>9.1}s {:>8}",
                    a.name,
                    state_str(a.state),
                    a.memory_bytes.map(human).unwrap_or_else(|| "-".into()),
                    a.cpu_usage_usec.unwrap_or(0) as f64 / 1_000_000.0,
                    a.pid
                );
            }
        }
        "spawn" => {
            if rest.len() < 2 {
                die("用法: shui-ctl spawn <名字> <命令...>");
            }
            let name = rest[0].clone();
            let argv = rest[1..].to_vec();
            let spec = AgentSpec::new(name.clone(), argv);
            let info: AgentInfo =
                call(&mut client, "agent.spawn", serde_json::to_value(&spec).unwrap());
            println!("已派生 {} pid={} 状态={}", info.name, info.pid, state_str(info.state));
        }
        "kill" => {
            if rest.is_empty() {
                die("用法: shui-ctl kill <名字>");
            }
            let info: AgentInfo = call(
                &mut client,
                "agent.kill",
                serde_json::json!({ "name": rest[0] }),
            );
            println!("已终止 {}（exit={:?}）", info.name, info.exit_code);
        }
        "forget" => {
            if rest.is_empty() {
                die("用法: shui-ctl forget <名字>");
            }
            let v: serde_json::Value = call(
                &mut client,
                "agent.forget",
                serde_json::json!({ "name": rest[0] }),
            );
            println!("{}", serde_json::to_string(&v).unwrap_or_default());
        }
        "logs" => {
            if rest.is_empty() {
                die("用法: shui-ctl logs <名字> [行数]");
            }
            let lines: usize = rest.get(1).and_then(|s| s.parse().ok()).unwrap_or(60);
            let v: serde_json::Value = call(
                &mut client,
                "agent.logs",
                serde_json::json!({ "name": rest[0], "lines": lines }),
            );
            if let Some(arr) = v.as_array() {
                let mut out = std::io::stdout();
                for l in arr {
                    if let Some(s) = l.as_str() {
                        let _ = writeln!(out, "{s}");
                    }
                }
            }
        }
        "send" => {
            if rest.len() < 2 {
                die("用法: shui-ctl send <名字> <文本>");
            }
            let text = rest[1..].join(" ");
            let _: serde_json::Value = call(
                &mut client,
                "agent.send",
                serde_json::json!({ "name": rest[0], "data": text }),
            );
            println!("已发送");
        }
        "tools" => {
            let tools: Vec<ToolInfo> = call(&mut client, "mcp.tools", serde_json::json!({}));
            for t in tools {
                println!("{:<14} {}", t.name, t.description);
            }
        }
        "call" => {
            if rest.is_empty() {
                die("用法: shui-ctl call <工具> [json 参数]");
            }
            let args: serde_json::Value = rest
                .get(1)
                .map(|s| serde_json::from_str(s).unwrap_or(serde_json::json!({})))
                .unwrap_or(serde_json::json!({}));
            let v: serde_json::Value = call(
                &mut client,
                "mcp.call",
                serde_json::json!({ "tool": rest[0], "arguments": args }),
            );
            let content = v.get("content").and_then(|c| c.as_str()).unwrap_or("");
            println!("{content}");
            if !v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false) {
                std::process::exit(1);
            }
        }
        "models" => {
            let list: Vec<ModelInfo> = call(&mut client, "model.list", serde_json::json!({}));
            if list.is_empty() {
                println!("（{} 下没有模型）", shuios_proto::MODEL_DIR);
                return;
            }
            for m in list {
                println!("{:<44} {:>10}  {}", m.name, human(m.size_bytes), m.path);
            }
        }
        "mcp" => {
            let info: serde_json::Value = call(&mut client, "mcp.info", serde_json::json!({}));
            let servers: serde_json::Value =
                call(&mut client, "mcp.servers", serde_json::json!({}));
            println!("MCP 系统总线");
            println!(
                "  套接字    {}",
                info.get("socket").and_then(|v| v.as_str()).unwrap_or("-")
            );
            println!(
                "  协议版本  {}",
                info.get("protocol_version")
                    .and_then(|v| v.as_str())
                    .unwrap_or("-")
            );
            println!(
                "  工具数量  {}",
                info.get("tool_count").and_then(|v| v.as_u64()).unwrap_or(0)
            );
            println!(
                "  是否启用  {}",
                if info.get("enabled").and_then(|v| v.as_bool()).unwrap_or(false) {
                    "是"
                } else {
                    "否"
                }
            );
            if let Some(arr) = servers.as_array() {
                for s in arr {
                    println!(
                        "  服务      {} -> {}",
                        s.get("name").and_then(|v| v.as_str()).unwrap_or("-"),
                        s.get("socket").and_then(|v| v.as_str()).unwrap_or("-")
                    );
                }
            }
        }
        "model-select" => {
            let v: serde_json::Value = call(&mut client, "model.select", serde_json::json!({}));
            let path = v
                .get("selected")
                .and_then(|s| s.get("path"))
                .and_then(|p| p.as_str());
            match path {
                Some(p) => println!("{p}"),
                None => {
                    eprintln!(
                        "shui-ctl: 没有可用模型（{}）",
                        v.get("reason").and_then(|r| r.as_str()).unwrap_or("未知原因")
                    );
                    std::process::exit(1);
                }
            }
        }
        "ai" => cmd_ai(&mut client, &rest),
        // 状态行。两种消费者：
        //   swaybar：status_command 输出一行 JSON {"text","tooltip"}（可用 pango markup）
        //   waybar ：custom 模块只吃纯文本 → `shui-ctl bar --text`
        "bar" => {
            let s: SystemInfo = call(&mut client, "system.info", serde_json::json!({}));
            let used = human(s.mem_total_bytes.saturating_sub(s.mem_available_bytes));
            let total = human(s.mem_total_bytes);
            let ro = if s.immutable_root { "只读" } else { "可写" };

            if rest.iter().any(|a| a == "--text") {
                println!(
                    "⊙ {}/{} · {} · {}",
                    s.agents_running, s.agents_total, used, ro
                );
                return;
            }

            let text = format!(
                "<span size=\"large\" foreground=\"#2daed9\">氵</span> \
                 <span foreground=\"#2daed9\">{}/{}</span> · {} · \
                 <span foreground=\"#7ad17a\">{}</span>",
                s.agents_running, s.agents_total, used, ro
            );
            let tooltip = format!(
                "shuios {} 「{}」\n主机 {}\n内存 {}/{}  负载 {:.2}\n智能体 {} 运行 / {} 登记\n根文件系统 {}",
                s.os_version,
                shuios_proto::SHUIOS_CODENAME,
                s.hostname,
                used,
                total,
                s.load1,
                s.agents_running,
                s.agents_total,
                if s.immutable_root { "只读（不可变）" } else { "可写" }
            );
            println!(
                "{}",
                serde_json::json!({ "text": text, "tooltip": tooltip, "class": "shuios" })
            );
        }
        "config" => {
            let v: serde_json::Value = call(&mut client, "config.get", serde_json::json!({}));
            println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default());
        }
        "status" => {
            let s: SystemInfo = call(&mut client, "system.info", serde_json::json!({}));
            println!(
                "shuios {} {} — {} ({}), 内核 {}",
                s.os_version,
                shuios_proto::SHUIOS_CODENAME,
                s.hostname,
                s.arch,
                short_kernel(&s.kernel)
            );
            println!(
                "内存 {}/{}  负载 {:.2}  在线 {}s  智能体 {}/{} 只读根={}",
                human(s.mem_total_bytes.saturating_sub(s.mem_available_bytes)),
                human(s.mem_total_bytes),
                s.load1,
                s.uptime_secs,
                s.agents_running,
                s.agents_total,
                s.immutable_root
            );
            let list: Vec<AgentInfo> = call(&mut client, "agent.list", serde_json::json!({}));
            for a in list {
                println!(
                    "  {:<16} {:<9} {:>9}  pid {}",
                    a.name,
                    state_str(a.state),
                    a.memory_bytes.map(human).unwrap_or_else(|| "-".into()),
                    a.pid
                );
            }
        }
        other => die(&format!("未知子命令 {other}\n\n{USAGE}")),
    }
}

fn call<T: serde::de::DeserializeOwned>(
    c: &mut Client,
    method: &str,
    params: serde_json::Value,
) -> T {
    match c.call::<T>(method, params) {
        Ok(v) => v,
        Err(e) => die(&format!("{method} 失败: {e}")),
    }
}

/// `shui-ctl windows [--follow]`
///
/// 输出 TSV：`app_id \t title \t focused \t con_id \t workspace`
///
/// `--follow` 会先打印当前列表，然后持续输出事件行：
/// `change \t app_id \t title \t focused \t con_id \t workspace`
/// （change 取 sway 的值：new / close / focus / title / fullscreen_mode …）
///
/// shui-panel 用它在任务栏上维护"合并式"按钮列表。
fn cmd_windows(follow: bool) -> i32 {
    match swayipc::get_tree() {
        Ok(tree) => {
            for w in swayipc::collect_windows(&tree) {
                println!("{}", swayipc::to_tsv(&w));
            }
        }
        Err(e) => {
            eprintln!("shui-ctl windows: {e}");
            return 1;
        }
    }
    if !follow {
        return 0;
    }

    let mut stream = match swayipc::subscribe_windows() {
        Ok(s) => s,
        Err(e) => {
            eprintln!("shui-ctl windows: 订阅窗口事件失败：{e}");
            return 1;
        }
    };
    // 告诉调用方"订阅已就绪"（前面那批是初始快照）
    println!("_ready\t\t0\t0\t");
    let _ = std::io::stdout().flush();

    loop {
        match swayipc::recv_event(&mut stream) {
            Ok(Some((change, Some(w)))) => {
                println!("{change}\t{}", swayipc::to_tsv(&w));
                let _ = std::io::stdout().flush();
            }
            Ok(Some((change, None))) => {
                println!("{change}\t\t0\t0\t");
                let _ = std::io::stdout().flush();
            }
            Ok(None) => {}
            Err(e) => {
                eprintln!("shui-ctl windows: 事件流结束：{e}");
                return 0;
            }
        }
    }
}

fn die(msg: &str) -> ! {
    eprintln!("shui-ctl: {msg}");
    std::process::exit(1)
}

fn bool01(v: bool) -> u8 {
    if v { 1 } else { 0 }
}

fn one_line(s: &str) -> String {
    s.replace(['\r', '\n'], " ").trim().to_string()
}

fn print_ai_status(client: &mut Client) {
    let s: AiStatus = call(client, "ai.status", serde_json::json!({}));
    println!("provider={}", s.provider);
    println!("provider_name={}", s.provider_name);
    println!("endpoint={}", s.endpoint);
    println!("model={}", s.model);
    println!("key_set={}", bool01(s.key_set));
    println!("key_hint={}", s.key_hint.unwrap_or_default());
    println!("timeout_secs={}", s.timeout_secs);
    println!("temperature={}", s.temperature);
    println!("local={}", bool01(s.local));
    println!("secure={}", bool01(s.secure));
    println!("ready={}", bool01(s.ready));
    println!("config_path={}", s.config_path);
}

fn take_arg<'a>(args: &'a [String], i: &mut usize, flag: &str) -> &'a str {
    *i += 1;
    match args.get(*i) {
        Some(v) if !v.starts_with("--") => v.as_str(),
        _ => die(&format!("{flag} 需要一个参数")),
    }
}

fn read_key_file(path: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let p = std::path::Path::new(path);
    match std::fs::metadata(p) {
        Ok(meta) => {
            if meta.permissions().mode() & 0o077 != 0 {
                eprintln!("shui-ctl: 警告：密钥文件权限过宽，建议 chmod 600 {path}");
            }
        }
        Err(e) => die(&format!("读取密钥文件 {path} 失败: {e}")),
    }
    match std::fs::read_to_string(p) {
        Ok(s) => s.trim_end_matches(['\r', '\n']).to_string(),
        Err(e) => die(&format!("读取密钥文件 {path} 失败: {e}")),
    }
}

fn read_key_stdin() -> String {
    let mut s = String::new();
    if let Err(e) = std::io::stdin().read_to_string(&mut s) {
        die(&format!("读取 stdin 失败: {e}"));
    }
    s.trim_end_matches(['\r', '\n']).to_string()
}

fn cmd_ai(client: &mut Client, args: &[String]) {
    let Some(sub) = args.first().map(String::as_str) else {
        eprintln!("用法: shui-ctl ai status|providers|set|test|clear-key");
        std::process::exit(2);
    };
    match sub {
        "status" => print_ai_status(client),
        "providers" => {
            let list: Vec<serde_json::Value> =
                call(client, "ai.providers", serde_json::json!({}));
            for p in list {
                println!(
                    "{}\t{}\t{}\t{}\t{}",
                    p.get("id").and_then(|v| v.as_str()).unwrap_or(""),
                    p.get("name").and_then(|v| v.as_str()).unwrap_or(""),
                    p.get("endpoint").and_then(|v| v.as_str()).unwrap_or(""),
                    p.get("model").and_then(|v| v.as_str()).unwrap_or(""),
                    p.get("local").and_then(|v| v.as_bool()).unwrap_or(false)
                );
            }
        }
        "set" => {
            let mut provider: Option<String> = None;
            let mut endpoint: Option<String> = None;
            let mut model: Option<String> = None;
            let mut timeout: Option<u64> = None;
            let mut temperature: Option<f64> = None;
            let mut key_file: Option<String> = None;
            let mut key_stdin = false;
            let mut clear_key = false;

            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--provider" => provider = Some(take_arg(args, &mut i, "--provider").to_string()),
                    "--endpoint" => endpoint = Some(take_arg(args, &mut i, "--endpoint").to_string()),
                    "--model" => model = Some(take_arg(args, &mut i, "--model").to_string()),
                    "--timeout" => {
                        let v = take_arg(args, &mut i, "--timeout");
                        timeout = Some(v.parse().unwrap_or_else(|_| die("--timeout 需要整数秒")));
                    }
                    "--temperature" => {
                        let v = take_arg(args, &mut i, "--temperature");
                        temperature =
                            Some(v.parse().unwrap_or_else(|_| die("--temperature 需要数字")));
                    }
                    "--key-file" => {
                        key_file = Some(take_arg(args, &mut i, "--key-file").to_string())
                    }
                    "--key-stdin" => key_stdin = true,
                    "--clear-key" => clear_key = true,
                    other => die(&format!("未知 ai set 选项 {other}")),
                }
                i += 1;
            }
            if clear_key && (key_stdin || key_file.is_some()) {
                die("--clear-key 不能和 --key-stdin/--key-file 同时使用");
            }

            let key = if let Some(path) = key_file {
                Some(read_key_file(&path))
            } else if key_stdin {
                Some(read_key_stdin())
            } else {
                None
            };

            let mut params = serde_json::Map::new();
            if let Some(v) = provider {
                params.insert("provider".into(), serde_json::json!(v));
            }
            if let Some(v) = endpoint {
                params.insert("endpoint".into(), serde_json::json!(v));
            }
            if let Some(v) = model {
                params.insert("model".into(), serde_json::json!(v));
            }
            if let Some(v) = timeout {
                params.insert("timeout_secs".into(), serde_json::json!(v));
            }
            if let Some(v) = temperature {
                params.insert("temperature".into(), serde_json::json!(v));
            }
            if let Some(k) = key {
                if k.is_empty() {
                    die("没有从 stdin/文件读到 API 密钥");
                }
                params.insert("api_key".into(), serde_json::json!(k));
            }
            if clear_key {
                params.insert("clear_key".into(), serde_json::json!(true));
            }
            if params.is_empty() {
                die("没有要更新的字段（见 shui-ctl --help 的 ai set 选项）");
            }
            let _: serde_json::Value =
                call(client, "ai.configure", serde_json::Value::Object(params));
            println!("saved=1");
        }
        "clear-key" => {
            let _: serde_json::Value = call(
                client,
                "ai.configure",
                serde_json::json!({ "clear_key": true }),
            );
            println!("saved=1");
        }
        "test" => {
            let _ = client.set_read_timeout(Duration::from_secs(45));
            let v: serde_json::Value = call(client, "ai.test", serde_json::json!({}));
            let ok = v.get("ok").and_then(|x| x.as_bool()).unwrap_or(false);
            println!("ok={}", bool01(ok));
            if ok {
                println!(
                    "reply={}",
                    one_line(v.get("reply").and_then(|x| x.as_str()).unwrap_or(""))
                );
                println!(
                    "latency_ms={}",
                    v.get("latency_ms").and_then(|x| x.as_u64()).unwrap_or(0)
                );
                println!(
                    "model={}",
                    v.get("model").and_then(|x| x.as_str()).unwrap_or("")
                );
            } else {
                println!(
                    "error={}",
                    one_line(v.get("error").and_then(|x| x.as_str()).unwrap_or("未知错误"))
                );
                std::process::exit(1);
            }
        }
        other => {
            eprintln!("未知 ai 子命令 {other}（status|providers|set|test|clear-key）");
            std::process::exit(2);
        }
    }
}

fn state_str(s: shuios_proto::AgentState) -> &'static str {
    match s {
        shuios_proto::AgentState::Starting => "starting",
        shuios_proto::AgentState::Running => "running",
        shuios_proto::AgentState::Exited => "exited",
        shuios_proto::AgentState::Failed => "failed",
    }
}

fn human(n: u64) -> String {
    const U: [&str; 4] = ["B", "K", "M", "G"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n}{}", U[0])
    } else {
        format!("{v:.1}{}", U[i])
    }
}

fn short_kernel(k: &str) -> String {
    k.split_whitespace().take(3).collect::<Vec<_>>().join(" ")
}
