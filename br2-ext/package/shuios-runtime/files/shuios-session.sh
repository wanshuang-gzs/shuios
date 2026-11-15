#!/bin/sh
# shuios 桌面会话入口（由 shuios-desktop.service 调用）。
#
# 默认合成器：swayfx（sway 1.12 + scenefx，GLES2 渲染）。
#   虚拟 GPU 走 kms_swrast/llvmpipe 软件 GL，真 GPU 自动走 i915/amdgpu。
#   SHUIOS_COMPOSITOR=weston 可切到救援合成器（无任务栏）。
#
# 统一用 seatd 拿 DRM seat（libseat 的 logind 后端对 system 服务不可用）。
set -u

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/shuios/compositor}"
export XDG_SESSION_TYPE=wayland
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# locale 由 post-build.sh 生成（C.UTF-8 / zh_CN.UTF-8 / en_US.UTF-8）。
# 不设的话默认是 C locale：GTK 报 "Locale not supported"，foot 直接拒绝启动。
export LANG="${LANG:-zh_CN.UTF-8}"

# 字体缓存要可写：根分区是只读 squashfs，不指到数据分区的话，
# fontconfig 每次查字体都会报 "No writable cache directories" 并且重新扫一遍全部字体
# （启动变慢，串口/日志被刷满）。
export XDG_CACHE_HOME=/var/lib/shuios/cache
mkdir -p "$XDG_CACHE_HOME" 2>/dev/null || true

# 用户配置与数据同样放数据分区：/root 是 64MB tmpfs（重启即丢），
# 而且 shuios-desktop.service 开了 ProtectSystem=strict，/root 实际只读。
# fcitx5 要写配置、Rime 要部署词典，都必须落在可写分区。
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/var/lib/shuios/config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-/var/lib/shuios/data}"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" 2>/dev/null || true

# fcitx5 启动时检查 HOME，为空直接 "Please set HOME." 退出；
# systemd 的 system 服务不注入 HOME，而 /root 只读，指向数据分区。
export HOME="${HOME:-/var/lib/shuios/home}"
mkdir -p "$HOME" 2>/dev/null || true

# ---- 输入法（fcitx5）----------------------------------------------------
# Wayland 应用（foot 等）走 text-input-v3 → 合成器 → fcitx5；
# GTK 应用走 fcitx5-gtk immodule + 会话 D-Bus。
# 根分区里没有 GTK 默认的 immodules.cache（Buildroot 不跑
# gtk-query-immodules），必须显式指向镜像里手写的那份。
export GTK_IM_MODULE=fcitx
export GTK_IM_MODULE_FILE=/etc/shuios/gtk-immodules.cache
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export SDL_IM_MODULE=fcitx
export INPUT_METHOD=fcitx

LOG="$XDG_RUNTIME_DIR/compositor.log"
SER=/dev/ttyS0
[ -w "$SER" ] || SER=/dev/console

say() {
	echo "shuios-session: $*" >&2
	echo "shuios-session: $*" >> "$SER" 2>/dev/null || true
}

# 会话 D-Bus：fcitx5 与 GTK immodule 之间靠它通信，waybar（托盘/通知）也需要。
# 必须在 exec sway 之前启动：sway 派生的应用（快捷键开的终端、菜单项）继承的是
# sway 的环境，之后再设置 DBUS_SESSION_BUS_ADDRESS 它们拿不到。
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -x /usr/bin/dbus-daemon ]; then
	ADDR=$(/usr/bin/dbus-daemon --session --fork --print-address 2>/dev/null)
	if [ -n "$ADDR" ]; then
		export DBUS_SESSION_BUS_ADDRESS="$ADDR"
		say "session bus $ADDR"
	fi
fi

