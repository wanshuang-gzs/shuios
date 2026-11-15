#!/bin/bash
# shui-pkg 端到端验证：仓库 → 列包 → 安装 → 运行 → 卸载 → MCP 工具。
#
# 注意：ssh 的非交互 shell 不会读 /etc/profile，所以每条命令前显式补 PATH，
# 否则会误判"命令不存在"（踩过一次）。
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

run() {
	echo
	echo "########## $* ##########"
	$SSH "export PATH=/var/lib/shuios/pkg/bin:\$PATH; $*"
}

run 'shui-pkg repo'
run 'shui-pkg list'
run 'shui-pkg installed; echo ---; which htop 2>/dev/null || echo "(htop 不在 PATH)"'

run 'shui-pkg install htop'
run 'shui-pkg installed; echo ---; ls -l /var/lib/shuios/pkg/bin/; echo ---; grep "pkg/mnt" /proc/mounts; echo ---; htop --version 2>&1 | head -2'

run 'shui-pkg install libcurl'
run 'curl --version 2>&1 | head -3; echo ---; ls /var/lib/shuios/pkg/mnt/libcurl/usr/lib/ 2>/dev/null | head'

run 'shui-pkg remove htop; echo ---; shui-pkg installed; echo ---; ls /var/lib/shuios/pkg/bin/; echo ---; grep -c "pkg/mnt" /proc/mounts'

run 'shui-ctl tools 2>&1 | grep pkg; echo ---; shui-ctl call pkg.list "{}" 2>&1 | head -6'

run 'df -h /var/lib/shuios | tail -1; du -sh /var/lib/shuios/pkg'
