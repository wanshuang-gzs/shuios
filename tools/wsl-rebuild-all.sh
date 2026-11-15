#!/bin/bash
# 一键：同步源码 → 重建软件仓库 → 重建自研应用 → 重打镜像。日志在 /tmp 下。
set -u

# 必须先把 Windows 侧源码同步进来：应用重建用的是 /root/shuios 里的源码，
# 而 wsl-repack.sh 里的 rsync 在最后一步才跑——先编后同步会拿旧代码编译
# （踩过：改了 C 却一直报同一个旧错误）。
echo ">>> 同步源码到 WSL"
rsync -a --delete \
	--exclude '.cache' --exclude 'target' --exclude 'output' \
	--exclude 'buildroot' --exclude '.git' --exclude 'br2-ext/artifacts' \
	--exclude 'br2-ext/pkgrepo' \
	/mnt/d/shuios/ /root/shuios/ || exit 1

echo ">>> 重建软件仓库"
bash /mnt/d/shuios/tools/make-pkgrepo.sh > /tmp/pkgrepo-run.log 2>&1
rc=$?
echo "    repo rc=$rc"
if [ "$rc" -ne 0 ]; then
	echo "!!! 仓库构建失败，最后 15 行："
	tail -15 /tmp/pkgrepo-run.log
fi

echo ">>> 强制重建自研 GTK 应用（改了 C 源码）"
cd /root/shuios/buildroot || exit 1
# 先应用 defconfig：新加的包（shui-panel）只有进了 .config 才有 <pkg>-rebuild 目标
make -s BR2_EXTERNAL=/root/shuios/br2-ext shuios_x86_64_defconfig >/dev/null 2>&1
# Buildroot 的 local 包不会因为源码变动自动重建，必须显式 rebuild。
for p in shui-store shui-panel shui-browser; do
	if ! grep -q "^BR2_PACKAGE_$(echo "$p" | tr 'a-z-' 'A-Z_')=y" .config; then
		echo "    $p 未在 defconfig 中启用，跳过"
		continue
	fi
	make -s BR2_EXTERNAL=/root/shuios/br2-ext BR2_PRIMARY_SITE=file:///root/shuios-mirror \
		-j12 "$p-rebuild" > "/tmp/$p-rebuild.log" 2>&1
	rc=$?
	echo "    $p rebuild rc=$rc"
	if [ "$rc" -ne 0 ]; then
		tail -15 "/tmp/$p-rebuild.log"
	fi
done

echo ">>> 重打镜像"
sh /mnt/d/shuios/tools/wsl-repack.sh > /tmp/repack-run.log 2>&1
rc=$?
echo "    repack rc=$rc"
tail -6 /tmp/repack-run.log
ls -l /root/test.img 2>/dev/null
