#!/bin/bash
# 生成 shuios 软件仓库（br2-ext/pkgrepo/）：
#   对每个包，单独在 Buildroot 里构建 → 用 output/target 的前后差异算出
#   「这个包 + 它的依赖闭包」新增了哪些文件 → 打成一个 squashfs 包 →
#   从 output/target 里删掉这些文件（让系统镜像保持干净，包只存在于仓库里）。
#
# 为什么用目录快照差异，而不是 Buildroot 的 .files-list.txt：
# .files-list 只列本包自己的文件，不含依赖（例如 jq 依赖 oniguruma 的 .so）。
# 我们的包设计是「每个包自带依赖闭包」，所以必须把依赖文件一起装进去。
#
# 用法（在 WSL 里、构建过完整镜像之后跑）：
#   sh /mnt/d/shuios/tools/make-pkgrepo.sh
set -uo pipefail

BR=/root/shuios/buildroot
EXT=/root/shuios/br2-ext
TGT=$BR/output/target
OUT=$EXT/pkgrepo
STAGE=/root/pkgstage
# 被挪出 target 的文件暂存区：
#   EXTRAS —— 历次运行留下的"额外文件"（冷存，整轮都不还回 target）
#   HOLD   —— 本轮算完一个包后的闭包（下个包开算前还回 target）
# 这样即使某次运行中途失败，下次也能自动把残留清干净。
HOLD=/root/pkgstage/hold
EXTRAS=/root/pkgstage/extras
EXTRAS_FILE=/root/pkg-extras-known.txt
JOBS=${JOBS:-12}

# 包名:版本 → 对应 Buildroot 开关（版本只是写进索引的展示值）
#
# 注意：只放**镜像里没有**的包。jq/tmux/nano 已经在系统镜像内（差集为 0，无法打包）。
# GUI 应用：Buildroot 里的 pcmanfm/leafpad 都依赖 Xorg（我们是纯 Wayland），
# 所以图形应用由我们自己写（见 br2-ext/package/shui-*）。
PKGS=${PKGS:-"htop:3.3.0 libcurl:8.14.1"}

sym_of() {
	case "$1" in
		jq) echo BR2_PACKAGE_JQ ;;
		htop) echo BR2_PACKAGE_HTOP ;;
		curl) echo BR2_PACKAGE_LIBCURL ;;
		libcurl) echo BR2_PACKAGE_LIBCURL ;;
		pcmanfm) echo BR2_PACKAGE_PCMANFM ;;
		nano) echo BR2_PACKAGE_NANO ;;
		tmux) echo BR2_PACKAGE_TMUX ;;
		*) echo "" ;;
	esac
}

# 有些包需要额外打开配套开关（例如 libcurl 里的 curl 命令行工具 + TLS 后端）
extra_of() {
	case "$1" in
		libcurl|curl) echo "BR2_PACKAGE_LIBCURL_CURL=y BR2_PACKAGE_LIBCURL_MBEDTLS=y" ;;
		*) echo "" ;;
	esac
}

# 需要一起装进 target（从而进入包闭包）的附加依赖包。
# 不依赖 Buildroot 的 -show-depends：那个目标只看 _DEPENDENCIES 变量，
# 条件依赖经常漏（踩过：libcurl 的 mbedtls 没被列出来）。
deps_of() {
	case "$1" in
		libcurl|curl) echo "mbedtls" ;;
		*) echo "" ;;
	esac
}

