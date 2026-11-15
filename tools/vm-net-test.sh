#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 网络与 DNS ##########"
$SSH 'ip -4 addr show | grep -E "inet " | head -3; echo ---; cat /etc/resolv.conf 2>/dev/null | head -5'
echo
echo "########## 用 wget 抓一个页面（HTTP） ##########"
$SSH 'command -v wget || echo "(没有 wget)"; wget -qO- -T 8 http://example.com 2>&1 | head -6'
echo
echo "########## 用 wget 抓 HTTPS（看有没有 TLS 支持） ##########"
$SSH 'wget -qO- -T 8 https://example.com 2>&1 | head -3'
