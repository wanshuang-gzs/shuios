#!/bin/bash
# 在 WSL（shui-build）里跑：把验收工具推到 VM 并执行。
# 用法：ime-verify.sh <VM_IP> [text|browser-start|browser-type]
set -u
IP=${1:?用法: ime-verify.sh <VM_IP> [子命令]}
CMD=${2:-text}
CACHE=/mnt/d/shuios/.cache
export SSHPASS=${SSHPASS:-shui}

OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
sshpass -e scp $OPTS "$CACHE"/ime-test/vkbd-inject "$CACHE"/ime-test/gtk-ime-test \
	/mnt/d/shuios/tools/ime-test/ime-remote.sh "root@$IP:/tmp/" || exit 1
sshpass -e ssh $OPTS "root@$IP" "bash /tmp/ime-remote.sh $CMD"
