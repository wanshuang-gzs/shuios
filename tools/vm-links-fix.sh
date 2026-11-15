#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## links -dump（非交互能否渲染页面） ##########"
$SSH 'links -dump https://example.com 2>&1 | head -8'

echo
echo "########## links 需要什么终端能力（看它启动时的报错） ##########"
$SSH 'echo "" | links -dump https://example.com 2>&1 | tail -3'

echo
echo "########## 用 script 伪造 pty 跑一次交互模式 ##########"
$SSH 'command -v script || echo "(没有 script)"'
$SSH 'TERM=xterm-256color script -q -c "links https://example.com" /dev/null </dev/null 2>&1 | head -8'
