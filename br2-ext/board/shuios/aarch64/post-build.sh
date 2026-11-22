#!/bin/sh
# shuios post-build：镜像构建完成、post-image 之前的最后一步
# 职责：品牌化、权限修正、必要的目录准备。

set -eu

TARGET_DIR="${TARGET_DIR:-${1:-}}"
if [ -z "${TARGET_DIR}" ] || [ ! -d "${TARGET_DIR}" ]; then
	echo "shuios post-build: 缺少 TARGET_DIR（应由 Buildroot 以环境变量提供）" >&2
	exit 1
fi
# 防止误写到宿主根目录
case "${TARGET_DIR}" in
	output/target|*/output/target) ;;
	*) echo "shuios post-build: TARGET_DIR 异常（${TARGET_DIR}）" >&2; exit 1 ;;
esac

# --- 品牌化 /etc/os-release ---------------------------------------------
cat > "${TARGET_DIR}/etc/os-release" <<'EOF'
NAME="shuios"
PRETTY_NAME="shuios 0.1 「泉」 (氵系统)"
ID=shuios
ID_LIKE=linux
VERSION="0.1 「泉」"
VERSION_ID="0.1"
VERSION_CODENAME=quan
BUILD_ID=rolling
ANSI_COLOR="1;36"
HOME_URL="https://github.com/shuios/shuios"
DOCUMENTATION_URL="https://github.com/shuios/shuios/tree/main/docs"
SUPPORT_URL="https://github.com/shuios/shuios/issues"
BUG_REPORT_URL="https://github.com/shuios/shuios/issues"
SHUIOS_AI_NATIVE=1
EOF

cat > "${TARGET_DIR}/etc/issue" <<'EOF'

  氵 shuios 0.1 「泉」  \r (\l)

EOF

# --- 权限修正（在 Windows 上准备的文件可能没有可执行位）-----------------
for f in \
	"${TARGET_DIR}/usr/libexec/shuios/shuios-storage" \
	"${TARGET_DIR}/usr/libexec/shuios/shuios-firstboot"
do
	[ -f "$f" ] && chmod 0755 "$f"
done

# --- 保证关键目录存在（overlay 里可能只有空目录）-------------------------
mkdir -p "${TARGET_DIR}/workspace" \
	"${TARGET_DIR}/var/lib/shuios/models" \
	"${TARGET_DIR}/var/log/shuios/agents" \
	"${TARGET_DIR}/data" \
	"${TARGET_DIR}/etc/shuios"

# --- 预生成 SSH 主机密钥 ------------------------------------------------
# 根文件系统是只读 squashfs，sshd 无法在运行时生成密钥，会直接 failed。
# 因此在构建阶段（构建主机上有 ssh-keygen）就把密钥写进镜像。
if [ -d "${TARGET_DIR}/etc/ssh" ]; then
	if [ ! -f "${TARGET_DIR}/etc/ssh/ssh_host_ed25519_key" ]; then
		echo ">>> shuios: 预生成 SSH 主机密钥"
		ssh-keygen -q -t ed25519 -f "${TARGET_DIR}/etc/ssh/ssh_host_ed25519_key" -N '' -C shuios
		ssh-keygen -q -t rsa -b 3072 -f "${TARGET_DIR}/etc/ssh/ssh_host_rsa_key" -N '' -C shuios
		ssh-keygen -q -t ecdsa -f "${TARGET_DIR}/etc/ssh/ssh_host_ecdsa_key" -N '' -C shuios
		chmod 600 "${TARGET_DIR}"/etc/ssh/ssh_host_*_key
		chmod 644 "${TARGET_DIR}"/etc/ssh/ssh_host_*_key.pub
	fi
	# 允许 root 用密码登录（默认密码在 BR2_TARGET_GENERIC_ROOT_PASSWD 里设置）
	if [ -f "${TARGET_DIR}/etc/ssh/sshd_config" ]; then
		sed -i -e 's/^#*PermitRootLogin.*/PermitRootLogin yes/' \
		       -e 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
			"${TARGET_DIR}/etc/ssh/sshd_config"
		grep -q '^PermitRootLogin' "${TARGET_DIR}/etc/ssh/sshd_config" || \
			echo 'PermitRootLogin yes' >> "${TARGET_DIR}/etc/ssh/sshd_config"
	fi
fi

# --- 屏蔽 Buildroot 自带的 weston.service ---------------------------------
# 桌面由 shuios-desktop.service 统一管理（它内部 exec swayfx）。
# Buildroot 的 weston 包会把自己挂进 multi-user.target.wants，而且它的安装
# 时机在 shuios-runtime 之后时，我们包里的 rm 就又白做了——所以在这里兜底：
#   1) 删掉自动启动的软链；
#   2) 把单元 mask 掉（指向 /dev/null），彻底防止被别的依赖拉起来。
#
# 为什么必须只留一个合成器：两个合成器会各自拉一整套桌面（foot/shui/商店/mc），
# 抢同一块 DRM，画面就会"每一帧都留在屏幕上"，CPU 也被吃掉一倍
# （实测两个实例时输入延迟 23~106ms）。weston 现在只在 sway 起不来时做救援。
rm -f "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/weston.service"
rm -f "${TARGET_DIR}/etc/systemd/system/graphical.target.wants/weston.service"
ln -sf /dev/null "${TARGET_DIR}/etc/systemd/system/weston.service"

