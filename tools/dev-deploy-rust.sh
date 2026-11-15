#!/bin/bash
# 编译 Rust 组件并推到 VM 的可写分区，直接跑（不重打镜像）
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo ">>> 编译 Rust 工作区（增量）"
export PATH="$HOME/.cargo/bin:$PATH"
cd /root/shuios || exit 1
rsync -a /mnt/d/shuios/crates/ /root/shuios/crates/
if ! cargo build --release --workspace >/tmp/rust-dev.log 2>&1; then
	echo "!!! 编译失败"; grep -E "^error" /tmp/rust-dev.log | head -5; exit 1
fi
echo "    编译完成"

echo ">>> 推送到 VM"
for b in shui-ctl shuiosd shui shuios-update shuios-splash shui-pkg; do
	[ -f "target/release/$b" ] || continue
	cat "target/release/$b" | $SSH "mkdir -p /var/lib/shuios/dev && cat > /var/lib/shuios/dev/$b && chmod 0755 /var/lib/shuios/dev/$b" 2>/dev/null \
		&& echo "    ✓ $b"
done

echo ">>> 在 VM 里试跑 shui-ctl windows"
$SSH '/var/lib/shuios/dev/shui-ctl windows; echo "--- 退出码=$?"'
