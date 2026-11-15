//! 进程内共享状态。

use crate::config::Config;
use crate::supervisor::AgentHandle;
use shuios_proto::ai::{AiConfig, AiStatus};
use std::collections::HashMap;
use std::io;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

/// 单个智能体的共享句柄：监控线程与服务线程都通过它读写。
pub type SharedAgent = Arc<Mutex<AgentHandle>>;

/// 守护进程全局状态。
pub struct App {
    pub cfg: Config,
    pub ai: Mutex<AiConfig>,
    pub agents: Mutex<HashMap<String, SharedAgent>>,
    pub started_at: u64,
}

impl App {
    /// 新建全局状态。
    pub fn new(cfg: Config, ai: AiConfig) -> Self {
        Self {
            cfg,
            ai: Mutex::new(ai),
            agents: Mutex::new(HashMap::new()),
            started_at: now_secs(),
        }
    }

    /// 当前 AI 配置的副本（不含锁）。
    pub fn ai_config(&self) -> AiConfig {
        match self.ai.lock() {
            Ok(g) => g.clone(),
            Err(p) => p.into_inner().clone(),
        }
    }

    /// 可安全展示的 AI 状态。
    pub fn ai_status(&self) -> AiStatus {
        self.ai_config().status()
    }

    /// 替换 AI 配置（调用方负责先持久化）。
    pub fn set_ai_config(&self, cfg: AiConfig) {
        match self.ai.lock() {
            Ok(mut g) => *g = cfg,
            Err(p) => *p.into_inner() = cfg,
        }
    }

    /// 结构化日志：写入 stderr，由 systemd 收进 journal。
    pub fn log(&self, msg: impl AsRef<str>) {
        eprintln!("[{}] shuiosd: {}", now_secs(), msg.as_ref());
    }

    /// 确保运行所需目录存在。
    pub fn prepare_dirs(&self) -> io::Result<()> {
        for d in [&self.cfg.agent_log_dir, &self.cfg.model_dir, &self.cfg.state_dir] {
            std::fs::create_dir_all(d)?;
        }
        if let Some(parent) = Path::new(&self.cfg.socket).parent() {
            std::fs::create_dir_all(parent)?;
            // 运行目录权限交给 systemd 的 RuntimeDirectory，这里只兜底。
        }
        Ok(())
    }

    /// 列出全部智能体句柄的克隆（避免长时间持锁）。
    pub fn snapshot(&self) -> Vec<SharedAgent> {
        let map = match self.agents.lock() {
            Ok(m) => m,
            Err(p) => p.into_inner(),
        };
        map.values().cloned().collect()
    }

    /// 按名字取句柄。
    pub fn get(&self, name: &str) -> Option<SharedAgent> {
        let map = match self.agents.lock() {
            Ok(m) => m,
            Err(p) => p.into_inner(),
        };
        map.get(name).cloned()
    }

    /// 插入句柄；已存在同名则返回 false。
    pub fn insert(&self, name: String, agent: SharedAgent) -> bool {
        let mut map = match self.agents.lock() {
            Ok(m) => m,
            Err(p) => p.into_inner(),
        };
        if map.contains_key(&name) {
            return false;
        }
        map.insert(name, agent);
        true
    }

    /// 删除句柄。
    pub fn remove(&self, name: &str) -> Option<SharedAgent> {
        let mut map = match self.agents.lock() {
            Ok(m) => m,
            Err(p) => p.into_inner(),
        };
        map.remove(name)
    }

    /// 当前登记的智能体数量。
    pub fn count(&self) -> (usize, usize) {
        let snaps = self.snapshot();
        let total = snaps.len();
        let running = snaps
            .iter()
            .filter(|a| match a.lock() {
                Ok(h) => h.state.is_live(),
                Err(p) => p.into_inner().state.is_live(),
            })
            .count();
        (total, running)
    }
}

/// 当前 Unix 秒时间戳。
pub fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}
