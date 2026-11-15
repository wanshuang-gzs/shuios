#!/bin/sh
# 用 WSL 里**完整解压**的 Buildroot 树校验 defconfig 的选项名。
#
# 为什么需要：Windows 上那半份解压树是残缺的（tar 有 130 个文件失败），
# 用它校验会漏掉真实存在的符号（例如 BR2_TOOLCHAIN_BUILDROOT_CXX）。
#
# 用法：wsl -d shui-build -u root -- sh /mnt/d/shuios/tools/validate-defconfig.sh
set -u

BR="${BR:-/root/shuios/buildroot}"
EXT="${EXT:-/root/shuios/br2-ext}"
DEF="${DEF:-/root/shuios/br2-ext/configs/shuios_x86_64_defconfig}"

if [ ! -d "$BR" ] || [ ! -f "$DEF" ]; then
	echo "路径不对：BR=$BR DEF=$DEF" >&2
	exit 1
fi

# 同时扫描 Buildroot 本体和 BR2_EXTERNAL（自研包），否则
# BR2_PACKAGE_FCITX5 这类外部符号会被误报成缺失。
{
	grep -rhE '^[[:space:]]*(menu)?config[[:space:]]+BR2_' \
		--include='Config.in' --include='Config.in.host' --include='*.in' "$BR" 2>/dev/null
	[ -d "$EXT" ] && grep -rhE '^[[:space:]]*(menu)?config[[:space:]]+BR2_' \
		--include='Config.in' --include='Config.in.host' --include='*.in' "$EXT" 2>/dev/null
} | sed -E 's/^[[:space:]]*(menu)?config[[:space:]]+//' | tr -d '\r' | sort -u > /tmp/br2-defined.txt

grep -oE 'BR2_[A-Z0-9_]+' "$DEF" | sort -u > /tmp/br2-used.txt

echo "Kconfig 中定义的符号：$(wc -l < /tmp/br2-defined.txt)"
echo "defconfig 使用的符号：$(wc -l < /tmp/br2-used.txt)"

# 自身的外部树变量与自有包符号不算缺失
comm -23 /tmp/br2-used.txt /tmp/br2-defined.txt \
	| grep -vE '^BR2_EXTERNAL|^BR2_PACKAGE_SHUIOS_RUNTIME$|^BR2_PACKAGE_LLAMA_CPP$|^BR2_PACKAGE_LLAMA_CPP_|^BR2_PACKAGE_SHUios' \
	| sed 's/^/  MISSING: /' > /tmp/br2-missing.txt

if [ -s /tmp/br2-missing.txt ]; then
	echo "--- 在 Buildroot 中不存在 ---"
	cat /tmp/br2-missing.txt
	exit 1
fi

echo "全部存在 ✓"
