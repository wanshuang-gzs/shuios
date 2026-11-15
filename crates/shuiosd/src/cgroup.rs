//! cgroup v2 资源管理。
//!
//! shuios 的资源模型直接落在 cgroup v2 上：每个智能体一个 cgroup，
//! `/sys/fs/cgroup/shuios/<name>/`。镜像里 systemd 已经挂好 unified
//! hierarchy，因此这里只需要「建子树 / 写上限 / 迁入进程 / 整体击杀」。

use crate::state::App;
use shuios_proto::{CGROUP_ROOT, CGROUP_SLICE};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

static AVAILABLE: AtomicBool = AtomicBool::new(false);

/// 可选控制器，按优先级尝试开启。
const CONTROLLERS: [&str; 5] = ["memory", "pids", "cpu", "io", "cpuset"];

/// cgroup v2 是否可用。
pub fn available() -> bool {
    AVAILABLE.load(Ordering::Relaxed)
}

/// 智能体 cgroup 目录。
pub fn agent_dir(name: &str) -> PathBuf {
    Path::new(CGROUP_ROOT).join(CGROUP_SLICE).join(name)
}

/// 初始化：探测 unified hierarchy，开控制器，建 shuios 子树。
pub fn init(app: &App) {
    let root = Path::new(CGROUP_ROOT);
    let ctrl = match fs::read_to_string(root.join("cgroup.controllers")) {
        Ok(s) => s,
        Err(e) => {
            AVAILABLE.store(false, Ordering::Relaxed);
            app.log(format!("cgroup v2 不可用（{e}）：智能体资源限制不生效"));
            return;
        }
    };
    let ctrl: Vec<&str> = ctrl.split_whitespace().collect();
    if ctrl.is_empty() {
        AVAILABLE.store(false, Ordering::Relaxed);
        app.log("cgroup v2 控制器列表为空：资源限制不生效");
        return;
    }

    // 根 cgroup 允许持进程同时开 subtree_control（root 例外于 no-internal-process 规则）。
    let want: Vec<String> = CONTROLLERS
        .iter()
        .filter(|c| ctrl.contains(c))
        .map(|c| format!("+{c}"))
        .collect();
    if !want.is_empty() {
        if let Err(e) = fs::write(root.join("cgroup.subtree_control"), want.join(" ")) {
            app.log(format!("写根 cgroup.subtree_control 失败: {e}"));
        }
    }

    let slice = root.join(CGROUP_SLICE);
    if !slice.exists() {
        if let Err(e) = fs::create_dir(&slice) {
            AVAILABLE.store(false, Ordering::Relaxed);
            app.log(format!("创建 {} 失败（{e}）：资源限制不生效", slice.display()));
            return;
        }
    }
    // 子树内部同样需要开控制器，子 cgroup 才能写 memory.max 等。
    let sub = CONTROLLERS
        .iter()
        .filter(|c| ctrl.contains(c))
        .map(|c| format!("+{c}"))
        .collect::<Vec<_>>()
        .join(" ");
    if !sub.is_empty() {
        let _ = fs::write(slice.join("cgroup.subtree_control"), sub);
    }

    AVAILABLE.store(true, Ordering::Relaxed);
    app.log(format!(
        "cgroup v2 就绪：{}（可用控制器: {}）",
        slice.display(),
        ctrl.join(",")
    ));
}

/// 为智能体建 cgroup。
pub fn create(name: &str) -> io::Result<()> {
    if !available() {
        return Ok(());
    }
    let dir = agent_dir(name);
    if !dir.exists() {
        fs::create_dir(&dir)?;
    }
    Ok(())
}

/// 写入资源上限。
pub fn set_limits(name: &str, limits: &shuios_proto::Limits) -> io::Result<()> {
    if !available() {
        return Ok(());
    }
    let dir = agent_dir(name);
    if let Some(bytes) = limits.memory_max_bytes() {
        let _ = fs::write(dir.join("memory.max"), bytes.to_string());
        // 尽量留一点 swap 余量，避免直接 OOM 杀进程时体验过差。
        let _ = fs::write(dir.join("memory.swap.max"), "0");
    } else if let Some(ref raw) = limits.memory_max {
        if raw.eq_ignore_ascii_case("max") {
            let _ = fs::write(dir.join("memory.max"), "max");
        }
    }
    if let Some(p) = limits.pids_max {
        let _ = fs::write(dir.join("pids.max"), p.to_string());
    }
    if let Some(w) = limits.cpu_weight {
        let w = w.clamp(1, 10000);
        let _ = fs::write(dir.join("cpu.weight"), w.to_string());
    }
    if let Some(w) = limits.io_weight {
        let w = w.clamp(1, 1000);
        let _ = fs::write(dir.join("io.weight"), format!("default {w}"));
    }
    Ok(())
}

/// 把进程迁入 cgroup。
pub fn attach(name: &str, pid: u32) -> io::Result<()> {
    if !available() {
        return Ok(());
    }
    fs::write(agent_dir(name).join("cgroup.procs"), pid.to_string())
}

/// 整体击杀（cgroup.kill，内核 5.14+；失败则退化为 SIGKILL 进程组）。
pub fn kill(name: &str, pid: u32) -> io::Result<()> {
    if available() {
        let p = agent_dir(name).join("cgroup.kill");
        if fs::write(&p, "1").is_ok() {
            return Ok(());
        }
    }
    // setsid 之后 pid 即进程组 id。
    let rc = unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// 删除 cgroup（进程退出后调用，失败静默——内核可能仍持有引用）。
pub fn remove(name: &str) {
    if !available() {
        return;
    }
    let _ = fs::remove_dir(agent_dir(name));
}

/// 读取 `memory.current` 与 `cpu.stat` 的 `usage_usec`。
pub fn stats(name: &str) -> (Option<u64>, Option<u64>) {
    if !available() {
        return (None, None);
    }
    let dir = agent_dir(name);
    let mem = fs::read_to_string(dir.join("memory.current"))
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok());
    let cpu = fs::read_to_string(dir.join("cpu.stat")).ok().and_then(|s| {
        s.lines()
            .find(|l| l.starts_with("usage_usec"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<u64>().ok())
    });
    (mem, cpu)
}