# ---- 音频：PipeWire + WirePlumber ---------------------------------------
# 桌面是 system service，没有 user systemd，所以手动按顺序拉起：
#   pipewire（核心，建 pipewire-0 套接字）
#   → wireplumber（设备/策略管理，wpctl 依赖它）
#   → pipewire-pulse（PulseAudio 协议，GStreamer/WebKit 用 pulsesink 接）。
# 套接字都在 XDG_RUNTIME_DIR（/run/shuios/compositor）；会话退出时 systemd
# 的 KillMode=control-group 会把整棵进程树一并回收。
start_audio() {
	[ -x /usr/bin/pipewire ] || return 0
	# VMware 虚拟 HDA 的周期中断经常晚上一拍，内核会打印
	#   snd_hda_intel: IRQ timing workaround is activated ... Suggest a bigger bdl_pos_adj
	# 之后 DMA 指针几乎不推进，PipeWire/Chromium 的音频流就永远停在 0。
	# 按内核建议把第一张卡的 bdl_pos_adj 调到 32（必须在 pipewire 打开设备前写）。
	if [ -w /sys/module/snd_hda_intel/parameters/bdl_pos_adj ]; then
		echo 32 >/sys/module/snd_hda_intel/parameters/bdl_pos_adj 2>/dev/null &&
			say "snd_hda_intel bdl_pos_adj=32"
	fi
	/usr/bin/pipewire >>"$XDG_RUNTIME_DIR/audio.log" 2>&1 &
	i=0
	while [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ] && [ "$i" -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
		say "pipewire 已就绪"
	else
		say "pipewire 未就绪（没有 pipewire-0 套接字），音频将不可用"
	fi
	[ -x /usr/bin/wireplumber ] && \
		/usr/bin/wireplumber >>"$XDG_RUNTIME_DIR/audio.log" 2>&1 &
	[ -x /usr/bin/pipewire-pulse ] && \
		/usr/bin/pipewire-pulse >>"$XDG_RUNTIME_DIR/audio.log" 2>&1 &

	# 音量/静音由 shui-settings 和 shui-panel 写在数据分区：
	# WirePlumber 自己不会持久化默认 sink 的音量（每次冷启动回到 40%），
	# 所以这里等默认 sink 就绪后回放一次。
	AUDIO_STATE=/var/lib/shuios/state/audio.conf
	if [ -r "$AUDIO_STATE" ]; then
		vol=$(sed -n 's/^VOLUME=//p' "$AUDIO_STATE" | head -n1)
		mute=$(sed -n 's/^MUTE=//p' "$AUDIO_STATE" | head -n1)
		i=0
		while [ "$i" -lt 40 ]; do
			/usr/bin/wpctl get-volume @DEFAULT_AUDIO_SINK@ \
				>/dev/null 2>&1 && break
			sleep 0.25
			i=$((i + 1))
		done
		# WirePlumber 创建设备后还会补一次默认音量，稍等再写
		sleep 1
		case "$vol" in
			''|*[!0-9]*) ;;
			*) /usr/bin/wpctl set-volume @DEFAULT_AUDIO_SINK@ \
				"${vol}%" >>"$XDG_RUNTIME_DIR/audio.log" 2>&1 ;;
		esac
		case "$mute" in
			0|1) /usr/bin/wpctl set-mute @DEFAULT_AUDIO_SINK@ \
				"$mute" >>"$XDG_RUNTIME_DIR/audio.log" 2>&1 ;;
		esac
		say "回放音量 vol=${vol:-?} mute=${mute:-?}"
	fi
}
start_audio

if [ ! -e /dev/dri/card0 ]; then
	say "没有 /dev/dri/card0：无法启动图形会话（屏幕上不会有画面）"
	exit 1
fi

COMPOSITOR="${SHUIOS_COMPOSITOR:-sway}"
say "合成器=$COMPOSITOR  DRM=$(ls /dev/dri | tr '\n' ' ')"

# 后台定时把合成器日志打到串口，方便无头排障
(
	for i in 1 2 3; do
		sleep 8
		{
			echo "=== compositor.log 第 ${i} 次 dump ==="
			tail -n 40 "$LOG" 2>/dev/null || echo "(日志还没生成)"
		} >> "$SER" 2>/dev/null || true
	done
) &

