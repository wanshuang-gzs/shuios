//! shuios 软件包管理器的核心逻辑。
//!
//! 设计要点（为什么不是 apt）：
//!
//! 1. **根文件系统只读**。系统本体是 squashfs，装软件不能往 `/usr` 里写，
//!    所以每个包被装成**可写数据分区上的一个只读 squashfs 挂载点**：
//!    `.sqfs` 落在 `/var/lib/shuios/pkg/cache/`，挂到
//!    `/var/lib/shuios/pkg/mnt/<名字>`。
//! 2. **每个包自带依赖闭包**，互不共享目录，因此不存在「装 A 破坏了 B」的
//!    经典包管理灾难；代价是磁盘占用略高（换来的是可以随便卸）。
//! 3. **可重放**：已装清单写在 `/var/lib/shuios/pkg/installed.json`，
//!    开机时 `shui-pkg restore` 按清单重新挂载并重建软链，重启不丢。
//! 4. **零第三方依赖**：sha256 与 HTTP GET 都是自己实现的（见同目录模块）。
//!
//! 单元测试只覆盖纯逻辑（索引解析、校验、路径推导），挂载需要 root 与内核支持。

pub mod http;
pub mod sha256;

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// 仓库默认位置：镜像里自带一份（离线可用）。
pub const DEFAULT_REPO: &str = "/usr/share/shuios/pkgrepo";
/// 状态目录默认位置（在可写数据分区上）。
pub const DEFAULT_STATE: &str = "/var/lib/shuios/pkg";
/// 配置文件名。
pub const CONF: &str = "/etc/shuios/pkgrepo.conf";
/// 数据分区上的覆盖配置：根分区是只读的，装完系统后想改仓库只能写这里。
pub const DATA_CONF: &str = "/var/lib/shuios/pkg/repo.conf";

// ---------------------------------------------------------------------------
// 仓库索引
// ---------------------------------------------------------------------------

/// 仓库索引 `index.json`。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Index {
    #[serde(default = "default_schema")]
    pub schema: u32,
    #[serde(default)]
    pub generated: String,
    #[serde(default)]
    pub packages: Vec<Entry>,
}

fn default_schema() -> u32 {
    1
}

/// 索引里的一个包。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub name: String,
    /// 展示名（例如 `QQ`、`微信`）。为空时退回 `name`。
    #[serde(default)]
    pub title: String,
    /// 厂商 / 开发者。
    #[serde(default)]
    pub developer: String,
    /// 是否在商店首页的精选位展示。
    #[serde(default)]
    pub featured: bool,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub categories: Vec<String>,
    /// 图标文件名（相对于仓库 `icons/` 目录）。
    #[serde(default)]
    pub icon: String,
    /// 包文件大小（字节）。
    #[serde(default)]
    pub size: u64,
    /// 包文件 SHA-256。
    #[serde(default)]
    pub sha256: String,
    /// 包文件名（相对仓库根）。
    #[serde(default)]
    pub file: String,
    /// 依赖包名（安装时按顺序解析）。
    #[serde(default)]
    pub depends: Vec<String>,
}

impl Entry {
    /// 展示名：优先 `title`，没填就用包名。
    pub fn display_name(&self) -> &str {
        if self.title.trim().is_empty() {
            &self.name
        } else {
            &self.title
        }
    }

    /// 关键字匹配：名字、摘要、描述、分类任一命中即算。
    pub fn matches(&self, query: &str) -> bool {
        let q = query.trim().to_lowercase();
        if q.is_empty() {
            return true;
        }
        let hay = format!(
            "{} {} {} {}",
            self.name,
            self.summary,
            self.description,
            self.categories.join(" ")
        )
        .to_lowercase();
        hay.contains(&q)
    }

    /// 人类可读的体积。
    pub fn size_human(&self) -> String {
        human_size(self.size)
    }
}

impl Index {
    pub fn parse(bytes: &[u8]) -> Result<Index, String> {
        serde_json::from_slice(bytes).map_err(|e| format!("索引不是合法 JSON：{e}"))
    }

    pub fn find(&self, name: &str) -> Option<&Entry> {
        self.packages.iter().find(|p| p.name == name)
    }
}

/// 包内的元数据 `/.pkg/meta.json`，决定要建哪些软链。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Meta {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub version: String,
    /// 可执行文件（相对包根，如 `usr/bin/jq`）。
    #[serde(default)]
    pub bins: Vec<String>,
    /// 桌面入口（相对包根，如 `usr/share/applications/x.desktop`）。
    #[serde(default)]
    pub desktop: Vec<String>,
}

