//! `shui-pkg` 命令行。
//!
//! 子命令：
//!   list / search / info / installed / install / remove / restore / update / repo
//!
//! `restore` 是开机钩子：按 `installed.json` 重新挂载所有已装包并重建软链，
//! 因为 `/run` 是 tmpfs，重启后挂载点会消失。

use shui_pkg::{Entry, Index, InstalledPkg, Paths};
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dry = args.iter().any(|a| a == "--dry-run" || a == "-n");
    // GUI（shui-store）用 TSV 读数，避免在 C 里解析 JSON
    let tsv = args.iter().any(|a| a == "--tsv");
    let words: Vec<String> = args
        .iter()
        .filter(|a| !a.starts_with('-'))
        .cloned()
        .collect();

    let cmd = words.first().map(|s| s.as_str()).unwrap_or("list");
    let rest = &words[1.min(words.len())..];

    let paths = Paths::default_state();
    let repo = shui_pkg::resolve_repo();

    let code = match run(cmd, rest, &paths, &repo, dry, tsv) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("shui-pkg: {e}");
            1
        }
    };
    std::process::exit(code);
}

fn run(
    cmd: &str,
    rest: &[String],
    paths: &Paths,
    repo: &str,
    dry: bool,
    tsv: bool,
) -> Result<(), String> {
    match cmd {
        "list" | "ls" => cmd_list(paths, repo, rest.first().map(|s| s.as_str()), tsv),
        "search" => cmd_list(paths, repo, Some(rest.join(" ").as_str()), tsv),
        "installed" => cmd_installed(paths),
        "info" => cmd_info(paths, repo, rest.first().ok_or("info 需要一个包名")?),
        "install" | "add" => {
            if rest.is_empty() {
                return Err("install 需要至少一个包名".to_string());
            }
            cmd_install(paths, repo, rest, dry)
        }
        "remove" | "rm" | "uninstall" => {
            if rest.is_empty() {
                return Err("remove 需要至少一个包名".to_string());
            }
            cmd_remove(paths, rest)
        }
        "restore" => cmd_restore(paths),
        "icons" => cmd_icons(paths, repo),
        "update" => cmd_update(paths, repo),
        "repo" => cmd_repo(paths, repo),
        "help" | "-h" | "--help" => {
            println!("{USAGE}");
            Ok(())
        }
        other => Err(format!("未知子命令 `{other}`（试试 help）")),
    }
}

const USAGE: &str = "\
shui-pkg — 氵系统 软件包管理器

用法：
  shui-pkg list [关键字]     列出仓库中的包（默认全部）
  shui-pkg search <关键字>   按名字/摘要/描述/分类搜索
  shui-pkg info <包名>       查看包详情
  shui-pkg installed         列出已安装的包
  shui-pkg install <包名>…   安装（自动解析依赖）
  shui-pkg remove <包名>…    卸载
  shui-pkg icons             把仓库图标缓存到本地（商店用来显示真图标）
  shui-pkg update            刷新仓库索引缓存
  shui-pkg restore           按清单重新挂载所有已装包（开机钩子）
  shui-pkg repo              显示仓库位置与连通性

选项：
  -n, --dry-run              只打印将要做什么，不落盘

包被装成「可写数据分区上的只读 squashfs 挂载点」：
  /var/lib/shuios/pkg/cache/<文件>.sqfs     ← 包文件
  /var/lib/shuios/pkg/mnt/<包名>            ← 挂载点（重启后由 restore 重建）
  /var/lib/shuios/pkg/bin/<可执行名>        ← 软链，已加进 PATH
";

fn load_index(paths: &Paths, repo: &str) -> Result<Index, String> {
    if let Some(idx) = paths.load_cached_index() {
        return Ok(idx);
    }
    let bytes = shui_pkg::read_repo_file(repo, "index.json")?;
    let idx = Index::parse(&bytes)?;
    paths.save_cached_index(&idx)?;
    Ok(idx)
}

fn mark<'a>(installed: &shui_pkg::Installed, entry: &'a Entry) -> String {
    if installed.get(&entry.name).is_some() {
        format!("[已装] {}", entry.name)
    } else {
        format!("      {}", entry.name)
    }
}

