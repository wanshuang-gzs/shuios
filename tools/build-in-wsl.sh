#!/usr/bin/env bash
# 在 WSL2 的构建发行版里执行：装依赖 → 编 Rust → 跑 Buildroot → 产出镜像。
#
# 用法（在 WSL 内）：
#   bash /mnt/d/shuios/tools/build-in-wsl.sh
#
# 设计要点：
#   * apt 与 Rust 都走清华 TUNA 镜像（实测 ~3.5 MB/s，直连只有几十 KB/s）
#   * Buildroot 源码从 Windows 侧已下载的 .cache 里复制，避免重复慢速下载
#   * 仓库复制到 ext4（/root/shuios）里构建：在 /mnt/d 上直接跑会慢 5~10 倍
set -euo pipefail

TUNA="https://mirrors.tuna.tsinghua.edu.cn"
SRC="/mnt/d/shuios"
DST="/root/shuios"
BR_VER="2025.02.9"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ 1. apt
log "配置 apt 源为 TUNA"
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
	sed -i "s|http://archive.ubuntu.com/ubuntu|$TUNA/ubuntu|g; \
	        s|http://security.ubuntu.com/ubuntu|$TUNA/ubuntu|g; \
	        s|http://ports.ubuntu.com/ubuntu-ports|$TUNA/ubuntu-ports|g" \
		/etc/apt/sources.list.d/ubuntu.sources
fi
if [ -f /etc/apt/sources.list ]; then
	sed -i "s|http://archive.ubuntu.com/ubuntu|$TUNA/ubuntu|g; \
	        s|http://security.ubuntu.com/ubuntu|$TUNA/ubuntu|g" /etc/apt/sources.list
fi

export DEBIAN_FRONTEND=noninteractive
log "安装构建依赖"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	build-essential git wget curl ca-certificates cpio unzip rsync bc \
	libncurses-dev file python3 python3-pip libssl-dev pkg-config \
	dosfstools mtools e2fsprogs squashfs-tools patch perl bzip2 xz-utils \
	jq zstd lz4 bison flex gawk \
	groff xsltproc imagemagick netpbm socat \
	qemu-system-x86 ovmf

# ----------------------------------------------------------------- 2. rust
if ! command -v cargo >/dev/null 2>&1; then
	log "安装 Rust（TUNA 镜像）"
	export RUSTUP_DIST_SERVER="$TUNA/rustup"
	export RUSTUP_UPDATE_ROOT="$TUNA/rustup/rustup"
	curl --proto '=https' --tlsv1.2 -sSf "$TUNA/rustup/rustup/dist/x86_64-unknown-linux-gnu/rustup-init" \
		-o /tmp/rustup-init
	chmod +x /tmp/rustup-init
	/tmp/rustup-init -y --profile minimal --default-toolchain stable --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"
cargo --version

# ------------------------------------------------------------- 3. 复制源码
log "复制仓库到 $DST（排除 Windows 侧缓存与构建产物）"
mkdir -p "$DST"
rsync -a --delete \
	--exclude '.cache' --exclude 'target' --exclude 'output' \
	--exclude 'buildroot' --exclude '.git' \
	"$SRC/" "$DST/"

# Buildroot 源码：优先用 Windows 侧已下载的 tarball（在 Linux 里解压，
# 因为 Windows 的 tar 解压这个包时会有约 130 个文件失败）
if [ ! -d "$DST/buildroot" ]; then
	if [ -f "$SRC/.cache/buildroot-$BR_VER.tar.xz" ]; then
		log "从本地 tarball 解压 Buildroot $BR_VER"
		tar -xf "$SRC/.cache/buildroot-$BR_VER.tar.xz" -C "$DST"
		mv "$DST/buildroot-$BR_VER" "$DST/buildroot"
	elif [ -d "$SRC/.cache/buildroot-$BR_VER" ]; then
		log "警告：复用 Windows 侧已解压的 Buildroot（可能缺少个别文件）"
		cp -a "$SRC/.cache/buildroot-$BR_VER" "$DST/buildroot"
	else
		log "下载 Buildroot $BR_VER"
		wget -q --show-progress -O /tmp/br.tar.xz "$TUNA/buildroot/downloads/buildroot-$BR_VER.tar.xz" \
			|| wget -q --show-progress -O /tmp/br.tar.xz "https://buildroot.org/downloads/buildroot-$BR_VER.tar.xz"
		tar -xf /tmp/br.tar.xz -C "$DST"
		mv "$DST/buildroot-$BR_VER" "$DST/buildroot"
	fi
fi

cd "$DST"

# --------------------------------------------------------------- 4. 构建
log "编译 Rust 组件"
./tools/build-rust.sh

log "预取 Buildroot 源码到本地镜像（TUNA 加速）"
./tools/fetch-deps.sh || echo "（预取有失败项，继续尝试直接构建）"

MIRROR="$HOME/shuios-mirror"
BR2_EXTRA=""
if [ -d "$MIRROR" ]; then
	BR2_EXTRA="BR2_PRIMARY_SITE=file://$MIRROR"
fi

log "配置 shuios ($BR2_EXTRA)"
make -C buildroot BR2_EXTERNAL="$DST/br2-ext" $BR2_EXTRA shuios_x86_64_defconfig

log "开始构建镜像（这一步最久，约 25~60 分钟）"
JOBS="$(nproc)"
make -C buildroot BR2_EXTERNAL="$DST/br2-ext" $BR2_EXTRA -j"$JOBS"

log "构建完成，产物如下"
ls -lh buildroot/output/images/ 2>/dev/null || true

if [ -f buildroot/output/images/shuios.img ]; then
	log "把镜像复制回 Windows 侧"
	cp -f buildroot/output/images/shuios.img "$SRC/shuios.img"
	cp -f buildroot/output/images/rootfs.squashfs "$SRC/rootfs.squashfs" 2>/dev/null || true
	ls -lh "$SRC/shuios.img"
fi

log "全部完成"
