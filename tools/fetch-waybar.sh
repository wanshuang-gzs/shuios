#!/bin/bash
# 把 waybar 与 gtk-layer-shell 的源码放进本地 mirror（Buildroot 的 PRIMARY_SITE）
set -u
MIRROR=/root/shuios-mirror
mkdir -p "$MIRROR"
cd "$MIRROR" || exit 1

fetch() {
	url=$1
	file=$2
	if [ -s "$file" ]; then echo "    已有 $file"; return 0; fi
	echo "    下载 $file"
	# 先直连，失败再走 gh-proxy（GitHub 直连常常超时）
	if ! wget -q --timeout=25 -O "$file" "$url"; then
		echo "    直连失败，改用 gh-proxy"
		if ! wget -q --timeout=40 -O "$file" "https://gh-proxy.com/$url"; then
			echo "!!! 下载失败：$url"; rm -f "$file"; return 1
		fi
	fi
	ls -l "$file"
}

echo ">>> waybar 0.10.4"
fetch "https://github.com/Alexays/Waybar/archive/refs/tags/0.10.4.tar.gz" waybar-0.10.4.tar.gz

echo ">>> gtk-layer-shell 0.9.0"
fetch "https://github.com/wmww/gtk-layer-shell/archive/refs/tags/v0.9.0.tar.gz" gtk-layer-shell-0.9.0.tar.gz

echo
echo ">>> 校验（Buildroot 会核对 sha256）"
sha256sum waybar-0.10.4.tar.gz gtk-layer-shell-0.9.0.tar.gz 2>/dev/null
