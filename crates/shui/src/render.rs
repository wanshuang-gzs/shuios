//! 终端排版：颜色、表格、人类可读单位。

use shuios_proto::{AgentInfo, ModelInfo, SystemInfo, ToolInfo};

/// 是否启用 ANSI 颜色。
pub fn color_enabled() -> bool {
    std::env::var_os("NO_COLOR").is_none()
}

fn paint(code: &str, s: &str, on: bool) -> String {
    if on {
        format!("\x1b[{code}m{s}\x1b[0m")
    } else {
        s.to_string()
    }
}

/// 粗体
pub fn bold(s: &str, on: bool) -> String {
    paint("1", s, on)
}
/// 青色
pub fn cyan(s: &str, on: bool) -> String {
    paint("36", s, on)
}
/// 绿色
pub fn green(s: &str, on: bool) -> String {
    paint("32", s, on)
}
/// 黄色
pub fn yellow(s: &str, on: bool) -> String {
    paint("33", s, on)
}
/// 红色
pub fn red(s: &str, on: bool) -> String {
    paint("31", s, on)
}
/// 暗色
pub fn dim(s: &str, on: bool) -> String {
    paint("2", s, on)
}

/// 字节数 → `1.2 GiB`。
pub fn bytes_human(n: u64) -> String {
    const U: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

/// 秒 → `3m12s`。
pub fn dur_human(secs: u64) -> String {
    if secs < 60 {
        format!("{secs}s")
    } else if secs < 3600 {
        format!("{}m{}s", secs / 60, secs % 60)
    } else if secs < 86400 {
        format!("{}h{}m", secs / 3600, (secs % 3600) / 60)
    } else {
        format!("{}d{}h", secs / 86400, (secs % 86400) / 3600)
    }
}

fn state_label(a: &AgentInfo, on: bool) -> String {
    match a.state {
        shuios_proto::AgentState::Running => green("running", on),
        shuios_proto::AgentState::Starting => yellow("starting", on),
        shuios_proto::AgentState::Exited => dim("exited", on),
        shuios_proto::AgentState::Failed => red("failed", on),
    }
}

/// 智能体列表表格。
pub fn agent_table(agents: &[AgentInfo], on: bool) -> String {
    if agents.is_empty() {
        return dim("（还没有智能体。用 /spawn <名字> <命令...> 派生一个）", on);
    }
    let mut out = String::new();
    out.push_str(&format!(
        "{}{}{}\n",
        bold(&format!("{:<16}", "名字"), on),
        bold(&format!("{:<9}", "状态"), on),
        bold("资源", on)
    ));
    for a in agents {
        let mem = a.memory_bytes.map(bytes_human).unwrap_or_else(|| "-".to_string());
        let cpu = a
            .cpu_usage_usec
            .map(|u| format!("{:.1}s", u as f64 / 1_000_000.0))
            .unwrap_or_else(|| "-".to_string());
        out.push_str(&format!(
            "{:<16}{:<9}{} {}\n",
            a.name,
            state_label(a, on),
            mem,
            dim(&format!("cpu {cpu}  pid {}", a.pid), on)
        ));
    }
    out
}

/// 系统概况。
pub fn system_summary(s: &SystemInfo, on: bool) -> String {
    let mut out = String::new();
    out.push_str(&format!("{} {} {} {}\n", bold("shuios", on), s.os_version, bold(&s.arch, on), dim(&s.hostname, on)));
    out.push_str(&format!("{} {}\n", dim("内核:", on), s.kernel));
    out.push_str(&format!(
        "{} {} / {}   {} {:.2}   {} {}\n",
        dim("内存:", on),
        bytes_human(s.mem_total_bytes.saturating_sub(s.mem_available_bytes)),
        bytes_human(s.mem_total_bytes),
        dim("负载:", on),
        s.load1,
        dim("在线:", on),
        dur_human(s.uptime_secs)
    ));
    out.push_str(&format!(
        "{} {} 运行 / {} 登记   {} {}\n",
        dim("智能体:", on),
        s.agents_running,
        s.agents_total,
        dim("cgroup v2:", on),
        if s.cgroup_v2 { green("可用", on) } else { red("不可用", on) }
    ));
    out.push_str(&format!(
        "{} {}\n",
        dim("根文件系统:", on),
        if s.immutable_root { green("只读（不可变）", on) } else { yellow("可写（未启用不可变根）", on) }
    ));
    out
}

/// 模型列表。
pub fn model_table(models: &[ModelInfo], dir: &str, on: bool) -> String {
    if models.is_empty() {
        return format!(
            "{}\n{}",
            dim(&format!("{dir} 下没有模型文件"), on),
            dim("把 .gguf 模型放进去，或运行 shui-ctl model pull <url>", on)
        );
    }
    let mut out = String::new();
    for m in models {
        out.push_str(&format!("{:<40} {}\n", m.name, dim(&bytes_human(m.size_bytes), on)));
    }
    out
}

/// 工具列表。
pub fn tool_table(tools: &[ToolInfo], on: bool) -> String {
    let mut out = String::new();
    for t in tools {
        out.push_str(&format!("{}  {}\n", cyan(&format!("{:<14}", t.name), on), t.description));
    }
    out
}
