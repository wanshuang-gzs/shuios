#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 哪些单元在跑 weston ##########"
$SSH 'systemctl list-units --all --no-pager 2>/dev/null | grep -i weston'

echo
echo "########## 所有 weston 相关单元文件 ##########"
$SSH 'ls /usr/lib/systemd/system/ | grep -i weston; echo ---; grep -rl "weston" /etc/systemd/system/*/ 2>/dev/null | head'

echo
echo "########## 253 到底是哪个单元拉起来的 ##########"
$SSH 'tr "\0" "\n" < /proc/253/environ | grep -E "XDG_RUNTIME_DIR|INVOCATION|SYSTEMD_UNIT"; echo ---; cat /proc/253/cgroup'

echo
echo "########## 两个进程谁有 DRM master ##########"
$SSH 'ls -l /proc/253/fd 2>/dev/null | grep -c card0; ls -l /proc/267/fd 2>/dev/null | grep -c card0'
