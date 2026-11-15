#!/bin/sh
# 检查虚拟机里的网络与 sshd 状态（从串口日志看）。
set -u
LOG=/tmp/shuios-serial.log
echo "===== 网卡 / DHCP ====="
grep -a -e "enp" -e "eth" -e "DHCP" -e "carrier" -e "10\.0\.2" "$LOG" | tail -12
echo
echo "===== sshd ====="
grep -a -i -e sshd -e "OpenSSH" -e "host key" -e "Server listening" "$LOG" | tail -10
echo
echo "===== 服务启动情况（后半段）====="
grep -a "Started" "$LOG" | tail -14
