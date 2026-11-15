#!/bin/bash
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

echo "########## 窗口几何 ##########"
$SSH 'export SWAYSOCK=$(ls /run/shuios/compositor/sway-ipc.*.sock 2>/dev/null | head -1); swaymsg -t get_tree 2>/dev/null | python3 -c "
import json,sys
t=json.load(sys.stdin)
def walk(n,d=0):
    if n.get(\"type\") in (\"floating_con\",\"con\") and (n.get(\"name\") or n.get(\"app_id\")):
        r=n.get(\"rect\",{})
        if n.get(\"name\"):
            print(\"%-28s app_id=%-12s x=%4d y=%4d w=%4d h=%4d\" % (n.get(\"name\")[:28], n.get(\"app_id\"), r.get(\"x\",0), r.get(\"y\",0), r.get(\"width\",0), r.get(\"height\",0)))
    for c in n.get(\"nodes\",[])+n.get(\"floating_nodes\",[]):
        walk(c,d+1)
walk(t)
" 2>&1 | head -12'

echo
echo "########## 状态栏文本（看 markup 是否生效） ##########"
$SSH '/usr/bin/shui-ctl bar'

echo
echo "########## 字体是否真的装上了 ##########"
$SSH 'fc-list 2>/dev/null | grep -ci wqy; fc-match "WenQuanYi Zen Hei" 2>/dev/null'