fn cmd_list(paths: &Paths, repo: &str, query: Option<&str>, tsv: bool) -> Result<(), String> {
    let idx = load_index(paths, repo)?;
    let installed = paths.load_installed();
    let q = query.unwrap_or("").trim();
    let hits: Vec<&Entry> = idx
        .packages
        .iter()
        .filter(|e| q.is_empty() || e.matches(q))
        .collect();
    if tsv {
        // 列：名字 版本 字节数 人类可读体积 摘要 是否已装 分类 图标
        //     展示名 开发者 是否精选 描述
        // 前 8 列保持不变（老版本 shui-store 只读这 8 列也不会错位）；
        // 后 4 列供新版商店画精选位和详情页。字段里的制表/换行一律压成空格，
        // 否则一行会被拆成两行（描述是多行文本）。
        for e in hits {
            println!(
                "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
                e.name,
                e.version,
                e.size,
                e.size_human(),
                tsv_field(&e.summary),
                if installed.get(&e.name).is_some() { 1 } else { 0 },
                e.categories.join(","),
                e.icon,
                tsv_field(e.display_name()),
                tsv_field(&e.developer),
                if e.featured { 1 } else { 0 },
                tsv_field(&e.description)
            );
        }
        return Ok(());
    }
    if hits.is_empty() {
        println!("仓库里没有匹配 `{q}` 的包（共 {} 个包）", idx.packages.len());
        return Ok(());
    }
    println!("仓库：{repo}");
    println!(
        "{:<24} {:<12} {:>10}  {}",
        "包名", "版本", "体积", "摘要"
    );
    for e in hits {
        println!(
            "{:<24} {:<12} {:>10}  {}",
            mark(&installed, e),
            e.version,
            e.size_human(),
            e.summary
        );
    }
    Ok(())
}

fn cmd_installed(paths: &Paths) -> Result<(), String> {
    let st = paths.load_installed();
    if st.packages.is_empty() {
        println!("还没有安装任何软件包。用 `shui-pkg list` 看看有什么可装的。");
        return Ok(());
    }
    println!("{:>3}  {:<16} {:<10} {:<20} 挂载点", "#", "包名", "版本", "安装时间");
    for (i, p) in st.packages.iter().enumerate() {
        println!(
            "{:>3}  {:<16} {:<10} {:<20} {}",
            i + 1,
            p.name,
            p.version,
            fmt_unix(p.installed_at),
            p.mount
        );
    }
    Ok(())
}

fn cmd_info(paths: &Paths, repo: &str, name: &str) -> Result<(), String> {
    let idx = load_index(paths, repo)?;
    let e = idx
        .find(name)
        .ok_or_else(|| format!("仓库里没有包 `{name}`"))?;
    let st = paths.load_installed();
    println!("名称    : {}", e.name);
    println!("版本    : {}", e.version);
    println!("摘要    : {}", e.summary);
    if !e.description.is_empty() {
        println!("描述    : {}", e.description);
    }
    println!("分类    : {}", if e.categories.is_empty() { "-".into() } else { e.categories.join(", ") });
    println!("体积    : {}", e.size_human());
    println!("文件    : {}", e.file);
    println!("SHA-256 : {}", if e.sha256.is_empty() { "(未签名)".into() } else { e.sha256.clone() });
    println!("依赖    : {}", if e.depends.is_empty() { "无".into() } else { e.depends.join(", ") });
    match st.get(&e.name) {
        Some(p) => println!("状态    : 已安装（{}，装在 {}）", fmt_unix(p.installed_at), p.mount),
        None => println!("状态    : 未安装"),
    }
    Ok(())
}

fn cmd_install(paths: &Paths, repo: &str, names: &[String], dry: bool) -> Result<(), String> {
    let idx = load_index(paths, repo)?;
    let mut st = paths.load_installed();

    // 先算出总顺序（含依赖），再逐个装
    let mut plan: Vec<String> = Vec::new();
    for name in names {
        for n in shui_pkg::resolve_order(&idx, name)? {
            if !plan.contains(&n) {
                plan.push(n);
            }
        }
    }

    for name in &plan {
        if st.get(name).is_some() {
            println!("· {name} 已安装，跳过");
            continue;
        }
        let entry = idx
            .find(name)
            .ok_or_else(|| format!("仓库里没有包 `{name}`"))?;
        println!(
            "→ 安装 {} {}（{}，SHA-256 {}）",
            entry.name,
            entry.version,
            entry.size_human(),
            short_sha(&entry.sha256)
        );
        if dry {
            continue;
        }
        let pkg = install_one(paths, repo, entry)?;
        st.packages.push(pkg);
        paths.save_installed(&st)?;
        println!("   ✓ {} 安装完成", entry.name);
    }

    if dry {
        println!("（--dry-run：没有真的安装）");
    }
    Ok(())
}

