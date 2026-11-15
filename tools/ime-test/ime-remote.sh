#!/bin/bash
# 在 VM 内运行（root）：验证 fcitx5 + Rime 的中文输入链路。
#
# 用法：ime-remote.sh text | browser-start | browser-type
#   text           跑 foot（text-input-v3）与 GTK（immodule）两条链路的自动验证
#   browser-start  用 shui-browser 打开测试页（宿主机随后抓 VNC 截图）
#   browser-type   往浏览器输入框里注入 nihao+space（宿主机再抓一张截图）
#
# VMware 的 VNC 只读，所以键盘注入用 /tmp/vkbd-inject（zwp_virtual_keyboard_v1）。
set -u

XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/shuios/compositor}
export XDG_RUNTIME_DIR
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    wl=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | head -1)
    WAYLAND_DISPLAY=$(basename "$wl")
    export WAYLAND_DISPLAY
fi
export XDG_CONFIG_HOME=/var/lib/shuios/config
export XDG_DATA_HOME=/var/lib/shuios/data
export GTK_IM_MODULE=fcitx
export GTK_IM_MODULE_FILE=/etc/shuios/gtk-immodules.cache
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export INPUT_METHOD=fcitx

say() { echo "[ime] $*"; }

prepare() {
    [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || {
        say "找不到 Wayland socket：$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
        exit 1
    }
    pid=$(pgrep -f '^/usr/bin/fcitx5' | head -1)
    if [ -z "$pid" ]; then
        say "fcitx5 没在跑，日志："
        tail -30 /tmp/fcitx5.log 2>/dev/null
        exit 1
    fi
    DBUS_SESSION_BUS_ADDRESS=$(tr '\0' '\n' </proc/"$pid"/environ |
        sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
    export DBUS_SESSION_BUS_ADDRESS
    say "fcitx5 pid=$pid dbus=${DBUS_SESSION_BUS_ADDRESS:-<空>}"
}

wait_rime() {
    for _ in $(seq 1 90); do
        ls "$XDG_DATA_HOME"/fcitx5/rime/build/*.prism.bin >/dev/null 2>&1 && return 0
        sleep 1
    done
    say "Rime 部署 90 秒仍未完成；日志："
    tail -30 "$XDG_DATA_HOME/fcitx5/rime/rime.log" 2>/dev/null ||
        tail -30 /tmp/fcitx5.log
    return 1
}

hexcheck() {
    # 期望 UTF-8 你好 = e4bda0 e5a5bd
    local file=$1
    local hex
    hex=$(od -An -tx1 "$file" 2>/dev/null | tr -d ' \n')
    if [ "$hex" = "e4bda0e5a5bd" ]; then
        say "PASS $file = 你好 ($hex)"
        return 0
    fi
    say "FAIL $file = ${hex:-<无文件>}"
    return 1
}

cmd_text() {
    prepare
    say "profile:"
    sed -n 1,20p "$XDG_CONFIG_HOME/fcitx5/profile" 2>/dev/null
    say "immodule: $(ls -l /usr/lib/gtk-3.0/3.0.0/immodules/im-fcitx5.so 2>&1)"
    wait_rime || exit 1
    say "rime build: $(ls "$XDG_DATA_HOME/fcitx5/rime/build" | head -5 | tr '\n' ' ')"

    # 不手动激活：出厂 config 已设 ActiveByDefault=True，
    # 新窗口聚焦后应直接进入 Rime，这正是在验证出厂配置。
    say "current im: $(fcitx5-remote -n 2>&1) / state: $(fcitx5-remote 2>&1)"

    # ---- 1. foot：text-input-v3 → sway input-method → fcitx5 ----
    rm -f /tmp/ime-foot.txt
    foot sh -c 'read x; printf "%s" "$x" >/tmp/ime-foot.txt' \
        >/tmp/foot-test.log 2>&1 &
    footpid=$!
    sleep 2
    /tmp/vkbd-inject wait:800 nihao space enter
    sleep 1
    hexcheck /tmp/ime-foot.txt
    foot_rc=$?
    kill "$footpid" 2>/dev/null

    # ---- 2. GTK3 immodule：GTK → D-Bus → fcitx5（浏览器同路径）----
    rm -f /tmp/ime-gtk.txt
    /tmp/gtk-ime-test /tmp/ime-gtk.txt >/tmp/gtk-ime.log 2>&1 &
    gtkpid=$!
    sleep 2
    /tmp/vkbd-inject wait:800 nihao space enter
    sleep 1
    sed -n 1,10p /tmp/gtk-ime.log
    hexcheck /tmp/ime-gtk.txt
    gtk_rc=$?
    kill "$gtkpid" 2>/dev/null

    [ $foot_rc -eq 0 ] && [ $gtk_rc -eq 0 ] && say "RESULT PASS" || say "RESULT FAIL"
}

cmd_browser_start() {
    prepare
    cat >/tmp/ime.html <<'EOF'
<!doctype html>
<meta charset="utf-8">
<title>shuios IME test</title>
<style>
 body{font:28px sans-serif;background:#202124;color:#e8eaed;padding:40px}
 #v{font-size:56px;color:#8ab4f8;margin-top:32px;min-height:72px}
</style>
<input id="i" autofocus
       style="font-size:32px;width:80%;padding:12px"
       placeholder="在这里打中文 / type here">
<div id="v"></div>
<script>
  var i = document.getElementById('i');
  i.addEventListener('input', function () {
    document.getElementById('v').textContent = i.value;
    document.title = 'shuios IME: ' + i.value;
  });
  i.focus();
</script>
EOF
    shui-browser file:///tmp/ime.html >/tmp/shui-browser.log 2>&1 &
    sleep 4
    say "browser started"
}

cmd_browser_type() {
    prepare
    /tmp/vkbd-inject wait:500 nihao space
    sleep 1
    say "typed"
}

case "${1:-text}" in
text) cmd_text ;;
browser-start) cmd_browser_start ;;
browser-type) cmd_browser_type ;;
*) say "未知子命令 $1"; exit 2 ;;
esac