# --- 清理 systemd-networkd 残留 ------------------------------------------
# 网络已交给 NetworkManager，defconfig 关闭了 systemd-networkd；但 systemd
# 基础包仍会装 tmpfiles.d/systemd-network.conf，目录属主是 systemd-network。
# 该用户只在 networkd 启用时才创建，mksquashfs 生成镜像时解析设备表会失败
# （Error 65 / Failed to resolve user 'systemd-network'）。
rm -f "${TARGET_DIR}/usr/lib/tmpfiles.d/systemd-network.conf"
rm -f "${TARGET_DIR}/usr/lib/sysusers.d/systemd-network.conf"
# Buildroot 在镜像生成前会跑 `systemctl preset-all`（ROOTFS_PRE_CMD hook，
# 晚于 post-build），默认 preset 会启用 networkd 和 ifupdown 的 network.service，
# 它们会和 NM 抢网卡（networkd 还会因缺 systemd-network 用户启动失败）。
# 用更高优先级的 preset 文件（00- 排在 90-default 之前）禁用它们。
mkdir -p "${TARGET_DIR}/etc/systemd/system-preset"
cat > "${TARGET_DIR}/etc/systemd/system-preset/00-shuios.preset" <<'EOF'
# 网络统一由 NetworkManager 管理
disable systemd-networkd.service
disable systemd-networkd.socket
disable systemd-networkd-wait-online.service
disable network.service
# 音频由桌面会话自己拉起（需要会话 D-Bus / XDG_RUNTIME_DIR / 可写 HOME）
disable pipewire.service
disable pipewire.socket
disable pipewire-manager.socket
disable wireplumber.service
EOF

# --- 屏蔽系统级 PipeWire/WirePlumber 单元 ---------------------------------
# Buildroot 的 pipewire/wireplumber 包会装系统单元并默认启用：它们以
# pipewire 用户运行、PIPEWIRE_RUNTIME_DIR=/run/pipewire，没有会话 D-Bus，
# 但开机会先抢到 HDA 声卡。桌面会话随后拉起的实例只能退化成 Dummy Output
# （实测：真正的 analog-stereo sink 不出现，wpctl 只看到 Dummy）。
# 桌面会话需要的声音服务器必须在 shuios-session.sh 里启动。
for u in pipewire.service pipewire.socket pipewire-manager.socket \
	wireplumber.service wireplumber@.service; do
	rm -f "${TARGET_DIR}/etc/systemd/system/multi-user.target.wants/${u}" \
		"${TARGET_DIR}/etc/systemd/system/default.target.wants/${u}"
	ln -sf /dev/null "${TARGET_DIR}/etc/systemd/system/${u}"
done

# --- resolv.conf 指向 resolved 本地 stub ---------------------------------
# Buildroot 默认是 uplink 模式（应用直连上游 DNS，绕过本地缓存）；
# 改成 stub 后应用查 127.0.0.53，由 resolved 统一缓存并转发。
rm -f "${TARGET_DIR}/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "${TARGET_DIR}/etc/resolv.conf"

# --- NM 连接配置目录指向数据分区（最后关口）------------------------------
# NM 包安装的是真实目录；必须在镜像生成前确保它是符号链接，否则连接配置
# 会尝试写只读根。这里再兜底一次，防止包安装顺序变化把它覆盖回去。
rm -rf "${TARGET_DIR}/etc/NetworkManager/system-connections"
mkdir -p "${TARGET_DIR}/etc/NetworkManager"
ln -sfn /var/lib/shuios/NetworkManager/system-connections \
	"${TARGET_DIR}/etc/NetworkManager/system-connections"

# --- 控制台 locale -------------------------------------------------------
# locale 数据由 Buildroot 依据 BR2_GENERATE_LOCALE 生成进
# /usr/lib/locale/locale-archive（见 defconfig），这里只补 shell 的默认值。
mkdir -p "${TARGET_DIR}/etc/profile.d"
cat > "${TARGET_DIR}/etc/profile.d/locale.sh" <<'EOF'
export LANG=zh_CN.UTF-8
EOF
# systemd 从 /etc/locale.conf 取初始环境；不写的话默认是 C.UTF-8，
# 所有服务（包括桌面会话）里的日期/排序都按 C locale 走。
cat > "${TARGET_DIR}/etc/locale.conf" <<'EOF'
LANG=zh_CN.UTF-8
EOF

# --- 记录构建信息 -------------------------------------------------------
{
	echo "shuios build"
	echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "kernel: $(ls "${TARGET_DIR}/lib/modules" 2>/dev/null | head -n1 || echo unknown)"
} > "${TARGET_DIR}/etc/shuios/build-info"

exit 0
