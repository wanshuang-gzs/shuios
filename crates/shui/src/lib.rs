//! # shui 的可测试核心
//!
//! 二进制入口在 `main.rs`。这里把可独立测试的部分抽成库：
//!
//! * [`render`]：终端排版
//!
//! 推理客户端与工具调用解析在 `shui-llm`（shuiosd 与 shui 共用）。

pub mod render;