# 用 readelf 的 DT_NEEDED 把运行库补齐：包内每个 ELF 依赖的 .so，
# 若 target 里有、包内没有，就复制进来。递归直到稳定。
# 这一步是"闭包"的最后保险，不依赖任何元数据。
close_shared_libs() {
	pkgroot=$1
	baseline=$2
	changed=1
	round=0
	while [ "$changed" -eq 1 ] && [ "$round" -lt 8 ]; do
		changed=0
		round=$((round + 1))
		for elf in $(find "$pkgroot" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null); do
			head -c 4 "$elf" 2>/dev/null | grep -q ELF || continue
			needed=$(readelf -d "$elf" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
			for so in $needed; do
				case "$so" in
					ld-linux*|ld64.so*) continue ;;
				esac
				# 包内已有？（软链也算，避免重复拷贝）
				found=$(find "$pkgroot" -name "$so" \( -type f -o -type l \) 2>/dev/null | head -1)
				[ -n "$found" ] && continue
				src=$(find "$TGT/lib" "$TGT/usr/lib" -maxdepth 2 -name "$so" 2>/dev/null | head -1)
				[ -n "$src" ] || continue
				rel=${src#"$TGT"}
				# 系统镜像里本来就有的库不用打进包（省体积，也不会过期）
				if [ -s "$baseline" ] && grep -qx -- "$rel" "$baseline"; then
					continue
				fi
				mkdir -p "$pkgroot$(dirname "$rel")"
				# -L：解引用软链，把真正的库文件按 SONAME 落进包里。
				# 否则包里会是一条指向不存在版本的断链（踩过：curl 报
				# "libcurl.so.4: cannot open shared object file"）。
				cp -L "$src" "$pkgroot$rel"
				changed=1
			done
		done
	done
	libs=$(find "$pkgroot" -name '*.so*' -type f 2>/dev/null | wc -l)
	echo "    运行库闭包：包内自带 $libs 个 .so"
}

summary_of() {
	case "$1" in
		jq) echo "命令行 JSON 处理器：给脚本和智能体用的瑞士军刀" ;;
		htop) echo "交互式进程查看器（带颜色、可搜索）" ;;
		pcmanfm) echo "图形文件管理器" ;;
		nano) echo "简单易用的终端文本编辑器" ;;
		tmux) echo "终端复用器：一个窗口里开很多会话" ;;
		*) echo "" ;;
	esac
}

fail=0

snapshot() {
	( cd "$TGT" && find . \( -type f -o -type l \) 2>/dev/null ) | sort
}

need_mksquashfs() {
	command -v mksquashfs >/dev/null 2>&1 && return 0
	echo ">>> 安装 squashfs-tools"
	apt-get update -qq >/dev/null 2>&1
	apt-get install -y -qq squashfs-tools >/dev/null 2>&1
	command -v mksquashfs >/dev/null 2>&1
}

echo ">>> 检查依赖"
if [ ! -d "$TGT" ]; then
	echo "!!! 找不到 $TGT，请先完整构建一次镜像"
	exit 1
fi
if ! need_mksquashfs; then
	echo "!!! 装不上 mksquashfs（squashfs-tools），无法打包"
	exit 1
fi

rm -rf "$OUT" "$STAGE"
rm -f /tmp/pkg-index-lines
mkdir -p "$OUT/icons" "$STAGE" "$HOLD" "$EXTRAS"

# 上一轮遗留的额外文件先挪进冷存，避免它们污染本轮基线与最终镜像
if [ -f "$EXTRAS_FILE" ]; then
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		[ -e "$TGT/$rel" ] || continue
		mkdir -p "$EXTRAS/$(dirname "$rel")"
		mv -f "$TGT/$rel" "$EXTRAS/$rel" 2>/dev/null || true
	done < "$EXTRAS_FILE"
	echo ">>> 已清理上轮残留 $(wc -l < "$EXTRAS_FILE") 条"
fi

# 把暂存区里的文件还回 target，恢复成干净基线
restore_target() {
	[ -d "$HOLD" ] || return 0
	( cd "$HOLD" && find . \( -type f -o -type l \) 2>/dev/null ) | while IFS= read -r rel; do
		mkdir -p "$TGT/$(dirname "$rel")"
		cp -a "$HOLD/$rel" "$TGT/$rel"
	done
}

