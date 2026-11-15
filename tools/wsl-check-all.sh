#!/bin/sh
# 综合检查：目标 rootfs 的安装情况 + 串口日志里的网络/自检信息。
# 全部用脚本写，避免 Windows 侧把 $T 之类变量吃掉。
set -u

T=/root/shuios/buildroot/output/target
LOG=/tmp/shuios-serial.log

echo "===== 1. shuios 运行时文件 ====="
ls -1 "$T/usr/libexec/shuios/" 2>/dev/null || echo "(目录不存在)"

echo
echo "===== 2. 开机启用的单元 ====="
ls -1 "$T/etc/systemd/system/multi-user.target.wants/" 2>/dev/null || echo "(无)"

echo
echo "===== 3. networkd 配置 ====="
ls -1 "$T/etc/systemd/network/" 2>/dev/null || echo "(无 network 目录)"
echo "--- 内容 ---"
for f in "$T"/etc/systemd/network/*; do
	[ -f "$f" ] || continue
	echo "[$f]"
	cat "$f"
done

echo
echo "===== 4. 串口日志里的网卡行 ====="
grep -a -e enp -e eth0 -e "e1000" "$LOG" 2>/dev/null | head -8 || echo "(无)"

echo
echo "===== 5. 串口日志里的自检段落 ====="
grep -a -n "开机自检" "$LOG" 2>/dev/null | head -3 || echo "(没有自检输出)"

echo
echo "===== 6. 串口日志大小 ====="
wc -c "$LOG" 2>/dev/null
