#!/bin/sh
# 从当前状态继续构建：编译 Rust 组件 → 重新应用 defconfig → 继续 make。
#
# 两个必须注意的点（都踩过）：
#  1. 非交互 shell 不加载 ~/.cargo/env，要显式把 ~/.cargo/bin 加进 PATH
#  2. shuios-runtime 用 SITE_METHOD=local，Buildroot 只在首次同步时把
#     br2-ext/artifacts 复制进 output/build/；Rust 二进制后编出来的话，
#     必须删掉它的构建目录让它重新同步，否则报「缺少预编译二进制」
set -eu

ROOT=/root/shuios
BR="$ROOT/buildroot"

export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

cd "$ROOT"

echo ">>> 1/4 编译 Rust 组件"
if ! command -v cargo >/dev/null 2>&1; then
	# shellcheck disable=SC1091
	. "$HOME/.cargo/env"
fi
command -v cargo && cargo --version
./tools/build-rust.sh
echo "    artifacts:"
ls -1 "$ROOT/br2-ext/artifacts" | sed 's/^/      /'

echo ">>> 2/4 重新应用 defconfig 并清理 shuios-runtime 构建目录"
cd "$BR"
make -s BR2_EXTERNAL="$ROOT/br2-ext" shuios_x86_64_defconfig >/dev/null
rm -rf "$BR/output/build/shuios-runtime-"*
echo "    CXX=$(grep -c '^BR2_TOOLCHAIN_BUILDROOT_CXX=y' .config) MESA3D=$(grep -c '^BR2_PACKAGE_MESA3D=y' .config) LLAMA=$(grep -c '^BR2_PACKAGE_LLAMA_CPP=y' .config)"

echo ">>> 3/4 补预取源码"
"$ROOT/tools/fetch-deps.sh" 2>&1 | tail -n 3 || true

echo ">>> 4/4 继续构建（-j12）"
exec make -s BR2_EXTERNAL="$ROOT/br2-ext" \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12
