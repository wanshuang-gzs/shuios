//! GRUB 环境块（`grubenv`）的读写。
//!
//! A/B 升级的状态就存在这一块 1024 字节里，由 GRUB 和 shuios 双方读写：
//! GRUB 在启动时 `load_env` / `save_env`，`shuios-update` 在运行时改写它。
//!
//! 格式（与 `grub-editenv` 一致）：
//!
//! ```text
//! # GRUB Environment Block
//! shuios_slot=a
//! shuios_prev=a
//! shuios_state=ok
//! #################################### ... 填充到 1024 字节
//! ```
//!
//! 硬约束：**必须恰好 1024 字节**，否则 GRUB 会拒绝读取。

/// 环境块的固定大小。
pub const ENV_BLOCK_SIZE: usize = 1024;
/// 首行魔数。
pub const ENV_HEADER: &str = "# GRUB Environment Block";
/// 填充字节。
const PAD: u8 = b'#';

/// 一个有序的键值环境（保持写入顺序，便于人看）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GrubEnv {
    vars: Vec<(String, String)>,
}

impl GrubEnv {
    /// 空环境。
    pub fn new() -> Self {
        Self::default()
    }

    /// 取值。
    pub fn get(&self, key: &str) -> Option<&str> {
        self.vars
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// 设值（已存在则原位替换）。
    pub fn set(&mut self, key: &str, value: &str) {
        if let Some(entry) = self.vars.iter_mut().find(|(k, _)| k == key) {
            entry.1 = value.to_string();
        } else {
            self.vars.push((key.to_string(), value.to_string()));
        }
    }

    /// 键值对数量。
    pub fn len(&self) -> usize {
        self.vars.len()
    }

    /// 是否为空。
    pub fn is_empty(&self) -> bool {
        self.vars.is_empty()
    }

    /// 解析一个 1024 字节的环境块。
    pub fn parse(block: &[u8]) -> Result<Self, String> {
        if block.len() != ENV_BLOCK_SIZE {
            return Err(format!(
                "环境块必须是 {ENV_BLOCK_SIZE} 字节，实际 {} 字节",
                block.len()
            ));
        }
        let text = String::from_utf8_lossy(block);
        let mut lines = text.split('\n');
        let header = lines.next().unwrap_or("");
        if !header.starts_with(ENV_HEADER) {
            return Err(format!("环境块首行不是 {ENV_HEADER:?}"));
        }
        let mut env = Self::new();
        for line in lines {
            let line = line.trim_end_matches(['\r', ' ', '#']);
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            match line.split_once('=') {
                Some((k, v)) => {
                    if !k.is_empty() {
                        env.set(k, v);
                    }
                }
                None => continue,
            }
        }
        Ok(env)
    }

    /// 序列化成恰好 1024 字节。
    pub fn serialize(&self) -> Result<Vec<u8>, String> {
        let mut buf: Vec<u8> = Vec::with_capacity(ENV_BLOCK_SIZE);
        buf.extend_from_slice(ENV_HEADER.as_bytes());
        buf.push(b'\n');
        for (k, v) in &self.vars {
            if k.contains('=') || k.contains('\n') {
                return Err(format!("非法键名: {k:?}"));
            }
            if v.contains('\n') {
                return Err(format!("键 {k} 的值不能包含换行"));
            }
            if k.starts_with('#') {
                return Err(format!("键名不能以 # 开头: {k:?}"));
            }
            buf.extend_from_slice(k.as_bytes());
            buf.push(b'=');
            buf.extend_from_slice(v.as_bytes());
            buf.push(b'\n');
        }
        if buf.len() > ENV_BLOCK_SIZE {
            return Err(format!(
                "环境内容 {} 字节，超过 {ENV_BLOCK_SIZE} 字节上限",
                buf.len()
            ));
        }
        buf.resize(ENV_BLOCK_SIZE, PAD);
        Ok(buf)
    }

    /// 从磁盘读（文件必须恰好 1024 字节）。
    pub fn load(path: &str) -> std::io::Result<Self> {
        let data = std::fs::read(path)?;
        Self::parse(&data)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
    }

    /// 原地写回（不截断：GRUB 依赖固定 1024 字节）。
    pub fn save(&self, path: &str) -> std::io::Result<()> {
        use std::io::Write;
        let block = self
            .serialize()
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            // 明确关闭截断：GRUB 的 grubenv 必须始终是 1024 字节
            .truncate(false)
            .open(path)?;
        f.write_all(&block)?;
        f.sync_all()?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_is_exactly_one_block() {
        let mut env = GrubEnv::new();
        env.set("shuios_slot", "a");
        let block = env.serialize().unwrap();
        assert_eq!(block.len(), ENV_BLOCK_SIZE, "GRUB 要求恰好 1024 字节");
    }

    #[test]
    fn roundtrip_preserves_values() {
        let mut env = GrubEnv::new();
        env.set("shuios_slot", "b");
        env.set("shuios_prev", "a");
        env.set("shuios_state", "try");
        let block = env.serialize().unwrap();
        let back = GrubEnv::parse(&block).unwrap();
        assert_eq!(back.get("shuios_slot"), Some("b"));
        assert_eq!(back.get("shuios_prev"), Some("a"));
        assert_eq!(back.get("shuios_state"), Some("try"));
        assert_eq!(back, env);
    }

    #[test]
    fn header_matches_grub_expectation() {
        let block = GrubEnv::new().serialize().unwrap();
        assert!(block.starts_with(b"# GRUB Environment Block\n"));
        // 除首行与填充外不应有其它内容
        assert!(block[ENV_HEADER.len() + 1..].iter().all(|b| *b == PAD));
    }

    #[test]
    fn parse_ignores_padding() {
        let mut env = GrubEnv::new();
        env.set("a", "1");
        let block = env.serialize().unwrap();
        let back = GrubEnv::parse(&block).unwrap();
        assert_eq!(back.len(), 1);
        assert_eq!(back.get("a"), Some("1"));
    }

    #[test]
    fn parse_rejects_wrong_size_and_header() {
        assert!(GrubEnv::parse(&[0u8; 100]).is_err());
        let mut bad = vec![b'x'; ENV_BLOCK_SIZE];
        bad[0] = b'#';
        assert!(GrubEnv::parse(&bad).is_err(), "首行必须是 GRUB 魔数");
    }

    #[test]
    fn set_replaces_in_place() {
        let mut env = GrubEnv::new();
        env.set("k", "1");
        env.set("other", "2");
        env.set("k", "3");
        assert_eq!(env.len(), 2, "重复设置同一个键不应新增条目");
        assert_eq!(env.get("k"), Some("3"));
    }

    #[test]
    fn empty_env_is_empty() {
        let env = GrubEnv::new();
        assert!(env.is_empty());
        assert_eq!(env.get("k"), None);
        assert_eq!(env.len(), 0);
    }

    #[test]
    fn rejects_oversized_content() {
        let mut env = GrubEnv::new();
        env.set("big", &"x".repeat(ENV_BLOCK_SIZE));
        assert!(env.serialize().is_err(), "超过 1024 字节必须报错而不是静默截断");
    }

    #[test]
    fn rejects_illegal_keys_and_values() {
        let mut env = GrubEnv::new();
        env.set("bad=key", "v");
        assert!(env.serialize().is_err());

        let mut env = GrubEnv::new();
        env.set("#bad", "v");
        assert!(env.serialize().is_err());

        let mut env = GrubEnv::new();
        env.set("k", "line1\nline2");
        assert!(env.serialize().is_err());
    }

    #[test]
    fn file_roundtrip_keeps_block_size() {
        let dir = std::env::temp_dir().join("shuios-grubenv-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("grubenv");
        let path_s = path.to_str().unwrap().to_string();

        let mut env = GrubEnv::new();
        env.set("shuios_slot", "b");
        env.save(&path_s).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().len(), ENV_BLOCK_SIZE as u64);

        // 再写一次更短的内容，文件大小不能被截断
        let mut env2 = GrubEnv::new();
        env2.set("x", "y");
        env2.save(&path_s).unwrap();
        assert_eq!(std::fs::metadata(&path).unwrap().len(), ENV_BLOCK_SIZE as u64);
        let back = GrubEnv::load(&path_s).unwrap();
        assert_eq!(back.get("x"), Some("y"));

        let _ = std::fs::remove_file(&path);
    }
}
