#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 挂载表（数据分区相关） ##########"
$SSH 'grep -E "sd[a-z][0-9]|shuios|workspace" /proc/mounts'

echo
echo "########## /workspace 与 /var/lib/shuios 的 df ##########"
$SSH 'df -h /workspace /var/lib/shuios /var 2>&1'

echo
echo "########## libcurl 包里到底有什么 ##########"
$SSH 'ls -l /var/lib/shuios/pkg/bin/; echo ---; ls -l /var/lib/shuios/pkg/mnt/libcurl/usr/bin/ 2>&1; echo ---; cat /var/lib/shuios/pkg/mnt/libcurl/.pkg/meta.json 2>&1'

echo
echo "########## 直接跑 curl ##########"
$SSH '/var/lib/shuios/pkg/mnt/libcurl/usr/bin/curl --version 2>&1 | head -4; echo "--- PATH=$PATH"'
