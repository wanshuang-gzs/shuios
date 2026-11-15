#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 1. 正在跑的是哪一份 panel ##########"
$SSH 'pgrep -af shui-panel'

echo
echo "########## 2. 两份二进制对比（镜像内 vs 可写分区） ##########"
$SSH 'for f in /usr/bin/shui-panel /var/lib/shuios/dev/shui-panel /usr/bin/shui-ctl /var/lib/shuios/dev/shui-ctl; do
	if [ -f "$f" ]; then printf "%-38s %8s  md5=%s\n" "$f" "$(stat -c%s $f)" "$(md5sum $f | cut -c1-8)"; else printf "%-38s (不存在)\n" "$f"; fi
done'

echo
echo "########## 3. 镜像里的 shui-ctl 支持 windows 吗（不支持=旧版） ##########"
$SSH '/usr/bin/shui-ctl windows 2>&1 | head -3'

echo
echo "########## 4. /var/lib/shuios 是不是持久分区 ##########"
$SSH 'grep " /var/lib/shuios " /proc/mounts; echo ---; df -h /var/lib/shuios | tail -1'