fn install_one(paths: &Paths, repo: &str, entry: &Entry) -> Result<InstalledPkg, String> {
    if entry.file.is_empty() {
        return Err(format!("包 {} 的索引缺少 file 字段", entry.name));
    }
    paths.prepare()?;

    // 1) 取包文件（缓存命中就不重复下载）
    let cache = paths.cache.join(&entry.file);
    if cache.exists() {
        match shui_pkg::verify_file(&cache, &entry.sha256, entry.size) {
            Ok(_) => println!("   使用缓存 {}", cache.display()),
            Err(e) => {
                println!("   缓存损坏（{e}），重新下载");
                let _ = std::fs::remove_file(&cache);
            }
        }
    }
    if !cache.exists() {
        println!("   下载 {} …", entry.file);
        let n = shui_pkg::fetch_repo_file(repo, &entry.file, &cache)?;
        println!("   {} 字节", n);
    }
    shui_pkg::verify_file(&cache, &entry.sha256, entry.size)?;

    // 2) 挂载
    let mount = paths.mounts.join(&entry.name);
    mount_readonly(&cache, &mount)?;

    // 3) 读包内元数据，建软链
    let meta_path = mount.join(".pkg/meta.json");
    let meta = match std::fs::read(&meta_path) {
        Ok(b) => shui_pkg::Meta::parse(&b),
        Err(e) => {
            let _ = umount(&mount);
            return Err(format!("包 {} 缺少 .pkg/meta.json：{e}", entry.name));
        }
    };

    let mut links = Vec::new();
    for rel in &meta.bins {
        let target = mount.join(rel);
        if !target.exists() {
            let _ = umount(&mount);
            return Err(format!("包内缺少可执行文件 {rel}"));
        }
        let name = Path::new(rel)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .ok_or_else(|| format!("可执行文件路径非法：{rel}"))?;
        let link = paths.bin.join(&name);
        if link.exists() || std::fs::symlink_metadata(&link).is_ok() {
            let _ = umount(&mount);
            return Err(format!(
                "{} 已存在（可能由别的包提供），拒绝覆盖",
                link.display()
            ));
        }
        write_bin_wrapper(&link, &mount, rel)?;
        links.push(link.to_string_lossy().to_string());
    }

    for rel in &meta.desktop {
        let target = mount.join(rel);
        if !target.exists() {
            continue;
        }
        let name = Path::new(rel)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| format!("{}.desktop", entry.name));
        let link = paths.applications.join(name);
        if std::fs::symlink_metadata(&link).is_ok() {
            let _ = std::fs::remove_file(&link);
        }
        // 桌面入口里的 Exec 也要走包装脚本，否则图形应用同样找不到包内私有库
        let body = std::fs::read_to_string(&target).unwrap_or_default();
        let rewritten = rewrite_desktop_exec(&body, &paths.bin);
        std::fs::write(&link, rewritten)
            .map_err(|e| format!("写桌面入口 {} 失败：{e}", link.display()))?;
        links.push(link.to_string_lossy().to_string());
    }

    Ok(InstalledPkg {
        name: entry.name.clone(),
        version: entry.version.clone(),
        file: entry.file.clone(),
        sha256: entry.sha256.clone(),
        mount: mount.to_string_lossy().to_string(),
        links,
        installed_at: now_secs(),
    })
}

fn cmd_remove(paths: &Paths, names: &[String]) -> Result<(), String> {
    let mut st = paths.load_installed();
    for name in names {
        let Some(pkg) = st.get(name).cloned() else {
            println!("· {name} 未安装，跳过");
            continue;
        };
        let mount = PathBuf::from(&pkg.mount);
        if is_mountpoint(&mount) {
            umount(&mount).map_err(|e| format!("卸载 {} 失败：{e}", mount.display()))?;
        }
        let _ = std::fs::remove_dir(&mount);
        for link in &pkg.links {
            let _ = std::fs::remove_file(link);
        }
        let cache = paths.cache.join(&pkg.file);
        let _ = std::fs::remove_file(&cache);
        st.remove(name);
        paths.save_installed(&st)?;
        println!("✓ 已卸载 {} {}", pkg.name, pkg.version);
    }
    Ok(())
}

