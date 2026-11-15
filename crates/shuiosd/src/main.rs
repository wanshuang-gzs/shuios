//! # shuiosd — 氵系统 智能体运行时守护进程
//!
//! 职责：
//! 1. 在 `/run/shuios/shuiosd.sock` 上提供 JSON Lines RPC 控制平面；
//! 2. 以 cgroup v2 为依据管理「智能体」进程的资源与生命周期；
//! 3. 把智能体输出落到 `/var/log/shuios/agents/<name>.log` 并在内存中保留尾部；
//! 4. 暴露一组内置 MCP 工具，让本地模型能安全地观察和操作这台机器；
//! 5. 维护本地模型仓库索引 `/var/lib/shuios/models`。
//!
//! 设计取舍：只用 `std` + `serde` + `libc`，不引入异步运行时。
//! 智能体数量在单机上是几十个量级的，线程模型足够且更可预测。

mod cgroup;
mod config;
mod ai;
mod htmltext;
mod mcp;
mod server;
mod state;
mod supervisor;
mod sysinfo;
mod tools;

use std::sync::Arc;

const USAGE: &str = "\
shuiosd — shuios (氵系统) 智能体运行时

用法:
  shuiosd [选项]

选项:
  -c, --config <PATH>   配置文件，默认 /etc/shuios/shuios.json
  -s, --socket <PATH>   覆盖控制套接字路径
  -f, --foreground      前台运行（默认行为，供 systemd Type=simple 使用）
  -V, --version         打印版本
  -h, --help            打印本帮助
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut cfg_path = shuios_proto::DEFAULT_CONFIG.to_string();
    let mut socket_override: Option<String> = None;
    let mut i = 0;

    while i < args.len() {
        match args[i].as_str() {
            "-c" | "--config" => {
                i += 1;
                match args.get(i) {
                    Some(p) => cfg_path = p.clone(),
                    None => fail("--config 需要一个路径"),
                }
            }
            "-s" | "--socket" => {
                i += 1;
                match args.get(i) {
                    Some(p) => socket_override = Some(p.clone()),
                    None => fail("--socket 需要一个路径"),
                }
            }
            "-f" | "--foreground" => {}
            "-V" | "--version" => {
                println!(
                    "shuiosd {} (protocol {}, codename {})",
                    shuios_proto::SHUIOS_VERSION,
                    shuios_proto::PROTOCOL_VERSION,
                    shuios_proto::SHUIOS_CODENAME
                );
                return;
            }
            "-h" | "--help" => {
                print!("{USAGE}");
                return;
            }
            other => fail(&format!("未知参数: {other}")),
        }
        i += 1;
    }

    let mut cfg = match config::Config::load(&cfg_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("shuiosd: 读取 {cfg_path} 失败（{e}），使用内置默认配置");
            config::Config::default()
        }
    };
    if let Some(s) = socket_override {
        cfg.socket = s;
    }

    let ai_cfg = ai::load(&cfg);
    let app = Arc::new(state::App::new(cfg, ai_cfg));
    app.log(format!(
        "启动 shuiosd {} (protocol {})，配置 {}",
        shuios_proto::SHUIOS_VERSION,
        shuios_proto::PROTOCOL_VERSION,
        cfg_path
    ));
    {
        let s = app.ai_status();
        app.log(format!(
            "AI 配置: provider={} endpoint={} model={} key={} ready={}",
            s.provider_name,
            s.endpoint,
            s.model,
            s.key_hint.as_deref().unwrap_or("未设置"),
            s.ready
        ));
    }

    if let Err(e) = app.prepare_dirs() {
        app.log(format!("警告: 准备目录失败: {e}"));
    }
    cgroup::init(&app);

    let autostart = app.cfg.autostart.clone();
    for spec in autostart {
        match supervisor::spawn(&app, spec.clone()) {
            Ok(info) => app.log(format!("自启智能体 {} pid={}", info.name, info.pid)),
            Err(e) => app.log(format!("自启智能体 {} 失败: {e}", spec.name)),
        }
    }

    // MCP 系统总线：独立套接字，只暴露工具发现与调用。
    {
        let app = app.clone();
        std::thread::spawn(move || {
            if let Err(e) = mcp::serve(&app) {
                app.log(format!("MCP 总线启动失败: {e}"));
            }
        });
    }

    if let Err(e) = server::serve(&app) {
        app.log(format!("控制平面退出: {e}"));
        std::process::exit(1);
    }
}

fn fail(msg: &str) -> ! {
    eprintln!("shuiosd: {msg}");
    eprintln!();
    eprint!("{USAGE}");
    std::process::exit(2)
}
