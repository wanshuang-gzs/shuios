//! 智能体监督器：派生、监控、记录、重启、击杀。

use crate::cgroup;
use crate::state::{now_secs, App, SharedAgent};
use shuios_proto::{AgentInfo, AgentSpec, AgentState};
use std::collections::VecDeque;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// 内存里保留的日志尾部行数。
pub const RING_CAPACITY: usize = 400;
/// 监控线程轮询间隔。
const POLL_INTERVAL: Duration = Duration::from_millis(300);
/// 重启退避上限。
const MAX_RESTART_BACKOFF_SECS: u64 = 30;
/// 连续重启放弃阈值。
const MAX_CONSECUTIVE_RESTARTS: u32 = 20;

/// 单个智能体的运行时句柄。
pub struct AgentHandle {
    pub spec: AgentSpec,
    pub pid: u32,
    pub state: AgentState,
    pub started_at: u64,
    pub exit_code: Option<i32>,
    pub log_path: PathBuf,
    pub ring: VecDeque<String>,
    /// 智能体 stdin（`agent.send` 往这里写）。
    pub stdin: Option<ChildStdin>,
}

impl AgentHandle {
    /// 生成对外视图。
    pub fn info(&self) -> AgentInfo {
        let (mem, cpu) = cgroup::stats(&self.spec.name);
        AgentInfo {
            name: self.spec.name.clone(),
            pid: self.pid,
            state: self.state,
            started_at: self.started_at,
            exit_code: self.exit_code,
            memory_bytes: mem,
            cpu_usage_usec: cpu,
            limits: self.spec.limits.clone(),
            capabilities: self.spec.capabilities.clone(),
            restart: self.spec.restart,
            description: self.spec.description.clone(),
            log_path: self.log_path.display().to_string(),
        }
    }

    /// 追加一行到内存环形缓冲，返回日志行文本。
    fn push_line(&mut self, line: String) {
        if self.ring.len() >= RING_CAPACITY {
            self.ring.pop_front();
        }
        self.ring.push_back(line);
    }
}

/// 名字合法性：只允许 `A-Za-z0-9._-`，长度 1..=64。
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// 派生一个智能体。
pub fn spawn(app: &Arc<App>, spec: AgentSpec) -> Result<AgentInfo, String> {
    if !valid_name(&spec.name) {
        return Err("名字非法：只允许 A-Za-z0-9._-，长度 1..=64".to_string());
    }
    if spec.argv.is_empty() {
        return Err("argv 不能为空".to_string());
    }
    let (total, _) = app.count();
    if total >= app.cfg.max_agents {
        return Err(format!("智能体数量已达上限 {}", app.cfg.max_agents));
    }
    if app.get(&spec.name).is_some() {
        return Err(format!("智能体 {} 已存在", spec.name));
    }

    let log_path = PathBuf::from(&app.cfg.agent_log_dir).join(format!("{}.log", spec.name));
    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let mut cmd = Command::new(&spec.argv[0]);
    cmd.args(&spec.argv[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    if let Some(ref wd) = spec.workdir {
        cmd.current_dir(wd);
    }
    for (k, v) in &spec.env {
        cmd.env(k, v);
    }
    // 每个智能体独占一个会话/进程组，便于整组信号与作业控制。
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }

    let mut child = cmd.spawn().map_err(|e| format!("启动 {} 失败: {e}", spec.argv[0]))?;
    let pid = child.id();
    let stdin = child.stdin.take();

    // 资源上限：建 cgroup → 写上限 → 迁入进程。
    let mut limits_applied = true;
    if let Err(e) = cgroup::create(&spec.name) {
        app.log(format!("创建 cgroup 失败（{}）: {e}", spec.name));
        limits_applied = false;
    }
    if limits_applied {
        if let Err(e) = cgroup::set_limits(&spec.name, &spec.limits) {
            app.log(format!("写 cgroup 限制失败（{}）: {e}", spec.name));
        }
        if let Err(e) = cgroup::attach(&spec.name, pid) {
            app.log(format!("迁移进程到 cgroup 失败（{}）: {e}", spec.name));
            limits_applied = false;
        }
    }

    let header = format!(
        "=== [{}] spawn {} pid={} cgroup_limits={} ===",
        now_secs(),
        spec.name,
        pid,
        limits_applied
    );
    append_line(&log_path, &header);

    let handle = Arc::new(Mutex::new(AgentHandle {
        spec: spec.clone(),
        pid,
        state: AgentState::Running,
        started_at: now_secs(),
        exit_code: None,
        log_path: log_path.clone(),
        ring: VecDeque::new(),
        stdin,
    }));

    if !app.insert(spec.name.clone(), handle.clone()) {
        let _ = cgroup::kill(&spec.name, pid);
        return Err(format!("智能体 {} 已存在", spec.name));
    }

    // 接管 stdout/stderr。
    let mut reader_threads = Vec::new();
    if let Some(out) = child.stdout.take() {
        reader_threads.push(spawn_reader(handle.clone(), out, log_path.clone()));
    }
    if let Some(err) = child.stderr.take() {
        reader_threads.push(spawn_reader(handle.clone(), err, log_path.clone()));
    }

    let info = match handle.lock() {
        Ok(h) => h.info(),
        Err(p) => p.into_inner().info(),
    };

    // 监控线程。
    let app2 = app.clone();
    let handle2 = handle.clone();
    thread::spawn(move || {
        monitor(app2, handle2, child, log_path, reader_threads);
    });

    app.log(format!("智能体 {} 已启动 pid={pid}", spec.name));
    Ok(info)
}

fn spawn_reader(
    handle: SharedAgent,
    pipe: impl std::io::Read + Send + 'static,
    log_path: PathBuf,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let reader = BufReader::new(pipe);
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let stamped = format!("[{}] {}", now_secs(), line);
            append_line(&log_path, &stamped);
            if let Ok(mut h) = handle.lock() {
                h.push_line(line);
            }
        }
    })
}

