//! 磁盘布局与槽位识别。
//!
//! shuios 的镜像固定四分区，且每个分区都有**固定的 PARTUUID**——
//! 这样内核和 GRUB 都用 `PARTUUID=` 定位，SATA/USB/NVMe 都一样，
//! 不会出现 `/dev/sda2` 猜错设备的问题。

/// ESP（EFI 系统分区）。
pub const PARTUUID_ESP: &str = "5b1e0a00-0000-4000-8000-0000000000e1";
/// 根分区 A。
pub const PARTUUID_ROOT_A: &str = "5b1e0a00-0000-4000-8000-0000000000a1";
/// 根分区 B。
pub const PARTUUID_ROOT_B: &str = "5b1e0a00-0000-4000-8000-0000000000b1";
/// 数据分区。
pub const PARTUUID_DATA: &str = "5b1e0a00-0000-4000-8000-0000000000d1";

/// ESP 的挂载点（只读根上由 fstab 挂载）。
pub const ESP_MOUNT: &str = "/boot/efi";
/// GRUB 环境块在 ESP 上的位置（与 GRUB 的 `$prefix/grubenv` 一致）。
pub const GRUBENV_PATH: &str = "/boot/efi/EFI/BOOT/grubenv";
/// 内核命令行。
pub const CMDLINE_PATH: &str = "/proc/cmdline";
/// udev 生成的 PARTUUID 符号链接目录。
pub const BY_PARTUUID: &str = "/dev/disk/by-partuuid";
/// 内核命令行里标记槽位的参数名。
pub const SLOT_CMDLINE_KEY: &str = "shuios.slot=";

/// 根分区槽位。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    /// 槽 A。
    A,
    /// 槽 B。
    B,
}

impl Slot {
    /// 命令行/配置里的短名。
    pub fn as_str(self) -> &'static str {
        match self {
            Slot::A => "a",
            Slot::B => "b",
        }
    }

    /// 另一个槽。
    pub fn other(self) -> Slot {
        match self {
            Slot::A => Slot::B,
            Slot::B => Slot::A,
        }
    }

    /// 该槽对应分区的 PARTUUID。
    pub fn partuuid(self) -> &'static str {
        match self {
            Slot::A => PARTUUID_ROOT_A,
            Slot::B => PARTUUID_ROOT_B,
        }
    }

    /// 该槽分区的设备路径（通过 PARTUUID 符号链接）。
    pub fn device_path(self) -> String {
        format!("{BY_PARTUUID}/{}", self.partuuid())
    }

    /// 从短名解析。
    pub fn parse(s: &str) -> Option<Slot> {
        match s.trim().to_ascii_lowercase().as_str() {
            "a" | "slot-a" | "root-a" => Some(Slot::A),
            "b" | "slot-b" | "root-b" => Some(Slot::B),
            _ => None,
        }
    }
}

/// 从内核命令行里取槽位标记（`shuios.slot=a`）。
pub fn parse_slot_from_cmdline(cmdline: &str) -> Option<Slot> {
    for token in cmdline.split_whitespace() {
        if let Some(rest) = token.strip_prefix(SLOT_CMDLINE_KEY) {
            return Slot::parse(rest);
        }
    }
    None
}

/// 当前运行在哪个槽。取不到时保守地认为是 A（镜像首启的默认）。
pub fn current_slot() -> Result<Slot, String> {
    let cmdline = std::fs::read_to_string(CMDLINE_PATH)
        .map_err(|e| format!("读取 {CMDLINE_PATH} 失败: {e}"))?;
    Ok(parse_slot_from_cmdline(&cmdline).unwrap_or(Slot::A))
}

/// 进程是否以 root 运行（升级要写块设备）。
pub fn is_root() -> bool {
    let Ok(status) = std::fs::read_to_string("/proc/self/status") else {
        return false;
    };
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("Uid:") {
            let first = rest.split_whitespace().next().unwrap_or("");
            return first == "0";
        }
    }
    false
}

