#!/bin/sh
# shuios 桌面启动器：在 sway 会话里拉起常驻应用。
#
# 设计意图：这台机器开机后应该"已经可用"——终端里已经在跑 shui，
# 右边是软件商店，底部是任务栏。
#
# 幂等：每个应用启动前先看有没有在跑。这样即使脚本被重复执行
# （reload、手动重跑）也不会出现一叠同样的窗口。
set -u

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/shuios/compositor}"
RT="${XDG_RUNTIME_DIR}"

# shui-pkg 装的软件入口与桌面项：会话里的应用（foot/商店/启动器）都要能看见
export PATH="/var/lib/shuios/pkg/bin:${PATH:-/usr/bin:/bin}"
export XDG_DATA_DIRS="/var/lib/shuios/pkg/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"

# 等 Wayland socket 就绪（最多 6 秒）。socket 名可能是 wayland-0 或 wayland-1，
# 取决于运行目录里已有哪些锁文件，所以用通配而不是写死 wayland-0。
i=0
WSOCK=""
while [ "$i" -lt 30 ]; do
	WSOCK=$(ls "$RT"/wayland-? 2>/dev/null | head -1)
	[ -n "$WSOCK" ] && break
	i=$((i + 1))
	sleep 0.2
done
# waybar/GTK 默认连 wayland-0；socket 实际是 wayland-1 时它们会
# "cannot open display" 直接退（踩过），所以显式导出探测到的那个。
if [ -n "$WSOCK" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	export WAYLAND_DISPLAY=$(basename "$WSOCK")
fi

# ---- 会话环境 ------------------------------------------------------------
# 起一个 session D-Bus：waybar（以及以后的托盘/通知）需要它。
# 没有 DBUS_SESSION_BUS_ADDRESS 时 waybar 会直接报
# "Cannot autolaunch D-Bus without X11 $DISPLAY" 然后退出。
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
	ADDR=$(/usr/bin/dbus-daemon --session --fork --print-address 2>/dev/null)
	if [ -n "$ADDR" ]; then
		export DBUS_SESSION_BUS_ADDRESS="$ADDR"
		echo "shuios-desktop: session bus $ADDR" >&2
	fi
fi

# 已经在跑就不重复启动；$1 = 匹配用的进程名片段
running() {
	pgrep -f "$1" >/dev/null 2>&1
}

# ---- 输入法：fcitx5 + Rime -------------------------------------------------
# 出厂配置只在首次运行时灌入；之后用户改过的不会被覆盖。
# 配置/数据目录由 shuios-session 通过 XDG_CONFIG_HOME / XDG_DATA_HOME
# 指到数据分区（/root 是 tmpfs 且 ProtectSystem=strict 下只读）。
FCITX_CFG="${XDG_CONFIG_HOME:-/var/lib/shuios/config}/fcitx5"
FCITX_RIME="${XDG_DATA_HOME:-/var/lib/shuios/data}/fcitx5/rime"
if [ -d /usr/share/shuios/fcitx5 ]; then
	mkdir -p "$FCITX_CFG" "$FCITX_RIME"
	[ -f "$FCITX_CFG/profile" ] || \
		cp /usr/share/shuios/fcitx5/profile "$FCITX_CFG/profile" 2>/dev/null || true
	[ -f "$FCITX_CFG/config" ] || \
		cp /usr/share/shuios/fcitx5/config "$FCITX_CFG/config" 2>/dev/null || true
	[ -f "$FCITX_RIME/default.custom.yaml" ] || \
		cp /usr/share/shuios/fcitx5/default.custom.yaml \
			"$FCITX_RIME/default.custom.yaml" 2>/dev/null || true
fi
# 后台常驻，但不开 -d：留在会话进程树里，随桌面一起被 systemd 回收。
# --replace 让桌面服务重启时新实例接管旧实例，避免两个输入法抢键盘。
if [ -x /usr/bin/fcitx5 ] && ! running "fcitx5"; then
	( exec /usr/bin/fcitx5 --replace >>/tmp/fcitx5.log 2>&1 ) &
fi

# ---- 默认只启动任务栏 ----------------------------------------------------
# 以前这里无条件拉起终端 + 商店，结果是"开机就摆着两个窗口"，既不像 Windows
# （Windows 开机只有壁纸 + 任务栏），用户也没法把它们收起来。
# 现在默认只起任务栏；想开机就带应用时设 SHUIOS_AUTOSTART=full。
AUTOSTART="${SHUIOS_AUTOSTART:-panel}"

if [ "$AUTOSTART" = "full" ]; then
	# 1) 主终端：跑 shui（AI 原生 shell）
	if [ -x /usr/bin/foot ] && [ -x /usr/bin/shui ] && ! running "foot -e /usr/bin/shui"; then
		/usr/bin/foot --title="shui 氵" -e /usr/bin/shui &
	fi

	# 2) 软件商店（带日志 + 重试：开机阶段 GTK 偶尔会因为 locale 没就绪退一次）
	if [ -x /usr/bin/shui-store ] && ! running shui-store; then
		(
			for i in 1 2 3; do
				/usr/bin/shui-store >>/tmp/shui-store.log 2>&1 && break
				sleep 2
			done
		) &
	fi
fi

# 3) 文件管理器（终端里的 mc），只有显式要求才开
if [ "${SHUIOS_OPEN_MC:-0}" = "1" ] && [ -x /usr/bin/foot ] && [ -x /usr/bin/mc ]; then
	/usr/bin/foot --title="文件 · /workspace" -e /usr/bin/mc /workspace &
fi

# 4) 底部任务栏（shui-panel，layer-shell）：开始按钮 / 固定+运行中应用 /
#    AI 状态 / 时钟，全在这 40px 里。Windows 形态没有顶栏，原来的 waybar
#    菜单栏不再启动（软件包仍留在镜像里，需要时可手动起）。
#    shui-panel 自己申请 exclusive_zone=40，平铺窗口自动避开。
if [ -x /usr/bin/shui-panel ] && ! running "shui-panel$"; then
	( sleep 1; exec /usr/bin/shui-panel ) &
fi

# 让这个进程一直存活，方便 systemd 把整个会话作为一棵进程树管理
exec sleep infinity
