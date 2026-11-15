#!/usr/bin/env bash
# 在构建主机（Linux / WSL2）上原生编译 Rust 组件，产物放进 br2-ext/artifacts/，
# 供 Buildroot 的 shuios-runtime 包安装。
#
# 为什么不交给 Buildroot 的 cargo 基础设施：shuios 的构建目标 x86_64 与构建主机
# 相同，原生编译 + Buildroot 打包更简单、更快，也更容易复现（不需要拉整套
# Rust 交叉工具链）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/br2-ext/artifacts"
mkdir -p "$OUT"

echo ">>> 编译 shuios Rust 组件（release，体积优先）"
cargo build --release --workspace

echo ">>> 安装到 $OUT"
for b in shuiosd shui shui-ctl shuios-update shuios-splash shui-pkg; do
    install -m 0755 "target/release/$b" "$OUT/$b"
done

echo
echo ">>> 产物："
ls -lh "$OUT" | sed 's/^/    /'
echo
echo "提示：接着运行  make build  或  make BR2_EXTERNAL=$(pwd)/br2-ext"