/// 开机重建：按清单重新挂载 + 补软链。缺文件不会让整个开机失败。
fn cmd_restore(paths: &Paths) -> Result<(), String> {
    let st = paths.load_installed();
    if st.packages.is_empty() {
        println!("没有已安装的包，跳过 restore");
        return Ok(());
    }
    paths.prepare()?;
    let mut failures = 0;
    for pkg in &st.packages {
        let cache = paths.cache.join(&pkg.file);
        let mount = PathBuf::from(&pkg.mount);
        if !cache.exists() {
            eprintln!("! {} 的包文件不见了：{}", pkg.name, cache.display());
            failures += 1;
            continue;
        }
        if !is_mountpoint(&mount) {
            if let Err(e) = mount_readonly(&cache, &mount) {
                eprintln!("! 挂载 {} 失败：{e}", pkg.name);
                failures += 1;
                continue;
            }
        }
        // 包装脚本/桌面入口可能被清理掉（/var 是 tmpfs 时），逐个补
        let meta_path = mount.join(".pkg/meta.json");
        if let Ok(b) = std::fs::read(&meta_path) {
            let meta = shui_pkg::Meta::parse(&b);
            for rel in &meta.bins {
                let target = mount.join(rel);
                if let Some(name) = Path::new(rel).file_name() {
                    let link = paths.bin.join(name);
                    if std::fs::symlink_metadata(&link).is_err() && target.exists() {
                        let _ = write_bin_wrapper(&link, &mount, rel);
                    }
                }
            }
            for rel in &meta.desktop {
                let target = mount.join(rel);
                if let Some(name) = Path::new(rel).file_name() {
                    let link = paths.applications.join(name);
                    if std::fs::symlink_metadata(&link).is_err() && target.exists() {
                        let body = std::fs::read_to_string(&target).unwrap_or_default();
                        let _ = std::fs::write(&link, rewrite_desktop_exec(&body, &paths.bin));
                    }
                }
            }
        }
        println!("✓ {} 已恢复（{}）", pkg.name, mount.display());
    }
    if failures > 0 {
        return Err(format!("{failures} 个包恢复失败"));
    }
    Ok(())
}

/// 把索引里引用的图标下载到本地缓存目录（`<状态目录>/icons`）。
///
/// 商店是 C 写的，不实现 HTTP；它只从本地缓存目录读图。图标很小，
/// 每次同步都重新拉一遍并覆盖，避免仓库换了图标本地还是旧的。
fn cmd_icons(paths: &Paths, repo: &str) -> Result<(), String> {
    let idx = load_index(paths, repo)?;
    paths.prepare()?;
    let mut ok = 0usize;
    let mut failed = 0usize;
    for e in &idx.packages {
        if e.icon.trim().is_empty() {
            continue;
        }
        // 只取文件名：防止索引里写 `../` 之类跳出图标目录
        let Some(base) = Path::new(&e.icon)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
        else {
            continue;
        };
        let dest = paths.icons.join(&base);
        match shui_pkg::read_repo_file(repo, &format!("icons/{base}")) {
            Ok(bytes) => {
                if let Err(err) = std::fs::write(&dest, bytes) {
                    eprintln!("! 写 {} 失败：{err}", dest.display());
                    failed += 1;
                } else {
                    ok += 1;
                }
            }
            Err(err) => {
                eprintln!("! {} 的图标不可用：{err}", e.name);
                failed += 1;
            }
        }
    }
    if failed > 0 {
        println!("图标已缓存 {ok} 个，{failed} 个失败");
    } else {
        println!("图标已缓存 {ok} 个");
    }
    Ok(())
}

fn cmd_update(paths: &Paths, repo: &str) -> Result<(), String> {
    println!("从 {repo} 拉取 index.json …");
    let bytes = shui_pkg::read_repo_file(repo, "index.json")?;
    let idx = Index::parse(&bytes)?;
    paths.save_cached_index(&idx)?;
    println!(
        "✓ 索引已更新：{} 个包，缓存到 {}",
        idx.packages.len(),
        paths.index.display()
    );
    Ok(())
}

