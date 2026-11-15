#!/bin/bash
# 修复 output/target：把当前 .config 里所有已启用包的 target 安装重新跑一遍。
#
# 背景：make-pkgrepo.sh 早期版本用 rm 把包的文件从 target 删掉了，但 Buildroot
# 的 install stamp 还在，后续 make 不会补回来 → 镜像会缺库（例如 ncurses）。
# 这里对所有已启用目标做一次 -reinstall，把 target 恢复到配置应有的状态。
set -uo pipefail
BR=/root/shuios/buildroot
cd "$BR" || exit 1

make -s BR2_EXTERNAL=/root/shuios/br2-ext shuios_x86_64_defconfig >/dev/null || exit 1

targets=$(make -s BR2_EXTERNAL=/root/shuios/br2-ext show-targets 2>/dev/null)
ok=0
skip=0
for t in $targets; do
	case "$t" in
		*.*|*.tar*|*.*) ;;  # 跳过 "xxx-yyy" 结果里的杂项
	esac
	if [ ! -d "$BR/output/build/$t" ] && ! ls -d "$BR/output/build/$t"-* >/dev/null 2>&1; then
		skip=$((skip + 1))
		continue
	fi
	if make -s BR2_EXTERNAL=/root/shuios/br2-ext "$t-reinstall" >>/tmp/repair.log 2>&1; then
		ok=$((ok + 1))
	else
		echo "    ! $t-reinstall 失败"
	fi
done

echo ">>> 重装完成：$ok 个，跳过 $skip 个"
echo
echo "=== 抽查关键文件是否回来了 ==="
for f in /usr/bin/mc /usr/bin/nano /usr/bin/tmux /usr/bin/jq /usr/lib/libncursesw.so.6 \
	/usr/share/terminfo /usr/bin/weston /usr/bin/foot /usr/bin/shui-store \
	/usr/lib/libgtk-3.so.0 /usr/lib/libcurl.so.4 /usr/lib/libmbedtls.so.21; do
	if [ -e "$BR/output/target$f" ]; then echo "  ✓ $f"; else echo "  ✗ $f（镜像里没有）"; fi
done
ls "$BR/output/target/usr/lib/" | grep -c '^libncurses' | sed 's/^/  ncurses 库文件数: /'
