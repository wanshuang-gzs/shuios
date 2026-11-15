#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"
$SSH 'for d in /sys/class/vtconsole/vtcon*; do echo "$d name=$(cat $d/name 2>/dev/null) bind=$(cat $d/bind 2>/dev/null)"; done; echo ---; ls -l /dev/dri/ 2>/dev/null'