fn append_line(path: &PathBuf, line: &str) {
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{line}");
    }
}

fn monitor(
    app: Arc<App>,
    handle: SharedAgent,
    mut child: Child,
    log_path: PathBuf,
    readers: Vec<thread::JoinHandle<()>>,
) {
    let mut restarts: u32 = 0;
    let mut readers = Some(readers);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let code = status.code();
                {
                    if let Ok(mut h) = handle.lock() {
                        h.exit_code = code;
                        // 退出码 0 视为正常退出，其余（含被信号杀死）标记为 failed，
                        // 便于 `shui-ctl agents` 一眼看出异常。
                        h.state = if code == Some(0) { AgentState::Exited } else { AgentState::Failed };
                        h.stdin = None;
                    }
                }
                append_line(
                    &log_path,
                    &format!("=== [{}] exit code={:?} ===", now_secs(), code),
                );
                if let Some(rs) = readers.take() {
                    for r in rs {
                        let _ = r.join();
                    }
                }
                cgroup::remove(&handle_spec_name(&handle));

                let restart = match handle.lock() {
                    Ok(h) => h.spec.restart,
                    Err(p) => p.into_inner().spec.restart,
                };
                if !restart {
                    app.log(format!("智能体 {} 退出 code={:?}", handle_spec_name(&handle), code));
                    return;
                }
                restarts += 1;
                if restarts > MAX_CONSECUTIVE_RESTARTS {
                    app.log(format!(
                        "智能体 {} 连续重启 {} 次，放弃",
                        handle_spec_name(&handle),
                        restarts
                    ));
                    if let Ok(mut h) = handle.lock() {
                        h.state = AgentState::Failed;
                    }
                    return;
                }
                let backoff = (1u64 << restarts.min(5)).min(MAX_RESTART_BACKOFF_SECS);
                app.log(format!(
                    "智能体 {} 将在 {}s 后重启（第 {} 次）",
                    handle_spec_name(&handle),
                    backoff,
                    restarts
                ));
                thread::sleep(Duration::from_secs(backoff));

                let spec = match handle.lock() {
                    Ok(h) => h.spec.clone(),
                    Err(p) => p.into_inner().spec.clone(),
                };
                app.remove(&spec.name);
                match spawn(&app, spec.clone()) {
                    Ok(_) => return,
                    Err(e) => {
                        app.log(format!("重启 {} 失败: {e}", spec.name));
                        return;
                    }
                }
            }
            Ok(None) => thread::sleep(POLL_INTERVAL),
            Err(e) => {
                app.log(format!("等待子进程失败: {e}"));
                return;
            }
        }
    }
}

fn handle_spec_name(h: &SharedAgent) -> String {
    match h.lock() {
        Ok(g) => g.spec.name.clone(),
        Err(p) => p.into_inner().spec.name.clone(),
    }
}

/// 终止智能体并等待其退出。
pub fn kill(app: &Arc<App>, name: &str) -> Result<AgentInfo, String> {
    let handle = app.get(name).ok_or_else(|| format!("智能体 {name} 不存在"))?;
    let pid = match handle.lock() {
        Ok(h) => h.pid,
        Err(p) => p.into_inner().pid,
    };
    if let Err(e) = cgroup::kill(name, pid) {
        app.log(format!("击杀 {name} 失败: {e}"));
        return Err(format!("击杀 {name} 失败: {e}"));
    }
    // 最多等 5 秒让监控线程刷新状态。
    for _ in 0..50 {
        let live = match handle.lock() {
            Ok(h) => h.state.is_live(),
            Err(p) => p.into_inner().state.is_live(),
        };
        if !live {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    let info = match handle.lock() {
        Ok(h) => h.info(),
        Err(p) => p.into_inner().info(),
    };
    app.log(format!("智能体 {name} 已终止"));
    Ok(info)
}

/// 从登记表移除（不杀进程），用于清理已退出的条目。
pub fn forget(app: &Arc<App>, name: &str) -> bool {
    app.remove(name).is_some()
}

/// 把一行输入写进智能体 stdin。
pub fn send(name: &str, handle: &SharedAgent, data: &str) -> Result<(), String> {
    let mut h = handle.lock().map_err(|_| "锁损坏".to_string())?;
    match h.stdin.as_mut() {
        Some(stdin) => {
            stdin
                .write_all(data.as_bytes())
                .map_err(|e| format!("写 {name} stdin 失败: {e}"))?;
            if !data.ends_with('\n') {
                stdin.write_all(b"\n").map_err(|e| e.to_string())?;
            }
            stdin.flush().map_err(|e| e.to_string())?;
            Ok(())
        }
        None => Err(format!("{name} 的 stdin 不可用（已退出或未接管）")),
    }
}

/// 取日志尾部。
pub fn tail(handle: &SharedAgent, lines: usize) -> Vec<String> {
    let h = match handle.lock() {
        Ok(h) => h,
        Err(p) => p.into_inner(),
    };
    let n = lines.min(h.ring.len());
    h.ring.iter().skip(h.ring.len() - n).cloned().collect()
}
