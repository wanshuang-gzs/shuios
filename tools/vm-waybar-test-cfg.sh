#!/bin/bash
# 用可写分区的临时配置试 waybar：避开 locale 依赖，并确认各模块能画出来
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'mkdir -p /var/lib/shuios/wbtest
cat > /var/lib/shuios/wbtest/config <<"EOF"
{
  "layer": "top",
  "position": "bottom",
  "height": 44,
  "spacing": 6,
  "modules-left": ["custom/start", "wlr/taskbar"],
  "modules-center": [],
  "modules-right": ["custom/sys", "custom/clock"],
  "custom/start": {
    "exec": "printf ⊙",
    "interval": "once",
    "on-click": "/usr/bin/shui-panel --menu",
    "tooltip": false
  },
  "wlr/taskbar": {
    "format": "{icon}",
    "icon-size": 22,
    "icon-theme": "hicolor",
    "tooltip-format": "{title}",
    "on-click": "activate",
    "on-click-middle": "close",
    "on-click-right": "close"
  },
  "custom/sys": {
    "exec": "/usr/bin/shui-ctl bar --text",
    "interval": 5,
    "format": "{}",
    "tooltip": false
  },
  "custom/clock": {
    "exec": "date +%H:%M",
    "interval": 20,
    "format": "{}",
    "tooltip": false
  }
}
EOF
cp /etc/xdg/waybar/style.css /var/lib/shuios/wbtest/style.css
echo "配置写好"

pkill -x waybar; sleep 1
D=$(ls /run/shuios/compositor | grep -m1 "^wayland-")
export XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
	DBUS_SESSION_BUS_ADDRESS=$(/usr/bin/dbus-daemon --session --fork --print-address)
	export DBUS_SESSION_BUS_ADDRESS
fi
nohup /usr/bin/waybar -c /var/lib/shuios/wbtest/config -s /var/lib/shuios/wbtest/style.css -l info >/tmp/wb-test.log 2>&1 &
sleep 5
pgrep -x waybar >/dev/null && echo "waybar 存活" || echo "waybar 退出"
echo "--- 日志 ---"
grep -E "error|warning|Disabling|Bar configured" /tmp/wb-test.log | tail -6
'