# 把文件从 target 挪进暂存区（不是删除——删除会让下一个包丢依赖）
stash_from_target() {
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		rel=${rel#./}
		mkdir -p "$HOLD/$(dirname "$rel")"
		mv -f "$TGT/$rel" "$HOLD/$rel" 2>/dev/null || true
	done
}

cd "$BR" || exit 1

for spec in $PKGS; do
	name=${spec%%:*}
	version=${spec##*:}
	sym=$(sym_of "$name")
	if [ -z "$sym" ]; then
		echo "!!! 未知包 $name（先在 sym_of() 里登记）"
		fail=1
		continue
	fi

	echo
	echo "================ $name ($version) ================"
	# 先把上一个包的闭包还回 target，保证差异是相对干净基线算的
	restore_target
	base_list=$(snapshot)
	printf '%s\n' "$base_list" > /tmp/pkg-base.lst
	extra=$(extra_of "$name")

	# 1) 打开开关并只构建这一个包
	if ! make -s BR2_EXTERNAL="$EXT" "$sym=y" $extra olddefconfig >/tmp/pkg-$name.log 2>&1; then
		echo "!!! olddefconfig 失败，见 /tmp/pkg-$name.log"
		fail=1
		continue
	fi
	# 先构建（已构建过则是空跑），再**强制重新安装**到 target：
	# 上一轮打包后我们把文件从 target 删掉了，但 Buildroot 的 install stamp 还在，
	# 不 reinstall 的话 `make <pkg>` 不会把文件装回来（踩过：差集永远是 0）。
	if ! make -s BR2_EXTERNAL="$EXT" "$sym=y" $extra BR2_PRIMARY_SITE=file:///root/shuios-mirror \
		-j"$JOBS" "$name" >>/tmp/pkg-$name.log 2>&1; then
		echo "!!! 构建 $name 失败，见 /tmp/pkg-$name.log"
		tail -n 15 /tmp/pkg-$name.log | sed 's/^/    /'
		fail=1
		make -s BR2_EXTERNAL="$EXT" shuios_x86_64_defconfig >/dev/null 2>&1
		continue
	fi
	# 依赖也要装进 target：上一轮我们把它们挪出去了，Buildroot 的 install
	# stamp 还在，所以必须 -reinstall 才会把文件放回来。
	for d in $(deps_of "$name"); do
		echo "    依赖包 $d"
		make -s BR2_EXTERNAL="$EXT" "$d" >>/tmp/pkg-$name.log 2>&1 || true
		make -s BR2_EXTERNAL="$EXT" "$d-reinstall" >>/tmp/pkg-$name.log 2>&1 || true
	done
	if ! make -s BR2_EXTERNAL="$EXT" "$sym=y" $extra \
		"$name-reinstall" >>/tmp/pkg-$name.log 2>&1; then
		echo "!!! 重新安装 $name 失败，见 /tmp/pkg-$name.log"
		tail -n 15 /tmp/pkg-$name.log | sed 's/^/    /'
		fail=1
		make -s BR2_EXTERNAL="$EXT" shuios_x86_64_defconfig >/dev/null 2>&1
		continue
	fi

	# 2) 差异 = 新增文件（含依赖）
	after_list=$(snapshot)
	new_files=$(comm -13 <(echo "$base_list") <(echo "$after_list"))
	count=$(echo "$new_files" | grep -c . || true)
	echo "    新增文件 $count 个"

	if [ "$count" -eq 0 ]; then
		echo "!!! $name 没有往 target 里装任何文件，跳过"
		fail=1
		continue
	fi

	# 版本号以 Buildroot 实际构建出来的目录为准（手写的 spec 版本容易过期）
	built=$(ls -d "$BR/output/build/$name-"* 2>/dev/null | head -1)
	if [ -n "$built" ]; then
		version=${built##*/}
		version=${version#"$name"-}
	fi

	# 3) 暂存（保留软链与权限）
	pkgroot="$STAGE/$name"
	mkdir -p "$pkgroot"
	echo "$new_files" | while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		rel=${rel#./}
		mkdir -p "$pkgroot/$(dirname "$rel")"
		cp -a "$TGT/$rel" "$pkgroot/$rel"
	done

	# 4) 补齐运行库，再生成包内元数据
	close_shared_libs "$pkgroot" /tmp/pkg-base.lst
	bins=""
	for d in usr/bin usr/sbin bin sbin; do
		[ -d "$pkgroot/$d" ] || continue
		for f in "$pkgroot/$d"/*; do
			[ -f "$f" ] || continue
			[ -x "$f" ] || continue
			bins="$bins$d/$(basename "$f")"$'\n'
		done
	done
	desktop=""
	if [ -d "$pkgroot/usr/share/applications" ]; then
		for f in "$pkgroot"/usr/share/applications/*.desktop; do
			[ -f "$f" ] || continue
			desktop="$desktop"usr/share/applications/"$(basename "$f")"$'\n'
		done
	fi

	mkdir -p "$pkgroot/.pkg"
	{
		echo "{"
		printf '  "name": "%s",\n' "$name"
		printf '  "version": "%s",\n' "$version"
		printf '  "bins": ['
		first=1
		while IFS= read -r b; do
			[ -n "$b" ] || continue
			[ $first -eq 1 ] && first=0 || printf ', '
			printf '"%s"' "$b"
		done <<< "$bins"
		printf '],\n'
		printf '  "desktop": ['
		first=1
		while IFS= read -r d; do
			[ -n "$d" ] || continue
			[ $first -eq 1 ] && first=0 || printf ', '
			printf '"%s"' "$d"
		done <<< "$desktop"
		printf ']\n'
		echo "}"
	} > "$pkgroot/.pkg/meta.json"

	# 5) 打 squashfs
	img="$OUT/$name-$version.sqfs"
	if ! mksquashfs "$pkgroot" "$img" -comp gzip -noappend -no-xattrs -all-root -quiet >/dev/null; then
		echo "!!! mksquashfs 失败"
		fail=1
		continue
	fi
	size=$(stat -c%s "$img")
	sha=$(sha256sum "$img" | cut -d' ' -f1)
	echo "    生成 $(basename "$img")  $size 字节  sha256=$sha"

	# 6) 把闭包文件挪出 target（不是删除），保持系统镜像干净
	echo "$new_files" | stash_from_target
	# 清掉因此变空的目录（不删 target 顶层）
	(cd "$TGT" && find . -mindepth 2 -type d -empty -delete 2>/dev/null) || true

	echo "$name|$version|$size|$sha|$(basename "$img")" >> /tmp/pkg-index-lines
done

# 恢复 defconfig（确保后续 make 用的是干净的配置）
echo
echo ">>> 还原 defconfig"
make -s BR2_EXTERNAL="$EXT" shuios_x86_64_defconfig >/dev/null 2>&1

# 7) 生成索引
echo ">>> 生成 index.json"
python3 - "$OUT" <<'PY'
import json, os, sys, time

out = sys.argv[1]
lines = []
if os.path.exists('/tmp/pkg-index-lines'):
    with open('/tmp/pkg-index-lines') as f:
        lines = [l.strip() for l in f if l.strip()]

summaries = {
    'jq': ('命令行 JSON 处理器：给脚本和智能体用的瑞士军刀', '开发', ['jq']),
    'htop': ('交互式进程查看器（带颜色、可搜索）', '系统', ['htop']),
    'libcurl': ('命令行 HTTP 客户端（自带 TLS，可抓 https）', '网络', ['curl']),
    'curl': ('命令行 HTTP 客户端（自带 TLS，可抓 https）', '网络', ['curl']),
    'pcmanfm': ('图形文件管理器', '桌面', ['pcmanfm']),
    'nano': ('简单易用的终端文本编辑器', '开发', ['nano']),
    'tmux': ('终端复用器：一个窗口里开很多会话', '开发', ['tmux']),
    'shui-notes': ('氵记事本：把想法写下来', '桌面', ['shui-notes']),
}

packages = []
for line in lines:
    name, version, size, sha, fn = line.split('|')
    summary, cat, unused = summaries.get(name, (name, '其他', []))
    packages.append({
        'name': name,
        'version': version,
        'summary': summary,
        'description': summary,
        'categories': [cat],
        'icon': f'{name}.svg',
        'size': int(size),
        'sha256': sha,
        'file': fn,
        'depends': [],
    })

index = {
    'schema': 1,
    'generated': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'packages': packages,
}
with open(os.path.join(out, 'index.json'), 'w') as f:
    json.dump(index, f, ensure_ascii=False, indent=2)
print(f'    {len(packages)} 个包写入 index.json')
PY

# 8) 生成图标（简单 SVG，配色跟桌面一致）
python3 - "$OUT" <<'PY'
import os, sys

out = sys.argv[1]
icons = {
    'jq': ('#2daed9', 'JSON 花括号'),
    'htop': ('#7ad17a', '进程条'),
    'libcurl': ('#d9b02d', '网络箭头'),
    'curl': ('#d9b02d', '网络箭头'),
    'pcmanfm': ('#d9b02d', '文件夹'),
    'nano': ('#c86dd7', '文本行'),
    'tmux': ('#2dd9b0', '分屏'),
}
for name, (color, _label) in icons.items():
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <rect x="2" y="2" width="60" height="60" rx="14" fill="#1b2028" stroke="{color}" stroke-width="3"/>
  <g fill="none" stroke="{color}" stroke-width="4" stroke-linecap="round">
    <path d="M22 20 L14 32 L22 44"/>
    <path d="M42 20 L50 32 L42 44"/>
    <path d="M36 16 L28 48"/>
  </g>
</svg>
'''
    with open(os.path.join(out, 'icons', f'{name}.svg'), 'w') as f:
        f.write(svg)
print(f'    图标 {len(icons)} 个')
PY

rm -f /tmp/pkg-index-lines
# 记下本轮所有被挪走的文件；同时把还留在 target 里的也收进冷存。
# 为什么还要多这一步：restore_target 会把上个包的闭包还回 target 以便算差集，
# 而最后只收回"最后一个包"的 new_files，前面的包就会残留在 target 里
# （踩过：镜像里莫名其妙出现了 /usr/bin/htop）。
newlist=/tmp/pkg-extras-new.txt
{
	[ -d "$EXTRAS" ] && ( cd "$EXTRAS" && find . -type f ) | sed 's#^\.##'
	[ -d "$HOLD" ] && ( cd "$HOLD" && find . -type f ) | sed 's#^\.##'
} | sort -u > "$newlist"
cp -f "$newlist" "$EXTRAS_FILE"

while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	[ -e "$TGT/$rel" ] || continue
	mkdir -p "$EXTRAS/$(dirname "$rel")"
	mv -f "$TGT/$rel" "$EXTRAS/$rel" 2>/dev/null || true
done < "$newlist"
(cd "$TGT" && find . -mindepth 2 -type d -empty -delete 2>/dev/null) || true

echo ">>> 额外文件清单已更新：$(wc -l < "$EXTRAS_FILE") 条 → $EXTRAS_FILE"

echo
echo ">>> 仓库内容"
ls -lh "$OUT" | sed 's/^/    /'

# 同步回 Windows 侧，方便查看/存档（构建时 wsl-repack.sh 会排除这个目录，
# 避免 rsync --delete 把它删掉）
if [ -d /mnt/d/shuios/br2-ext ]; then
	rm -rf /mnt/d/shuios/br2-ext/pkgrepo
	cp -a "$OUT" /mnt/d/shuios/br2-ext/pkgrepo && echo ">>> 已同步到 /mnt/d/shuios/br2-ext/pkgrepo"
fi
echo
if [ "$fail" -ne 0 ]; then
	echo "!!! 有包构建失败（见上面日志）"
	exit 1
fi
echo ">>> 完成：$OUT"
