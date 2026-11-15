#!/bin/sh
# 补齐 host 侧构建依赖后继续构建。
#
# 背景：NetSurf 构建过程中会用 host 的 groff 把 man 页转成 HTML 塞进 gresource，
# 而 Ubuntu 云镜像里只有 groff-base，缺 html 设备的 DESC 文件，报：
#   groff: fatal error: cannot load 'DESC' description file for device 'html'
set -eu

echo ">>> 安装 host 依赖（groff / xsltproc / 图像工具）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends groff xsltproc imagemagick netpbm socat || true

echo ">>> 验证 groff html 设备"
printf '.TH TEST 1\n.SH NAME\ntest\n' | groff -Thtml >/dev/null && echo "    groff -Thtml OK" || echo "    groff -Thtml 仍失败"

BR=/root/shuios/buildroot
cd "$BR"

echo ">>> 清理失败的 netsurf 后继续"
rm -rf "$BR/output/build/netsurf-"*

exec make -s BR2_EXTERNAL=/root/shuios/br2-ext \
	BR2_PRIMARY_SITE=file:///root/shuios-mirror -j12
