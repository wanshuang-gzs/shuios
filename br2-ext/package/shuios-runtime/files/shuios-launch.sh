#!/bin/sh
# shuios 应用启动器：收集可用应用，交给 dmenu 选择后启动。
#
# 为什么自己写：Buildroot 里没有 rofi/wofi，dmenu-wayland 只有"从 stdin 读列表"
# 的能力。这里把 .desktop 文件解析成"显示名 -> 命令行"的映射，
# 选完直接 exec。以后 v0.2 会用 GTK3 写带图标的图形启动器替换它。
set -u

MAP=$(mktemp /tmp/shuios-launch.XXXXXX)
trap 'rm -f "$MAP"' EXIT

emit() {
	# $1 显示名  $2 命令行
	printf '%s\t%s\n' "$1" "$2" >> "$MAP"
}

# 1) .desktop 文件
for d in /usr/share/applications/*.desktop; do
	[ -f "$d" ] || continue
	name=$(sed -n 's/^Name=//p' "$d" | head -n 1)
	cmd=$(sed -n 's/^Exec=//p' "$d" | head -n 1 | sed 's/%[fFuUdDnNickvm]//g')
	if [ -n "$name" ] && [ -n "$cmd" ]; then
		emit "$name" "$cmd"
	fi
done

# 2) shuios 自带的应用
emit "shui（AI 原生 shell）" "foot -e /usr/bin/shui"
emit "浏览器（links）" "foot -e env TERM=xterm-256color /usr/bin/links"
emit "文件管理（/workspace）" "foot -e /usr/bin/mc /workspace"
emit "系统状态" "foot -e /usr/bin/shui-ctl status"
emit "MCP 工具" "foot -e /usr/bin/shui-ctl tools"

SEL=$(sort -u "$MAP" | cut -f1 | dmenu -i -p 'shuios >' -l 20) || exit 0
[ -z "$SEL" ] && exit 0

CMD=$(sort -u "$MAP" | awk -F'\t' -v s="$SEL" '$1 == s { print $2; exit }')
[ -z "$CMD" ] && exit 0

# 后台启动，避免阻塞 sway
exec sh -c "$CMD" >/dev/null 2>&1 &
