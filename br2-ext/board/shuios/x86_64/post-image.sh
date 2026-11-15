#!/bin/sh
# shuios post-image：组装 A/B 磁盘映像。
#
# Buildroot 会导出 BUILD_DIR / BINARIES_DIR / TARGET_DIR / HOST_DIR。
#
# 本脚本做四件事：
#   1. 把 shuios 的 grub.cfg 覆盖到 ESP 的 /EFI/BOOT/grub.cfg
#   2. 生成初始 grubenv（1024 字节，GRUB 的 A/B 状态块）
#   3. 生成数据分区 data.ext4（带卷标、预置目录）与空的 B 槽 root-b.raw
#   4. 调用 genimage 组装 shuios.img
#
# 注意：host e2fsprogs 的可执行文件装在 $HOST_DIR/sbin（不是 bin），
# 所以查找 mke2fs 必须两边都看。
set -eu

for v in BUILD_DIR BINARIES_DIR TARGET_DIR HOST_DIR; do
	eval "val=\$$v"
	if [ -z "$val" ]; then
		echo "shuios post-image: 缺少环境变量 $v（应由 Buildroot 提供）" >&2
		exit 1
	fi
done

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------ 0. 前置检查
SQUASHFS="${BINARIES_DIR}/rootfs.squashfs"
if [ ! -f "${SQUASHFS}" ]; then
	echo "!!! 找不到 ${SQUASHFS}（需要 BR2_TARGET_ROOTFS_SQUASHFS=y）" >&2
	exit 1
fi

EIEFI_DIR="${BINARIES_DIR}/efi-part/EFI/BOOT"
BOOT_EFI="${EIEFI_DIR}/bootx64.efi"
if [ ! -f "${BOOT_EFI}" ]; then
	echo "!!! 找不到 ${BOOT_EFI}" >&2
	echo "!!! 请确认 BR2_TARGET_GRUB2=y 且 BR2_TARGET_GRUB2_X86_64_EFI=y" >&2
	exit 1
fi

# ---------------------------------------------------------------- 1. GRUB
echo ">>> shuios: 安装 GRUB 配置到 ${EIEFI_DIR}/grub.cfg"
install -D -m 0644 "${BOARD_DIR}/grub.cfg" "${EIEFI_DIR}/grub.cfg"

# ------------------------------------------------------------- 2. grubenv
ENV="${EIEFI_DIR}/grubenv"
echo ">>> shuios: 生成初始 grubenv（slot=a, state=ok）"
ENV_TMP="${BUILD_DIR}/.grubenv.tmp"
{
	printf '# GRUB Environment Block\n'
	printf 'shuios_slot=a\n'
	printf 'shuios_prev=a\n'
	printf 'shuios_state=ok\n'
} > "${ENV_TMP}"
_size=$(wc -c < "${ENV_TMP}")
_pad=$((1024 - _size))
if [ "${_pad}" -gt 0 ]; then
	dd if=/dev/zero bs=1 count="${_pad}" 2>/dev/null | tr '\0' '#' >> "${ENV_TMP}"
fi
if [ "$(wc -c < "${ENV_TMP}")" -ne 1024 ]; then
	echo "!!! grubenv 不是 1024 字节" >&2
	exit 1
fi
install -D -m 0644 "${ENV_TMP}" "${ENV}"

# --------------------------------------------------------- 3. 数据分区 / B 槽
DATA_IMG="${BINARIES_DIR}/data.ext4"
DATA_SIZE="${SHUIOS_DATA_SIZE:-1024}"     # MiB
DATA_ROOT="${BUILD_DIR}/shuios-data-root"

# mke2fs 在 host/sbin 或 host/bin，两个都找
MKE2FS=""
for c in "${HOST_DIR}/sbin/mke2fs" "${HOST_DIR}/bin/mke2fs"; do
	[ -x "$c" ] && MKE2FS="$c" && break
done
if [ -z "${MKE2FS}" ]; then
	MKE2FS="$(command -v mke2fs 2>/dev/null || true)"
fi
if [ -z "${MKE2FS}" ]; then
	echo "!!! 找不到 mke2fs（需要 BR2_PACKAGE_HOST_E2FSPROGS=y）" >&2
	exit 1
fi
echo ">>> shuios: 使用 mke2fs: ${MKE2FS}"

if [ ! -f "${DATA_IMG}" ] || [ "${SHUIOS_REBUILD_DATA:-1}" = "1" ]; then
	echo ">>> shuios: 生成数据分区（${DATA_SIZE}MiB, LABEL=SHUI-DATA）"
	rm -f "${DATA_IMG}"
	rm -rf "${DATA_ROOT}"
	mkdir -p "${DATA_ROOT}/workspace" "${DATA_ROOT}/shuios/models" "${DATA_ROOT}/shuios/state"
	cat > "${DATA_ROOT}/workspace/.keep" <<'EOF'
shuios 工作区。这里的文件在重启、升级后都会保留。
EOF
	if command -v truncate >/dev/null 2>&1; then
		truncate -s "${DATA_SIZE}M" "${DATA_IMG}"
	else
		dd if=/dev/zero of="${DATA_IMG}" bs=1M count="${DATA_SIZE}" status=none
	fi
	"${MKE2FS}" -q -F -t ext4 -L SHUI-DATA -E root_owner=0:0 -m 0 \
		-d "${DATA_ROOT}" "${DATA_IMG}"
fi

SQ_MB=$(( ($(wc -c < "${SQUASHFS}") + 1048575) / 1048576 + 64 ))
SLOT_MB="${SHUIOS_SLOT_SIZE:-${SQ_MB}}"
if [ "${SLOT_MB}" -lt 512 ]; then SLOT_MB=512; fi

ROOT_B="${BINARIES_DIR}/root-b.raw"
echo ">>> shuios: 生成空 B 槽（${SLOT_MB}MiB）供首次升级写入"
rm -f "${ROOT_B}"
if command -v truncate >/dev/null 2>&1; then
	truncate -s "${SLOT_MB}M" "${ROOT_B}"
else
	dd if=/dev/zero of="${ROOT_B}" bs=1M count="${SLOT_MB}" status=none
fi

# --------------------------------------------------------------- 4. 组盘
echo ">>> shuios: 调用 genimage 组装 shuios.img"
GENIMAGE=""
for c in "${HOST_DIR}/bin/genimage" "${HOST_DIR}/sbin/genimage"; do
	[ -x "$c" ] && GENIMAGE="$c" && break
done
[ -z "${GENIMAGE}" ] && GENIMAGE="$(command -v genimage 2>/dev/null || true)"
if [ -z "${GENIMAGE}" ]; then
	echo "!!! 找不到 genimage（需要 BR2_PACKAGE_HOST_GENIMAGE=y）" >&2
	exit 1
fi

ROOTPATH_TMP="$(mktemp -d)"
trap 'rm -rf "${ROOTPATH_TMP}"' EXIT

rm -rf "${BUILD_DIR}/genimage.tmp"
"${GENIMAGE}" \
	--rootpath "${ROOTPATH_TMP}" \
	--tmppath "${BUILD_DIR}/genimage.tmp" \
	--inputpath "${BINARIES_DIR}" \
	--outputpath "${BINARIES_DIR}" \
	--config "${BOARD_DIR}/genimage.cfg"

echo
echo ">>> 产物"
ls -lh "${BINARIES_DIR}/shuios.img" "${SQUASHFS}" "${ROOT_B}" 2>/dev/null || true
echo ">>> 完成：${BINARIES_DIR}/shuios.img（A/B 双根：槽 A 已装系统，槽 B 待升级）"
