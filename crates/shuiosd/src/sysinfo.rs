//! 系统信息采集：全部来自 `/proc`、`/etc/os-release` 与 `statvfs`，
//! 不依赖任何外部命令（镜像里没有 coreutils 也能工作）。

use shuios_proto::SystemInfo;

fn read_trim(path: &str) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

/// 读取 `/etc/os-release` 的某个键。
fn os_release(key: &str) -> Option<String> {
    let text = std::fs::read_to_string("/etc/os-release").ok()?;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix(&format!("{key}=")) {
            return Some(rest.trim_matches('"').to_string());
        }
    }
    None
}

/// `/proc/meminfo` 里 (MemTotal, MemAvailable)。
fn meminfo() -> (u64, u64) {
    let mut total = 0u64;
    let mut avail = 0u64;
    if let Ok(text) = std::fs::read_to_string("/proc/meminfo") {
        for line in text.lines() {
            let mut it = line.split_whitespace();
            let key = it.next().unwrap_or("");
            let val: u64 = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
            let bytes = val.saturating_mul(1024);
            match key {
                "MemTotal:" => total = bytes,
                "MemAvailable:" => avail = bytes,
                _ => {}
            }
        }
    }
    (total, avail)
}

/// `/proc/uptime` 第一列。
fn uptime_secs() -> u64 {
    read_trim("/proc/uptime")
        .and_then(|s| s.split_whitespace().next().map(|v| v.to_string()))
        .and_then(|v| v.parse::<f64>().ok())
        .map(|f| f as u64)
        .unwrap_or(0)
}

/// `/proc/loadavg` 第一个值。
fn load1() -> f64 {
    read_trim("/proc/loadavg")
        .and_then(|s| s.split_whitespace().next().map(|v| v.to_string()))
        .and_then(|v| v.parse::<f64>().ok())
        .unwrap_or(0.0)
}

/// 根文件系统是否为只读挂载（判断不可变根是否生效）。
fn root_is_readonly() -> bool {
    use std::ffi::CString;
    unsafe {
        let path = CString::new("/").unwrap();
        let mut st: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(path.as_ptr(), &mut st) != 0 {
            return false;
        }
        (st.f_flag & libc::ST_RDONLY as libc::c_ulong) != 0
    }
}

/// 当前可用内存（字节），供模型挑选策略使用。
pub fn mem_available() -> u64 {
    meminfo().1
}

/// 汇总系统信息。
pub fn system_info(agents_total: usize, agents_running: usize) -> SystemInfo {
    let (mem_total, mem_avail) = meminfo();
    SystemInfo {
        hostname: read_trim("/proc/sys/kernel/hostname").unwrap_or_else(|| "shuios".to_string()),
        os_name: os_release("NAME").unwrap_or_else(|| "shuios".to_string()),
        os_version: os_release("VERSION").unwrap_or_else(|| shuios_proto::SHUIOS_VERSION.to_string()),
        kernel: read_trim("/proc/version").unwrap_or_else(|| "unknown".to_string()),
        arch: std::env::consts::ARCH.to_string(),
        uptime_secs: uptime_secs(),
        load1: load1(),
        mem_total_bytes: mem_total,
        mem_available_bytes: mem_avail,
        agents_running,
        agents_total,
        cgroup_v2: crate::cgroup::available(),
        immutable_root: root_is_readonly(),
    }
}
