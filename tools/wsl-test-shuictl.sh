#!/bin/bash
# 跑 shui-ctl 的测试并把结果压缩成几行
set -u
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/shuios || exit 1
rsync -a /mnt/d/shuios/crates/ /root/shuios/crates/
cargo test -p shui-ctl --target x86_64-unknown-linux-gnu 2>&1 \
	| grep -E "test result|^error|panicked|swayipc" | head -12
