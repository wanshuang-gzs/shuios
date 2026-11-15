#!/bin/sh
# 强制重建 ncurses（宽字符版）并继续构建。
#
# 背景：BR2_PACKAGE_NCURSES_WCHAR=y 加上之后，Buildroot 不会自动重建已安装的
# ncurses，所以 libncursesw.so 不存在，mc 链接时报 mvin_wchnstr / setcchar 未定义。
# 改任何包的配置后，若产物已存在，必须对该包 dirclean 才生效。
set -eu

ROOT=/root/shuios
BR="$ROOT/buildroot"
cd "$BR"

echo ">>> 1/3 清理 ncurses 与依赖它的 mc"
make -s BR2_EXTERNAL="$ROOT/br2-ext" ncurses-dirclean 2>&1 | tail -n 2 || true
rm -rf "$BR/output/build/mc-"*
echo "    已清理"

echo ">>> 2/3 重新应用 defconfig"
make -s BR2_EXTERNAL="$ROOT/br2-ext" shuios_x86_64_defconfig >/dev/null
grep -E '^BR2_PACKAGE_NCURSES_WCHAR=y' .config >/dev/null || { echo "WCHAR 未开" >&2; exit 1; }

echo ">>> 3/3 继续构建（-j12，安静模式）"
exec make -s BR2_EXTERNAL="$ROOT/br2-ext" \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12