case "$COMPOSITOR" in
	weston)
		say "exec weston（救援合成器，无任务栏）"
		exec /usr/bin/weston --backend=drm-backend.so --idle-time=0 --log="$LOG"
		;;
	*)
		# sway 在软件渲染（llvmpipe）下会提示 GPU 不受支持，
		# --unsupported-gpu 明确表示"我知道，继续跑"。
		# pixman：不依赖 EGL/GBM 的软件渲染后端。
		# QEMU 的 bochs 显卡没有专用 DRI 驱动，gles2 路径会失败；
		# 真机上把 WLR_RENDERER 设成 gles2 即可用硬件加速。
		# fbcon 会占着 DRM master，wlroots 拿不到就会报
		#   Could not make device fd drm master: Device or resource busy
		# 解绑帧缓冲控制台把 master 让出来（退出时再绑回去）。
		for vt in 0 1 2 3 4; do
			name=""
			[ -r "/sys/class/vtconsole/vtcon$vt/name" ] && name=$(cat "/sys/class/vtconsole/vtcon$vt/name" 2>/dev/null)
			case "$name" in
				*frame*|*fbcon*)
					if [ -w "/sys/class/vtconsole/vtcon$vt/bind" ]; then
						echo 0 > "/sys/class/vtconsole/vtcon$vt/bind" 2>/dev/null && \
							say "解绑 vtcon$vt（$name），让出 DRM master"
					fi
					;;
			esac
		done

		# 合成器是 swayfx：它的 fx renderer 自己接管场景渲染，只走 EGL/GLES2，
		# WLR_RENDERER 环境变量对它无效（所以这里不再强制 pixman）。
		# QEMU 的 bochs 显卡没有专用 DRI 驱动，由 mesa 的 kms_swrast
		# 软件 GL 兜底；真机上自动走 i915/iris。
		# 但 wlroots 默认拒绝软件渲染（Software rendering detected → 直接失败），
		# 必须显式允许；有硬件 GPU 时这一行没有任何副作用。
		export WLR_RENDERER_ALLOW_SOFTWARE=1

		# ---- 特效档位：根据 GPU 自动选 ------------------------------------
		# swayfx 的阴影（高斯模糊）和大圆角抗锯齿都很吃像素。
		# QEMU 的 virtio-gpu 没有 virgl，GLES2 走 llvmpipe 软件光栅化，
		# 阴影会把每帧成本翻好几倍；再加 TCG（没开 VT-x 时）就直接 PPT。
		# 检测到 virtio 驱动就降到"轻效档"（关阴影、圆角 6），真机满效档。
		drv="$(basename "$(readlink /sys/class/drm/card0/device/driver 2>/dev/null)" 2>/dev/null)"
		effects="$XDG_RUNTIME_DIR/effects.conf"
		case "$drv" in
			i915|amdgpu|radeon|nouveau|nvidia*)
				cat >"$effects" <<'EOF'
# 满效档：真实 GPU（i915/iris 等）
corner_radius 10
smart_corner_radius enable
shadows enable
shadows_on_csd enable
shadow_blur_radius 20
shadow_color #0000004D
shadow_offset 0 4
# 毛玻璃：macOS 风格面板/Dock 的底（passes 越多越糊也越贵）
blur enable
blur_passes 3
blur_radius 5
EOF
				say "GPU=$drv → 满效档"
				;;
			*)
				# 虚拟 GPU / 软件渲染：
				#   * 硬件光标平面在 virtio-gpu 上不可靠（光标消失、鼠标附近黑块）→ 软件光标
				#   * modifier 与 llvmpipe 不匹配 → 禁用 modifier，减少区块虚闪
				export WLR_NO_HARDWARE_CURSORS=1
				export WLR_DRM_NO_MODIFIERS=1
				cat >"$effects" <<'EOF'
