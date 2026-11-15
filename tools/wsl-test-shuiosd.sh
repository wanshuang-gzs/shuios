#!/bin/bash
set -u
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/shuios || exit 1
rsync -a /mnt/d/shuios/crates/ /root/shuios/crates/
cargo test -p shuiosd --target x86_64-unknown-linux-gnu 2>&1 | grep -E "test result|FAILED|panicked" | tail -6