fn cmd_repo(paths: &Paths, repo: &str) -> Result<(), String> {
    println!("仓库位置 : {repo}");
    println!("索引缓存 : {}{}", paths.index.display(), if paths.index.exists() { "" } else { "（未下载）" });
    println!("安装根   : {}", paths.root.display());
    match shui_pkg::read_repo_file(repo, "index.json") {
        Ok(_) => println!("连通性   : ✓ 可读取 index.json"),
        Err(e) => println!("连通性   : ✗ {e}"),
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

fn mount_readonly(sqfs: &Path, mount: &Path) -> Result<(), String> {
    if is_mountpoint(mount) {
        return Ok(());
    }
    std::fs::create_dir_all(mount).map_err(|e| format!("创建 {} 失败：{e}", mount.display()))?;
    let out = Command::new("mount")
        .arg("-o")
        .arg("loop,ro")
        .arg(sqfs)
        .arg(mount)
        .output()
        .map_err(|e| format!("执行 mount 失败：{e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(())
}

fn umount(mount: &Path) -> Result<(), String> {
    let out = Command::new("umount")
        .arg(mount)
        .output()
        .map_err(|e| format!("执行 umount 失败：{e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(())
}

fn is_mountpoint(path: &Path) -> bool {
    let mounts = std::fs::read_to_string("/proc/mounts").unwrap_or_default();
    shui_pkg::is_mounted(path, &mounts)
}

/// 生成一个可执行包装脚本，而不是软链。
///
/// 为什么不能只做软链：每个包自带私有运行库（`<挂载点>/usr/lib`），
/// 但这些目录不在动态链接器的默认搜索路径里，根文件系统又是只读的、
/// 没法往 `/etc/ld.so.conf.d` 或 `/usr/lib` 写。所以入口必须是一层
/// 设置 `LD_LIBRARY_PATH` 的包装脚本。
fn write_bin_wrapper(link: &Path, mount: &Path, rel: &str) -> Result<(), String> {
    let script = format!(
        "#!/bin/sh\n\
         # 由 shui-pkg 生成：把包内私有运行库加进动态链接器的搜索路径\n\
         PKGROOT='{}'\n\
         LD_LIBRARY_PATH=\"$PKGROOT/usr/lib:$PKGROOT/lib${{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}}\"\n\
         export LD_LIBRARY_PATH\n\
         exec \"$PKGROOT/{}\" \"$@\"\n",
        mount.display(),
        rel
    );
    std::fs::write(link, script)
        .map_err(|e| format!("写包装脚本 {} 失败：{e}", link.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(link, std::fs::Permissions::from_mode(0o755));
    }
    Ok(())
}

/// 把 `.desktop` 里的 `Exec=cmd args` 改成 `Exec=<包装脚本> args`。
fn rewrite_desktop_exec(body: &str, bindir: &Path) -> String {
    let mut out = String::with_capacity(body.len() + 64);
    for line in body.lines() {
        if let Some(rest) = line.strip_prefix("Exec=") {
            let mut parts = rest.splitn(2, char::is_whitespace);
            let cmd = parts.next().unwrap_or("").trim();
            let args = parts.next().unwrap_or("").trim();
            let name = Path::new(cmd)
                .file_name()
                .map(|s| s.to_string_lossy().to_string());
            if let Some(name) = name {
                let wrapper = bindir.join(&name);
                if wrapper.exists() {
                    out.push_str(&format!(
                        "Exec={}{}{}\n",
                        wrapper.display(),
                        if args.is_empty() { "" } else { " " },
                        args
                    ));
                    continue;
                }
            }
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// TSV 里的一格：制表符/换行会把一行拆成多行，统一压成空格。
fn tsv_field(s: &str) -> String {
    s.chars()
        .map(|c| if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c })
        .collect::<String>()
        .trim()
        .to_string()
}

fn short_sha(sha: &str) -> String {
    if sha.is_empty() {
        "(未签名)".to_string()
    } else if sha.len() > 12 {
        format!("{}…", &sha[..12])
    } else {
        sha.to_string()
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn fmt_unix(secs: u64) -> String {
    if secs == 0 {
        return "-".to_string();
    }
    let days = secs / 86400;
    let rem = secs % 86400;
    let (y, m, d) = civil_from_days(days as i64);
    format!("{y:04}-{m:02}-{d:02} {:02}:{:02}", rem / 3600, (rem % 3600) / 60)
}

/// 1970-01-01 起的天数 → (年, 月, 日)，Howard Hinnant 的算法。
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as i64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (y + if m <= 2 { 1 } else { 0 }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 日期换算() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(19_000), (2022, 1, 8));
        assert_eq!(fmt_unix(0), "-");
        assert_eq!(fmt_unix(1_700_000_000), "2023-11-14 22:13");
    }

    #[test]
    fn 摘要缩写() {
        assert_eq!(short_sha(""), "(未签名)");
        assert_eq!(short_sha("abcdef0123456789"), "abcdef012345…");
    }
}
