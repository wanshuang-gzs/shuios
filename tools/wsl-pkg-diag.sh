#!/bin/bash
set -u
BR=/root/shuios/buildroot
echo "=== target 里的 jq/htop/tmux/nano ==="
for b in jq htop tmux nano; do
	if [ -e "$BR/output/target/usr/bin/$b" ]; then
		echo "$b: 存在 $(ls -l "$BR/output/target/usr/bin/$b" | awk '{print $5}')"
	else
		echo "$b: 不存在"
	fi
done
echo
echo "=== .config 相关开关 ==="
grep -E '^BR2_PACKAGE_(JQ|HTOP|TMUX|NANO)' "$BR/output/.config" || echo "(无)"
echo
echo "=== 当前镜像里的 jq ==="
ls -l "$BR/output/images/rootfs.squashfs" 2>/dev/null | awk '{print $5, $9}'
if [ -d /root/rootfs-mnt ]; then
	echo "(已有挂载点)"
fi
echo
echo "=== 包构建日志尾部 ==="
tail -n 12 /tmp/pkg-jq.log 2>/dev/null || echo "(无日志)"
