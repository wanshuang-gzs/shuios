#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
$SSH 'export PATH=/var/lib/shuios/pkg/bin:$PATH; shui-pkg installed; echo ---; ls /var/lib/shuios/pkg/bin 2>/dev/null; echo ---; tail -3 /tmp/shui-store.log 2>/dev/null'
