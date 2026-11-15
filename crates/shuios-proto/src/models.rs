//! 本地模型仓库的挑选策略。
//!
//! shuios 的自述是"面向 AI 的 OS"，所以"该用哪个本地模型"必须是系统行为，
//! 而不是让用户每次手填路径。这里的规则刻意简单、可解释、可测试：
//!
//! 1. **只认 `.gguf`**：有其他格式（`.bin`/`.safetensors`）时一律让位；
//! 2. **优先能装下的最大模型**：能力通常随参数量增长，但装不下就等于不能用；
//! 3. **估算内存需求 = 文件大小 × 1.25**：KV cache 与运行余量的经验系数；
//! 4. **都装不下就挑最小的**：宁可慢一点，也要能起来；
//! 5. **同分时按名字排序**：保证结果确定，可复现。

use crate::ModelInfo;

/// 内存估算系数：文件大小 × 该系数 ≈ 实际需要的内存。
pub const MEMORY_OVERHEAD: f64 = 1.25;

/// 可用内存中允许被模型占用的比例。
pub const MEMORY_BUDGET_RATIO: f64 = 0.70;

/// 估算运行该模型需要的内存。
pub fn estimated_required_bytes(file_size: u64) -> u64 {
    (file_size as f64 * MEMORY_OVERHEAD) as u64
}

/// 在给定可用内存下，模型能否被容纳。
pub fn fits(model: &ModelInfo, mem_available: u64) -> bool {
    let budget = (mem_available as f64 * MEMORY_BUDGET_RATIO) as u64;
    estimated_required_bytes(model.size_bytes) <= budget
}

fn is_gguf(m: &ModelInfo) -> bool {
    m.name.to_ascii_lowercase().ends_with(".gguf")
}

/// 挑选默认模型；没有模型时返回 `None`。
pub fn pick_model(models: &[ModelInfo], mem_available: u64) -> Option<&ModelInfo> {
    if models.is_empty() {
        return None;
    }

    // 1. 优先 gguf；一个都没有才退回全部候选
    let ggufs: Vec<&ModelInfo> = models.iter().filter(|m| is_gguf(m)).collect();
    let pool: Vec<&ModelInfo> = if ggufs.is_empty() {
        models.iter().collect()
    } else {
        ggufs
    };

    // 2. 能装下的里面挑最大的；同大小时名字小的优先（保证确定性）
    let fitting: Vec<&&ModelInfo> = pool.iter().filter(|m| fits(m, mem_available)).collect();
    if !fitting.is_empty() {
        return fitting
            .iter()
            .max_by(|a, b| {
                a.size_bytes
                    .cmp(&b.size_bytes)
                    .then_with(|| b.name.cmp(&a.name))
            })
            .map(|m| **m);
    }

    // 3. 都装不下：挑最小的，至少能尝试
    pool.iter()
        .min_by(|a, b| {
            a.size_bytes
                .cmp(&b.size_bytes)
                .then_with(|| a.name.cmp(&b.name))
        })
        .copied()
}

/// 为挑选结果生成一句人话解释（给 `shui` / 日志用）。
pub fn explain(models: &[ModelInfo], mem_available: u64, picked: &ModelInfo) -> String {
    if models.is_empty() {
        return "模型仓库为空".to_string();
    }
    let need = estimated_required_bytes(picked.size_bytes);
    if fits(picked, mem_available) {
        format!(
            "选择 {}（{}，预计需要 {} MiB，可用 {} MiB）",
            picked.name,
            size_human(picked.size_bytes),
            need / 1024 / 1024,
            mem_available / 1024 / 1024
        )
    } else {
        format!(
            "没有模型能装进可用内存（预算 {} MiB），退回最小模型 {}（需 {} MiB）",
            (mem_available as f64 * MEMORY_BUDGET_RATIO) as u64 / 1024 / 1024,
            picked.name,
            need / 1024 / 1024
        )
    }
}

