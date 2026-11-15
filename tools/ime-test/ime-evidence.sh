#!/bin/bash
# 在 VM 内运行（root）：一次跑完 终端 + 浏览器 的中文输入取证，供人工截图。
#
# 用法：ime-evidence.sh        （VMware VNC 每 1 秒截一张即可拿到结果）
#
# 注意：浏览器窗口映射后要等（40 s），WebKit 的"可编辑焦点 → UI 进程输入法
# 过滤器"是异步的；注入太早就绕过输入法直落拉丁。
set -u
RT=/run/shuios/compositor
export XDG_RUNTIME_DIR=$RT
export WAYLAND_DISPLAY=$(basename $(ls $RT/wayland-* 2>/dev/null | head -1))
export SWAYSOCK=$(ls $RT/sway-ipc.* 2>/dev/null | head -1)
export XDG_CONFIG_HOME=/var/lib/shuios/config
export XDG_DATA_HOME=/var/lib/shuios/data
export GTK_IM_MODULE=fcitx
export GTK_IM_MODULE_FILE=/etc/shuios/gtk-immodules.cache
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
pid=$(pgrep -f '^/usr/bin/fcitx5' | head -1)
export DBUS_SESSION_BUS_ADDRESS=$(tr '\0' '\n' </proc/$pid/environ | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')

pkill -f shui-browser
sleep 1

# ---- 终端：完整提交一行，结果打印在屏幕上 ----
foot --title="终端 · 输入法验证" sh -c \
    'printf "请用拼音打中文…\n"; read x; printf "终端输入: %s\n" "$x"; sleep 300' \
    >/tmp/foot-show.log 2>&1 &
sleep 2
swaymsg '[app_id="foot"] focus' >/dev/null
sleep 1
/tmp/vkbd-inject wait:800 n i h a o space enter
sleep 1

# ---- 浏览器：起窗口后等 40 秒（WebKit 可编辑焦点 → UI 进程输入法过滤器就绪）----
shui-browser file:///tmp/ime.html >/tmp/shui-browser.log 2>&1 &
sleep 40
echo "before type: state=$(fcitx5-remote 2>&1) im=$(fcitx5-remote -n 2>&1)"
/tmp/vkbd-inject wait:800 n i h a o space
sleep 1
echo "after type:  state=$(fcitx5-remote 2>&1) im=$(fcitx5-remote -n 2>&1)"
echo "--- 窗口标题 ---"
swaymsg -t get_tree 2>/dev/null | grep -o '"name": "[^"]*"' | head -10
