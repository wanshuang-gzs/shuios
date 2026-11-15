#!/bin/sh
# 修 NetSurf 的 gresource 生成：glib-compile-resources 的 preprocess="xml-stripblanks"
# 会调用 host 的 xmllint；Ubuntu 云镜像里没有 libxml2-utils，于是子进程返回 1：
#   frontends/gtk/res/netsurf.gresource.xml: Child process exited with code 1.
set -eu

echo ">>> 安装 libxml2-utils（提供 xmllint）"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq --no-install-recommends libxml2-utils || true
command -v xmllint && xmllint --version 2>&1 | head -1

BR=/root/shuios/buildroot
cd "$BR"

echo ">>> 清理 netsurf 后继续"
rm -rf "$BR/output/build/netsurf-"*

exec make -s BR2_EXTERNAL=/root/shuios/br2-ext \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12