# 轻效档：虚拟/软件渲染（virtio-gpu 无 virgl、bochs 等）
corner_radius 6
smart_corner_radius enable
shadows disable
# blur 在软件渲染下必须关掉（实测，不是拍脑袋）：
#   swayfx 的 blur 背景纹理在 llvmpipe 上逐帧不稳定，半透明的 panel 每次
#   重绘都会采到不同的底色——屏幕上就是整条菜单栏在两种颜色间跳。
#   4 秒静置实测：blur 开 = 菜单栏 35840 px + Dock 23708 px 全量重绘；
#                  blur 关 = 58 px（只有时钟文字）。
#   每一跳都是整条的脏区，合成器因此永远闲不下来——这就是"虚闪 + 卡顿"。
# 毛玻璃只在真 GPU 档（上面那档）保留。
blur disable
EOF
				# virtio-gpu 2D：QEMU 只把 DRM damage clip 里的矩形传回 host，
				# 其余区域保留旧内容 → 黑块/残影，必须整屏重绘（scenefx 0001）。
				# bochs 是线性帧缓冲、vmwgfx 有真 3D，都没有这个问题；而整屏
				# 重绘在软件渲染下每帧多画 1280x800（15-25ms）——开着就是卡顿。
				if [ "$drv" = "virtio_gpu" ]; then
					export SHUIOS_FORCE_FULL_DAMAGE=1
				fi
				say "GPU=$drv → 轻效档（无阴影、无 blur、圆角 6、软件光标）"
				;;
		esac

		say "启动 swayfx（fx renderer / GLES2）"
		/usr/bin/sway --unsupported-gpu --config /etc/shuios/sway-config > "$LOG" 2>&1
		rc=$?

		# EGL 起不来时先试软件 GL，而不是直接掉进 Weston：Weston 没有
		# wlr-layer-shell（waybar 与 Dock 全都起不来），它在虚拟 GPU 上的软件合成
		# 还会留下鼠标黑块和残影——表现比"没有桌面"更糟。
		if [ "$rc" -ne 0 ] && grep -q "Failed to create renderer" "$LOG"; then
			mv -f "$LOG" "$LOG.try1"
			case "$drv" in
			vmwgfx)
				# vmwgfx 不实现 dumb buffer（内核 vmwgfx_drv.c 里没有 dumb_create），
				# 所以 kms_swrast 这条兜底在它身上不成立，只能让宿主机开 3D。
				say "swayfx 起不动：VMware 的 vmwgfx 需要宿主机开 3D 加速"
				say '修法：在 .vmx 里设 mks.enable3d = "TRUE"（tools/run-vmware.ps1 会自动写）'
				;;
			*)
				say "swayfx 的 EGL 起不来，改用 kms_swrast 软件 GL 重试"
				MESA_LOADER_DRIVER_OVERRIDE=kms_swrast \
					/usr/bin/sway --unsupported-gpu --config /etc/shuios/sway-config > "$LOG" 2>&1
				rc=$?
				;;
			esac
		fi

		if [ "$rc" -ne 0 ]; then
			say "sway 退出 rc=$rc，日志如下（最后 40 行）："
			tail -n 40 "$LOG" >> "$SER" 2>/dev/null || true
		fi
		# 恢复帧缓冲控制台
		for vt in 0 1 2 3 4; do
			[ -w "/sys/class/vtconsole/vtcon$vt/bind" ] && echo 1 > "/sys/class/vtconsole/vtcon$vt/bind" 2>/dev/null
		done
		# 兜底：sway 起不来就用 Weston，保证用户一定看得到桌面
		if [ "$rc" -ne 0 ] && [ -x /usr/bin/weston ]; then
			say "回退到 Weston（无任务栏，但画面可用）"
			exec /usr/bin/weston --backend=drm-backend.so --idle-time=0 --log="$LOG.weston"
		fi
		exit "$rc"
		;;
esac
