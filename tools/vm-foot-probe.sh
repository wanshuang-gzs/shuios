#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## foot 版本 ##########"
$SSH 'foot --version 2>&1 | head -3'

echo
echo "########## foot 支持哪些 ini 段（找 csd/decoration） ##########"
$SSH 'foot --print-pid 2>/dev/null; strings /usr/bin/foot 2>/dev/null | grep -iE "^\[csd\]|^preferred=|csd\." | head -10; echo "---"; strings /usr/bin/foot | grep -c "xdg_decoration"'

echo
echo "########## foot 的 man page 里有没有 csd ##########"
$SSH 'ls /usr/share/man/man5/foot.ini* 2>/dev/null; zcat /usr/share/man/man5/foot.ini.5.gz 2>/dev/null | grep -A6 -i "csd" | head -24'

echo
echo "########## 当前 sway 里 foot 的窗口规则/装饰 ##########"
$SSH 'grep -nE "foot|border|decoration" /etc/shuios/sway-config | head -12'
