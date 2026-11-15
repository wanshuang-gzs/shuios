//! # shuios-update — A/B 双根分区原子升级
//!
//! shuios 的系统本体是只读 squashfs。升级不是"就地改文件"，而是：
//!
//! ```text
//! 1. 把新的 rootfs.squashfs 整体写入**非活动**根分区
//! 2. 改写 ESP 上的 grubenv：slot=新槽，prev=旧槽，state=try
//! 3. 重启 → GRUB 把 state 改成 booting 并启动新槽
//! 4. 新系统正常启动到 multi-user 后，shuios-boot-ok 服务把 state 改成 ok
//! 5. 若第 4 步没发生（新系统起不来），下次开机 GRUB 看到 state=booting
//!    就知道上次没成功，自动回滚到 prev
//! ```
//!
//! 整个过程不需要计数器、不需要额外分区、不需要 packer，只靠一块
//! 1024 字节的 grubenv 和一个 GRUB 脚本。

mod grubenv;
mod slots;

use grubenv::GrubEnv;
use slots::Slot;

/// 内部状态：已提交。
const STATE_OK: &str = "ok";
/// 内部状态：刚写入新槽，等待首次启动。
const STATE_TRY: &str = "try";
/// 内部状态：GRUB 已经启动过新槽，等系统确认。
const STATE_BOOTING: &str = "booting";

const USAGE: &str = "\
shuios-update — shuios（氵系统）A/B 原子升级

用法:
  shuios-update status              查看当前槽位、grubenv 状态、分区容量
  shuios-update apply <镜像>        把 squashfs 写入非活动槽并设为下次启动
  shuios-update mark-boot-ok        标记当前槽启动成功（由 systemd 服务调用）
  shuios-update rollback            手动回滚到上一版本
  shuios-update slots               只列槽位与容量

说明:
  * 升级写的是块设备，需要 root
  * 镜像必须是 squashfs（和构建产物 rootfs.squashfs 一致）
  * 新系统若未能启动成功，下一次开机会自动回滚
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        print!("{USAGE}");
        std::process::exit(2);
    }
    let result = match args[0].as_str() {
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            return;
        }
        "-V" | "--version" | "version" => {
            println!(
                "shuios-update {} (shuios {})",
                env!("CARGO_PKG_VERSION"),
                shuios_proto::SHUIOS_VERSION
            );
            return;
        }
        "status" => cmd_status(),
        "slots" => cmd_slots(),
        "apply" | "upgrade" => match args.get(1) {
            Some(p) => cmd_apply(p),
            None => Err("用法: shuios-update apply <squashfs 镜像>".to_string()),
        },
        "mark-boot-ok" => cmd_mark_boot_ok(),
        "rollback" => cmd_rollback(),
        other => Err(format!("未知子命令 {other}\n\n{USAGE}")),
    };

    if let Err(e) = result {
        eprintln!("shuios-update: {e}");
        std::process::exit(1);
    }
}

// --------------------------------------------------------------------------
// 子命令
// --------------------------------------------------------------------------

fn cmd_status() -> Result<(), String> {
    let current = slots::current_slot()?;
    println!("当前槽位      {}", current.as_str().to_uppercase());
    println!("根分区设备    {}", slots::resolve_device(current.partuuid())
        .map(|p| p.display().to_string())
        .unwrap_or_else(|e| format!("（无法解析: {e}）")));

    match GrubEnv::load(slots::GRUBENV_PATH) {
        Ok(env) => {
            if env.is_empty() {
                println!("grubenv       {}（空，首次启动？）", slots::GRUBENV_PATH);
            } else {
                println!("grubenv       {}（{} 个变量）", slots::GRUBENV_PATH, env.len());
            }
            println!(
                "  下次启动槽  {}",
                env.get("shuios_slot").unwrap_or("（未设置）")
            );
            println!(
                "  上次提交槽  {}",
                env.get("shuios_prev").unwrap_or("（未设置）")
            );
            let state = env.get("shuios_state").unwrap_or("（未设置）");
            println!("  状态        {}（{}）", state, state_desc(state));
        }
        Err(e) => {
            println!("grubenv       读取失败: {e}");
            println!("              ESP 是否已挂载到 {} ？", slots::ESP_MOUNT);
        }
    }

    println!();
    println!("{:<8} {:<10} {:>12}  设备", "分区", "PARTUUID", "容量");
    let parts = [
        ("esp", slots::PARTUUID_ESP),
        ("root-a", slots::PARTUUID_ROOT_A),
        ("root-b", slots::PARTUUID_ROOT_B),
        ("data", slots::PARTUUID_DATA),
    ];
    for (label, uuid) in parts {
        match slots::resolve_device(uuid) {
            Ok(dev) => {
                let size = slots::partition_size_bytes(&dev)
                    .map(slots::size_human)
                    .unwrap_or_else(|_| "?".to_string());
                let mark = if label == format!("root-{}", current.as_str()) { "*" } else { " " };
                println!(
                    "{}{:<7} {:<10} {:>12}  {}",
                    mark,
                    label,
                    short_uuid(uuid),
                    size,
                    dev.display()
                );
            }
            Err(e) => println!(" {:<7} {:<10} {:>12}  （{e}）", label, short_uuid(uuid), "-"),
        }
    }
    Ok(())
}