impl Meta {
    /// 解析包内元数据。坏掉时退化成空元数据（不建软链），而不是让安装崩掉。
    pub fn parse(bytes: &[u8]) -> Meta {
        serde_json::from_slice(bytes).unwrap_or_default()
    }
}

// ---------------------------------------------------------------------------
// 已装状态
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Installed {
    #[serde(default = "default_schema")]
    pub schema: u32,
    #[serde(default)]
    pub packages: Vec<InstalledPkg>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstalledPkg {
    pub name: String,
    #[serde(default)]
    pub version: String,
    #[serde(default)]
    pub file: String,
    #[serde(default)]
    pub sha256: String,
    /// 挂载点。
    #[serde(default)]
    pub mount: String,
    /// 本次安装创建的软链（卸载时照单删除）。
    #[serde(default)]
    pub links: Vec<String>,
    /// 安装时间（Unix 秒）。
    #[serde(default)]
    pub installed_at: u64,
}

impl Installed {
    pub fn get(&self, name: &str) -> Option<&InstalledPkg> {
        self.packages.iter().find(|p| p.name == name)
    }
    pub fn remove(&mut self, name: &str) -> Option<InstalledPkg> {
        let idx = self.packages.iter().position(|p| p.name == name)?;
        Some(self.packages.remove(idx))
    }
}

// ---------------------------------------------------------------------------
// 目录布局
// ---------------------------------------------------------------------------

/// 状态目录下的固定布局。
#[derive(Debug, Clone)]
pub struct Paths {
    pub root: PathBuf,
    pub cache: PathBuf,
    pub bin: PathBuf,
    pub applications: PathBuf,
    pub mounts: PathBuf,
    pub icons: PathBuf,
    pub index: PathBuf,
    pub installed: PathBuf,
}

impl Paths {
    pub fn new(root: impl AsRef<Path>) -> Paths {
        let root = root.as_ref().to_path_buf();
        Paths {
            cache: root.join("cache"),
            bin: root.join("bin"),
            applications: root.join("share/applications"),
            mounts: root.join("mnt"),
            icons: root.join("icons"),
            index: root.join("index.json"),
            installed: root.join("installed.json"),
            root,
        }
    }

    pub fn default_state() -> Paths {
        Paths::new(DEFAULT_STATE)
    }

    /// 建好所有目录。返回第一个创建失败的路径（用于给出可读错误）。
    pub fn prepare(&self) -> Result<(), String> {
        for dir in [
            &self.root,
            &self.cache,
            &self.bin,
            &self.applications,
            &self.mounts,
            &self.icons,
        ] {
            std::fs::create_dir_all(dir).map_err(|e| format!("创建 {} 失败：{e}", dir.display()))?;
        }
        Ok(())
    }

    pub fn load_installed(&self) -> Installed {
        std::fs::read(&self.installed)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save_installed(&self, st: &Installed) -> Result<(), String> {
        self.prepare()?;
        let json = serde_json::to_vec_pretty(st).map_err(|e| e.to_string())?;
        std::fs::write(&self.installed, json)
            .map_err(|e| format!("写入 {} 失败：{e}", self.installed.display()))
    }

    pub fn load_cached_index(&self) -> Option<Index> {
        std::fs::read(&self.index)
            .ok()
            .and_then(|b| Index::parse(&b).ok())
    }

    pub fn save_cached_index(&self, idx: &Index) -> Result<(), String> {
        self.prepare()?;
        let json = serde_json::to_vec_pretty(idx).map_err(|e| e.to_string())?;
        std::fs::write(&self.index, json)
            .map_err(|e| format!("写入 {} 失败：{e}", self.index.display()))
    }
}

// ---------------------------------------------------------------------------
// 仓库位置解析
// ---------------------------------------------------------------------------

/// 解析仓库位置。优先级：
/// 环境变量 → 数据分区覆盖配置 → 镜像内配置 → 镜像内置仓库。
pub fn resolve_repo() -> String {
    if let Ok(v) = std::env::var("SHUIOS_PKGREPO") {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    for conf_path in [DATA_CONF, CONF] {
        if let Ok(conf) = std::fs::read_to_string(conf_path) {
            if let Some(v) = parse_conf_value(&conf, "repo") {
                return v;
            }
        }
    }
    DEFAULT_REPO.to_string()
}

/// 从 `key = value` / `key=value` 形式的配置里取值（忽略 `#` 注释）。
pub fn parse_conf_value(text: &str, key: &str) -> Option<String> {
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (k, v) = line.split_once('=')?;
        if k.trim() == key {
            let v = v.trim().trim_matches('"').trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// 仓库里的一个相对路径 → 可读取的字节。
pub fn read_repo_file(repo: &str, rel: &str) -> Result<Vec<u8>, String> {
    if repo.starts_with("http://") || repo.starts_with("https://") {
        http::get(&join_url(repo, rel))
    } else {
        let path = Path::new(repo).join(rel);
        std::fs::read(&path).map_err(|e| format!("读取 {} 失败：{e}", path.display()))
    }
}

/// 把仓库里的文件保存到本地（HTTP 直接流式写，本地仓库则复制）。
pub fn fetch_repo_file(repo: &str, rel: &str, dest: &Path) -> Result<u64, String> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("创建 {} 失败：{e}", parent.display()))?;
    }
    if repo.starts_with("http://") || repo.starts_with("https://") {
        http::download(&join_url(repo, rel), dest)
    } else {
        let src = Path::new(repo).join(rel);
        std::fs::copy(&src, dest)
            .map_err(|e| format!("复制 {} → {} 失败：{e}", src.display(), dest.display()))
    }
}

pub fn join_url(base: &str, rel: &str) -> String {
    format!("{}/{}", base.trim_end_matches('/'), rel.trim_start_matches('/'))
}

// ---------------------------------------------------------------------------
// 校验
// ---------------------------------------------------------------------------

/// 校验一个文件的体积与 SHA-256。返回计算出的摘要。
pub fn verify_file(path: &Path, expected_sha: &str, expected_size: u64) -> Result<String, String> {
    let data = std::fs::read(path).map_err(|e| format!("读取 {} 失败：{e}", path.display()))?;
    if expected_size != 0 && data.len() as u64 != expected_size {
        return Err(format!(
            "体积不符：期望 {} 字节，实际 {} 字节",
            expected_size,
            data.len()
        ));
    }
    let actual = sha256::digest(&data);
    if !expected_sha.is_empty() && !sha256::verify(expected_sha, &actual) {
        return Err(format!("SHA-256 不符：期望 {expected_sha}，实际 {actual}"));
    }
    Ok(actual)
}

/// 依赖闭包：按索引里的 `depends` 做深度优先后序遍历，返回安装顺序（依赖在前）。
/// 有环或缺失依赖时报错，不会静默跳过。
pub fn resolve_order(idx: &Index, want: &str) -> Result<Vec<String>, String> {
    fn visit(
        idx: &Index,
        name: &str,
        order: &mut Vec<String>,
        visiting: &mut Vec<String>,
    ) -> Result<(), String> {
        if order.iter().any(|n| n == name) {
            return Ok(());
        }
        if visiting.iter().any(|n| n == name) {
            return Err(format!("依赖成环：{name}"));
        }
        visiting.push(name.to_string());
        let entry = idx
            .find(name)
            .ok_or_else(|| format!("仓库里没有包 `{name}`"))?;
        for dep in &entry.depends {
            visit(idx, dep, order, visiting)?;
        }
        visiting.pop();
        order.push(name.to_string());
        Ok(())
    }

    let mut order = Vec::new();
    let mut visiting = Vec::new();
    visit(idx, want, &mut order, &mut visiting)?;
    Ok(order)
}

// ---------------------------------------------------------------------------
// 挂载
// ---------------------------------------------------------------------------

/// 某个路径是否已经是挂载点（读 `/proc/mounts`）。
pub fn is_mounted(mountpoint: &Path, mounts_text: &str) -> bool {
    let want = mountpoint.to_string_lossy();
    mounts_text.lines().any(|line| {
        // 字段用空格分隔，路径里的空格会被转义成 \040
        line.split_whitespace()
            .nth(1)
            .map(|m| m.replace("\\040", " ") == want)
            .unwrap_or(false)
    })
}

pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KiB", "MiB", "GiB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i + 1 < UNITS.len() {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{bytes} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn idx() -> Index {
        Index::parse(
            r#"{
                "schema": 1,
                "generated": "2026-10-19",
                "packages": [
                    {"name":"jq","version":"1.7.1","summary":"JSON 处理器","size":700000,
                     "sha256":"AA","file":"jq-1.7.1.sqfs","categories":["开发"]},
                    {"name":"htop","version":"3.3.0","summary":"进程查看器","size":200000,
                     "sha256":"BB","file":"htop-3.3.0.sqfs"}
                ]
            }"#
            .as_bytes(),
        )
        .expect("索引应当解析成功")
    }

    #[test]
    fn 解析索引并按名字查找() {
        let i = idx();
        assert_eq!(i.schema, 1);
        assert_eq!(i.packages.len(), 2);
        let jq = i.find("jq").expect("应当找到 jq");
        assert_eq!(jq.version, "1.7.1");
        assert_eq!(jq.size_human(), "683.6 KiB");
        assert!(i.find("nope").is_none());
    }

    #[test]
    fn 关键字匹配区分大小写不敏感() {
        let i = idx();
        let jq = i.find("jq").unwrap();
        assert!(jq.matches("JSON"));
        assert!(jq.matches("json"));
        assert!(jq.matches("开发"));
        assert!(jq.matches("  "));
        assert!(!jq.matches("process"));
    }

    #[test]
    fn 缺字段的索引不崩() {
        let minimal = Index::parse(br#"{"packages":[{"name":"x"}]}"#).unwrap();
        assert_eq!(minimal.schema, 1);
        assert_eq!(minimal.packages[0].size, 0);
        assert!(minimal.packages[0].depends.is_empty());
    }

    #[test]
    fn 坏索引报错而不是静默空仓库() {
        let err = Index::parse(b"{not json").unwrap_err();
        assert!(err.contains("JSON"), "错误信息应说明解析失败：{err}");
    }

    #[test]
    fn 配置文件取值() {
        let text = "# 仓库\nrepo = http://10.0.2.2:8099/repo\nother=1\n";
        assert_eq!(
            parse_conf_value(text, "repo").as_deref(),
            Some("http://10.0.2.2:8099/repo")
        );
        assert_eq!(parse_conf_value(text, "missing"), None);
        assert_eq!(parse_conf_value("repo=", "repo"), None);
    }

    #[test]
    fn url_拼接不会出现双斜杠() {
        assert_eq!(
            join_url("http://h:1/repo/", "/jq.sqfs"),
            "http://h:1/repo/jq.sqfs"
        );
        assert_eq!(join_url("http://h:1/repo", "jq.sqfs"), "http://h:1/repo/jq.sqfs");
    }

    #[test]
    fn 体积格式化() {
        assert_eq!(human_size(512), "512 B");
        assert_eq!(human_size(2048), "2.0 KiB");
        assert_eq!(human_size(5 * 1024 * 1024), "5.0 MiB");
    }

    #[test]
    fn 挂载点判定() {
        let mounts = "/dev/root / squashfs ro 0 0\n/dev/sda4 /var/lib/shuios ext4 rw 0 0\n\
                      /var/lib/shuios/pkg/cache/jq.sqfs /run/shuios/pkg/jq squashfs ro 0 0\n";
        assert!(is_mounted(Path::new("/run/shuios/pkg/jq"), mounts));
        assert!(is_mounted(Path::new("/var/lib/shuios"), mounts));
        assert!(!is_mounted(Path::new("/run/shuios/pkg/htop"), mounts));
        // 只是前缀相同不算挂载
        assert!(!is_mounted(Path::new("/run/shuios/pkg"), mounts));
    }

    #[test]
    fn 依赖顺序_依赖在前() {
        let i = Index::parse(
            br#"{"packages":[
                {"name":"app","depends":["lib","onig"]},
                {"name":"lib","depends":["onig"]},
                {"name":"onig"}
            ]}"#,
        )
        .unwrap();
        let order = resolve_order(&i, "app").unwrap();
        assert_eq!(order, vec!["onig", "lib", "app"]);
    }

    #[test]
    fn 依赖缺失要报错() {
        let i = Index::parse(br#"{"packages":[{"name":"app","depends":["ghost"]}]}"#).unwrap();
        let err = resolve_order(&i, "app").unwrap_err();
        assert!(err.contains("ghost"), "{err}");
    }

    #[test]
    fn 校验文件体积与摘要() {
        let dir = std::env::temp_dir().join("shui-pkg-test-verify");
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("data.bin");
        std::fs::write(&f, b"abc").unwrap();
        let sha = sha256::digest(b"abc");

        assert_eq!(verify_file(&f, &sha, 3).unwrap(), sha);
        assert!(verify_file(&f, "deadbeef", 3).unwrap_err().contains("SHA-256"));
        assert!(verify_file(&f, &sha, 4).unwrap_err().contains("体积"));
        // 摘要为空表示"只校验体积"
        assert!(verify_file(&f, "", 3).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn 状态增删() {
        let mut st = Installed::default();
        st.packages.push(InstalledPkg {
            name: "jq".into(),
            version: "1".into(),
            file: "jq.sqfs".into(),
            sha256: "x".into(),
            mount: "/run/shuios/pkg/jq".into(),
            links: vec!["/var/lib/shuios/pkg/bin/jq".into()],
            installed_at: 1,
        });
        assert!(st.get("jq").is_some());
        assert!(st.remove("jq").is_some());
        assert!(st.remove("jq").is_none());
        assert!(st.packages.is_empty());
    }
}
