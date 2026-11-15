#!/bin/sh
# 在 WSL 构建发行版里查看 shuios 构建状态与关键配置（避免 Windows 侧引号问题）。
#
# 用法（Windows）：
#   wsl -d shui-build -u root -- sh /mnt/d/shuios/tools/wsl-status.sh
set -u

BR=/root/shuios/buildroot
CFG="$BR/.config"

echo "===== 图形栈相关配置 ====="
for k in BR2_PACKAGE_MESA3D BR2_PACKAGE_MESA3D_LLVM BR2_PACKAGE_MESA3D_OPENGL_EGL \
         BR2_PACKAGE_HAS_LIBEGL BR2_PACKAGE_LIBGTK3 BR2_PACKAGE_LIBGTK3_WAYLAND \
         BR2_PACKAGE_WESTON BR2_PACKAGE_NETSURF BR2_PACKAGE_NETSURF_GTK3 BR2_PACKAGE_NETSURF_SDL \
         BR2_PACKAGE_PCMANFM BR2_PACKAGE_FOOT BR2_PACKAGE_LLAMA_CPP \
         BR2_USE_WCHAR BR2_INSTALL_LIBSTDCPP BR2_TOOLCHAIN_HAS_THREADS_NPTL BR2_STATIC_LIBS; do
	v="$(grep -E "^${k}=" "$CFG" 2>/dev/null || true)"
	if [ -n "$v" ]; then echo "  $v"; else echo "  ${k}  (未设置/关闭)"; fi
done

echo
echo "===== 关键工具链符号 ====="
grep -E '^BR2_TOOLCHAIN_GCC_AT_LEAST_(8|7)=|^BR2_TOOLCHAIN_HAS_SYNC' "$CFG" 2>/dev/null | sort || true

echo
echo "===== 最近在编译的包 ====="
ls -t "$BR/output/build" 2>/dev/null | head -6 || echo "(没有 build 目录)"

echo
echo "===== 产物 ====="
ls -lh "$BR/output/images" 2>/dev/null || echo "(还没有 images)"

echo
echo "===== 构建进程 ====="
pgrep -fa 'build-in-wsl|make -C buildroot' 2>/dev/null | head -3 || echo "(没有构建进程在跑)"

echo
echo "===== 磁盘 ====="
df -h / | tail -n 1