fn cmd_slots() -> Result<(), String> {
    for (label, uuid) in [
        ("esp", slots::PARTUUID_ESP),
        ("root-a", slots::PARTUUID_ROOT_A),
        ("root-b", slots::PARTUUID_ROOT_B),
        ("data", slots::PARTUUID_DATA),
    ] {
        match slots::resolve_device(uuid) {
            Ok(dev) => {
                let size = slots::partition_size_bytes(&dev)
                    .map(slots::size_human)
                    .unwrap_or_else(|_| "?".to_string());
                println!("{:<7} {:>10}  {}", label, size, dev.display());
            }
            Err(e) => println!("{:<7} {:>10}  （{e}）", label, "?"),
        }
    }
    if let Ok(slot) = slots::current_slot() {
        println!("当前运行槽 {}", slot.as_str().to_uppercase());
        println!("对应设备   {}", slot.device_path());
    }
    Ok(())
}

fn cmd_apply(image: &str) -> Result<(), String> {
    if !slots::is_root() {
        return Err("升级需要 root 权限（要写块设备）".to_string());
    }

    let meta = std::fs::metadata(image).map_err(|e| format!("读取镜像 {image} 失败: {e}"))?;
    if !meta.is_file() {
        return Err(format!("{image} 不是普通文件"));
    }

    let current = slots::current_slot()?;
    let target = current.other();
    let device = slots::resolve_device(target.partuuid())?;
    let capacity = slots::partition_size_bytes(&device)?;

    if meta.len() > capacity {
        return Err(format!(
            "镜像 {} 大于槽 {} 的容量 {}（{}），拒绝写入",
            slots::size_human(meta.len()),
            target.as_str().to_uppercase(),
            slots::size_human(capacity),
            device.display()
        ));
    }

    println!(
        "写入  {} ({})  ->  槽 {} ({})",
        image,
        slots::size_human(meta.len()),
        target.as_str().to_uppercase(),
        device.display()
    );

    let mut input =
        std::fs::File::open(image).map_err(|e| format!("打开镜像失败: {e}"))?;
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .open(&device)
        .map_err(|e| format!("打开块设备 {} 失败: {e}", device.display()))?;

    let written = std::io::copy(&mut input, &mut output)
        .map_err(|e| format!("写入 {} 失败: {e}", device.display()))?;
    output
        .sync_all()
        .map_err(|e| format!("刷盘失败: {e}"))?;
    println!("已写入 {} 字节并刷盘", written);

    let mut env = load_or_default_env(current)?;
    env.set("shuios_prev", current.as_str());
    env.set("shuios_slot", target.as_str());
    env.set("shuios_state", STATE_TRY);
    save_env(&env)?;

    println!();
    println!("完成。执行 reboot 后将从槽 {} 启动。", target.as_str().to_uppercase());
    println!(
        "若新系统未能完成启动，下一次开机会自动回滚到槽 {}。",
        current.as_str().to_uppercase()
    );
    Ok(())
}

fn cmd_mark_boot_ok() -> Result<(), String> {
    let current = slots::current_slot()?;
    let mut env = load_or_default_env(current)?;
    // 只有当前槽确实已经"上线"才把 prev 指过去：
    // 如果 grubenv 里的 slot 是别的槽（例如刚升级还没重启），这里不应误提交。
    let env_slot = env.get("shuios_slot").unwrap_or("").to_string();
    if !env_slot.is_empty() && env_slot != current.as_str() {
        println!(
            "跳过：grubenv 的目标槽是 {}，但当前运行在 {}（尚未重启生效）",
            env_slot,
            current.as_str().to_uppercase()
        );
        return Ok(());
    }
    env.set("shuios_slot", current.as_str());
    env.set("shuios_prev", current.as_str());
    env.set("shuios_state", STATE_OK);
    save_env(&env)?;
    println!("槽 {} 启动成功，已提交。", current.as_str().to_uppercase());
    Ok(())
}

fn cmd_rollback() -> Result<(), String> {
    if !slots::is_root() {
        return Err("回滚需要 root 权限".to_string());
    }
    let mut env = GrubEnv::load(slots::GRUBENV_PATH).map_err(|e| {
        format!("读取 {} 失败: {e}（ESP 是否已挂载？）", slots::GRUBENV_PATH)
    })?;
    let prev = env
        .get("shuios_prev")
        .map(|s| s.to_string())
        .ok_or_else(|| "grubenv 里没有 shuios_prev，无法回滚".to_string())?;
    env.set("shuios_slot", &prev);
    env.set("shuios_state", STATE_OK);
    save_env(&env)?;
    println!("已回滚：下次从槽 {} 启动。", prev.to_uppercase());
    Ok(())
}

// --------------------------------------------------------------------------
// 辅助
// --------------------------------------------------------------------------

fn load_or_default_env(current: Slot) -> Result<GrubEnv, String> {
    match GrubEnv::load(slots::GRUBENV_PATH) {
        Ok(env) => Ok(env),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let mut env = GrubEnv::new();
            env.set("shuios_slot", current.as_str());
            env.set("shuios_prev", current.as_str());
            env.set("shuios_state", STATE_OK);
            Ok(env)
        }
        Err(e) => Err(format!(
            "读取 {} 失败: {e}（ESP 是否已挂载？）",
            slots::GRUBENV_PATH
        )),
    }
}

fn save_env(env: &GrubEnv) -> Result<(), String> {
    env.save(slots::GRUBENV_PATH).map_err(|e| {
        format!(
            "写 {} 失败: {e}（ESP 是否以读写方式挂载？）",
            slots::GRUBENV_PATH
        )
    })
}

fn state_desc(state: &str) -> &'static str {
    match state {
        STATE_OK => "已提交，稳定运行",
        STATE_TRY => "等待首次启动新槽",
        STATE_BOOTING => "尝试中：若本次未确认成功，下次开机自动回滚",
        _ => "未知状态",
    }
}

fn short_uuid(uuid: &str) -> String {
    // 只显示最后一段，表格里好看些
    uuid.rsplit('-').next().unwrap_or(uuid).to_string()
}