/// 把 PARTUUID 解析成真实设备路径（跟随 udev 的符号链接）。
pub fn resolve_device(partuuid: &str) -> Result<std::path::PathBuf, String> {
    let link = format!("{BY_PARTUUID}/{partuuid}");
    std::fs::canonicalize(&link).map_err(|e| format!("找不到分区 {link}: {e}"))
}

/// 读取分区容量（字节）。
pub fn partition_size_bytes(dev: &std::path::Path) -> Result<u64, String> {
    let name = dev
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .ok_or_else(|| "设备路径没有文件名".to_string())?;
    let sysfs = format!("/sys/class/block/{name}/size");
    let text = std::fs::read_to_string(&sysfs).map_err(|e| format!("读取 {sysfs} 失败: {e}"))?;
    let sectors: u64 = text
        .trim()
        .parse()
        .map_err(|e| format!("解析 {sysfs} 失败: {e}"))?;
    Ok(sectors.saturating_mul(512))
}

/// 人类可读的容量。
pub fn size_human(n: u64) -> String {
    const U: [&str; 4] = ["B", "KiB", "MiB", "GiB"];
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slot_names_and_parsing() {
        assert_eq!(Slot::A.as_str(), "a");
        assert_eq!(Slot::B.as_str(), "b");
        assert_eq!(Slot::parse("a"), Some(Slot::A));
        assert_eq!(Slot::parse(" B "), Some(Slot::B));
        assert_eq!(Slot::parse("slot-a"), Some(Slot::A));
        assert_eq!(Slot::parse("root-b"), Some(Slot::B));
        assert_eq!(Slot::parse("c"), None);
        assert_eq!(Slot::parse(""), None);
    }

    #[test]
    fn slots_are_symmetric() {
        assert_eq!(Slot::A.other(), Slot::B);
        assert_eq!(Slot::B.other(), Slot::A);
        assert_eq!(Slot::A.other().other(), Slot::A);
    }

    #[test]
    fn partuuids_are_distinct() {
        let all = [PARTUUID_ESP, PARTUUID_ROOT_A, PARTUUID_ROOT_B, PARTUUID_DATA];
        for (i, a) in all.iter().enumerate() {
            for b in all.iter().skip(i + 1) {
                assert_ne!(a, b, "PARTUUID 不能重复: {a} vs {b}");
            }
            assert_eq!(a.len(), 36, "PARTUUID 必须是 36 字符的 UUID: {a}");
            assert!(a.contains('-'), "PARTUUID 必须带连字符");
        }
    }

    #[test]
    fn cmdline_with_slot_is_parsed() {
        let cmdline = "root=PARTUUID=5b1e0a00-0000-4000-8000-0000000000a1 ro rootfstype=squashfs rootwait shuios.slot=b console=ttyS0";
        assert_eq!(parse_slot_from_cmdline(cmdline), Some(Slot::B));
    }

    #[test]
    fn cmdline_without_slot_returns_none() {
        assert_eq!(parse_slot_from_cmdline("root=/dev/sda1 ro quiet"), None);
        assert_eq!(parse_slot_from_cmdline(""), None);
        // 参数名必须完整匹配，不能被 shuios.slotx 混淆
        assert_eq!(parse_slot_from_cmdline("shuios.slotx=a"), None);
        // 值非法时也不猜测
        assert_eq!(parse_slot_from_cmdline("shuios.slot=z"), None);
    }

    #[test]
    fn device_path_uses_partuuid_link() {
        assert_eq!(
            Slot::A.device_path(),
            format!("{BY_PARTUUID}/{PARTUUID_ROOT_A}")
        );
    }

    #[test]
    fn size_human_formats() {
        assert_eq!(size_human(512), "512 B");
        assert_eq!(size_human(1536), "1.5 KiB");
        assert_eq!(size_human(1024 * 1024), "1.0 MiB");
    }
}