/// 人类可读的字节数。
pub fn size_human(n: u64) -> String {
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

#[cfg(test)]
mod tests {
    use super::*;

    fn model(name: &str, size_bytes: u64) -> ModelInfo {
        ModelInfo {
            name: name.to_string(),
            path: format!("/var/lib/shuios/models/{name}"),
            size_bytes,
        }
    }

    const MIB: u64 = 1024 * 1024;
    const GIB: u64 = 1024 * MIB;

    #[test]
    fn empty_repo_returns_none() {
        assert!(pick_model(&[], 8 * GIB).is_none());
    }

    #[test]
    fn single_model_is_picked() {
        let m = vec![model("a.gguf", GIB)];
        let picked = pick_model(&m, 8 * GIB).unwrap();
        assert_eq!(picked.name, "a.gguf");
    }

    #[test]
    fn prefers_largest_fitting_model() {
        // 可用 8GiB → 预算 5.6GiB；3GiB 模型需要 3.75GiB，装得下
        let models = vec![
            model("small.gguf", GIB),
            model("mid.gguf", 3 * GIB),
            model("huge.gguf", 12 * GIB),
        ];
        let picked = pick_model(&models, 8 * GIB).unwrap();
        assert_eq!(picked.name, "mid.gguf", "应在装得下的里面挑最大的");
    }

    #[test]
    fn falls_back_to_smallest_when_nothing_fits() {
        let models = vec![model("big.gguf", 20 * GIB), model("bigger.gguf", 30 * GIB)];
        let picked = pick_model(&models, 2 * GIB).unwrap();
        assert_eq!(picked.name, "big.gguf", "都装不下时挑最小的");
    }

    #[test]
    fn prefers_gguf_over_other_formats() {
        let models = vec![
            model("weights.safetensors", 4 * GIB),
            model("chat.gguf", GIB),
        ];
        let picked = pick_model(&models, 16 * GIB).unwrap();
        assert_eq!(picked.name, "chat.gguf", "gguf 优先，即使体积更小");
    }

    #[test]
    fn uses_non_gguf_when_no_gguf_present() {
        let models = vec![model("w.bin", 2 * GIB), model("v.bin", GIB)];
        let picked = pick_model(&models, 16 * GIB).unwrap();
        assert_eq!(picked.name, "w.bin");
    }

    #[test]
    fn ties_break_deterministically() {
        let models = vec![model("b.gguf", 2 * GIB), model("a.gguf", 2 * GIB)];
        let first = pick_model(&models, 16 * GIB).unwrap().name.clone();
        let models_rev = vec![model("a.gguf", 2 * GIB), model("b.gguf", 2 * GIB)];
        let second = pick_model(&models_rev, 16 * GIB).unwrap().name.clone();
        assert_eq!(first, second, "同分时必须确定性选择");
        assert_eq!(first, "a.gguf");
    }

    #[test]
    fn memory_estimate_has_overhead() {
        assert_eq!(estimated_required_bytes(4 * GIB), 5 * GIB);
        assert!(estimated_required_bytes(1) >= 1);
    }

    #[test]
    fn fits_respects_budget_ratio() {
        let m = model("m.gguf", 8 * GIB);
        // 需要 10GiB；可用 14GiB → 预算 9.8GiB → 装不下
        assert!(!fits(&m, 14 * GIB));
        // 可用 16GiB → 预算 11.2GiB → 装得下
        assert!(fits(&m, 16 * GIB));
    }

    #[test]
    fn explain_mentions_fallback() {
        let models = vec![model("huge.gguf", 30 * GIB)];
        let picked = pick_model(&models, 2 * GIB).unwrap();
        let text = explain(&models, 2 * GIB, picked);
        assert!(text.contains("退回最小模型"), "应说明退而求其次: {text}");
    }

    #[test]
    fn size_human_formats() {
        assert_eq!(size_human(512), "512 B");
        assert_eq!(size_human(1024), "1.0 KiB");
        assert_eq!(size_human(5 * GIB), "5.0 GiB");
    }
}
