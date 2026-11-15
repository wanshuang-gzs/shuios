#!/bin/bash
set -u
BR=/root/shuios/buildroot
cd "$BR" || exit 1
echo "=== 递归依赖目标是否可用 ==="
make -s BR2_EXTERNAL=/root/shuios/br2-ext BR2_PACKAGE_LIBCURL=y BR2_PACKAGE_LIBCURL_MBEDTLS=y \
	olddefconfig >/dev/null 2>&1
echo "--- libcurl 直接依赖 ---"
make -s BR2_EXTERNAL=/root/shuios/br2-ext libcurl-show-depends 2>&1 | head -3
echo "--- libcurl 递归依赖 ---"
make -s BR2_EXTERNAL=/root/shuios/br2-ext libcurl-show-recursive-depends 2>&1 | head -3
echo "--- files-list ---"
for p in libcurl mbedtls htop; do
	d=$(ls -d output/build/$p-* 2>/dev/null | head -1)
	if [ -n "$d" ] && [ -f "$d/.files-list.txt" ]; then
		echo "$p: $(wc -l < "$d/.files-list.txt") 条"
	else
		echo "$p: 无 files-list"
	fi
done
echo "--- target 里还有多少 mbedtls 文件 ---"
ls output/target/usr/lib/libmbed* 2>/dev/null | wc -l
