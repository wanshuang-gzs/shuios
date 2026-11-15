#!/bin/bash
# 用可写分区试新版 waybar 外观（不重建镜像），验证后再固化
set -u
GW=$(ip route | awk '/^default/ {print $3; exit}')
SSH="sshpass -p shui ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p 10022 root@$GW"

$SSH 'mkdir -p /var/lib/shuios/wb2
cat > /var/lib/shuios/wb2/config <<"EOF"
{
  "layer": "top",
  "position": "bottom",
  "height": 40,
  "spacing": 0,
  "margin-bottom": 0,
  "modules-left": ["custom/start", "wlr/taskbar"],
  "modules-center": [],
  "modules-right": ["network", "cpu", "memory", "custom/clock", "custom/date"],

  "custom/start": {
    "exec": "printf ⊙",
    "interval": "once",
    "tooltip": false,
    "on-click": "/usr/bin/shui-panel --menu"
  },

  "wlr/taskbar": {
    "format": "{icon}",
    "icon-size": 20,
    "icon-theme": "hicolor",
    "tooltip-format": "{title}",
    "on-click": "activate",
    "on-click-middle": "close",
    "on-click-right": "close"
  },

  "network": {
    "interval": 10,
    "tooltip": false,
    "format-wifi": "wifi",
    "format-ethernet": "net",
    "format-linked": "net",
    "format-disconnected": "offline"
  },

  "cpu": { "interval": 5, "tooltip": false, "format": "cpu {}%" },
  "memory": { "interval": 5, "tooltip": false, "format": "mem {}%" },

  "custom/clock": { "exec": "date +%H:%M", "interval": 20, "format": "{}", "tooltip": false },
  "custom/date": { "exec": "date +%m-%d", "interval": 300, "format": "{}", "tooltip": false }
}
EOF
cat > /var/lib/shuios/wb2/style.css <<"EOF"
* {
	font-family: "WenQuanYi Zen Hei", "DejaVu Sans Mono", sans-serif;
	font-size: 12px;
	min-height: 0;
	border: none;
	border-radius: 0;
	box-shadow: none;
	text-shadow: none;
}

window#waybar {
	background-color: rgba(22, 26, 32, 0.92);
	color: #e6eaf0;
	border-top: 1px solid rgba(255, 255, 255, 0.06);
}

/* 开始按钮：主色圆角块 + ⊙ */
#custom-start {
	background-image: linear-gradient(160deg, #33b6df 0%, #1c86ab 100%);
	color: #06121a;
	font-size: 16px;
	min-width: 34px;
	margin: 5px 8px;
	padding: 0 6px;
	border-radius: 10px;
}

#custom-start:hover {
	background-image: linear-gradient(160deg, #4ac9f0 0%, #2597bd 100%);
}

/* 任务按钮 */
#taskbar button {
	background-color: transparent;
	color: #e6eaf0;
	margin: 4px 2px;
	padding: 0 9px;
	border-radius: 8px;
	border-bottom: 2px solid transparent;
}

#taskbar button:hover {
	background-color: rgba(255, 255, 255, 0.08);
}

#taskbar button.active {
	background-color: rgba(45, 174, 217, 0.18);
	border-bottom: 2px solid #2daed9;
}

/* 右侧系统信息：三个小胶囊 */
#network, #cpu, #memory {
	color: #98a2b0;
	background-color: rgba(255, 255, 255, 0.035);
	border-radius: 8px;
	margin: 7px 2px;
	padding: 0 9px;
}

#network:hover, #cpu:hover, #memory:hover {
	color: #e6eaf0;
	background-color: rgba(255, 255, 255, 0.08);
}

/* 时钟：时间粗、日期细 */
#custom-clock {
	color: #e6eaf0;
	font-size: 13px;
	font-weight: bold;
	padding: 0 2px 0 10px;
}

#custom-date {
	color: #98a2b0;
	font-size: 10px;
	padding: 0 10px 0 4px;
}
EOF
echo "写入完成"

pkill -x waybar; sleep 1
D=$(ls /run/shuios/compositor | grep -m1 "^wayland-")
export XDG_RUNTIME_DIR=/run/shuios/compositor WAYLAND_DISPLAY=$D
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
	DBUS_SESSION_BUS_ADDRESS=$(/usr/bin/dbus-daemon --session --fork --print-address)
	export DBUS_SESSION_BUS_ADDRESS
fi
nohup /usr/bin/waybar -c /var/lib/shuios/wb2/config -s /var/lib/shuios/wb2/style.css -l info >/tmp/wb2.log 2>&1 &
sleep 5
pgrep -x waybar >/dev/null && echo "waybar 存活" || echo "waybar 退出"
grep -E "error|warning|Disabling|Bar configured" /tmp/wb2.log | tail -5
'
