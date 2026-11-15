#!/bin/bash
# 把厂商提供的 .deb 打成 shuios 的 sqfs 包（给 shui-pkg 用）。
#
# 为什么要这个：shuios 的根分区是只读 squashfs，没有 dpkg/apt，
# 第三方软件（微信、钉钉、VS Code…）只能走 shui-pkg 的「每包自带依赖闭包 +
# 挂载」模型。本脚本做三件事：
#   1) 解包 .deb（不执行任何安装脚本，纯解压）
#   2) 用 readelf 把缺的运行库从 Buildroot 的 target 里补齐（闭包）
#   3) 生成 .pkg/meta.json 并打成 .sqfs，写入软件仓库 + 更新 index.json
#
# 用法（WSL 里）：
#   tools/deb-to-sqfs.sh /path/to/wechat.deb
#   tools/deb-to-sqfs.sh /path/to/x.deb -n 自定义包名 -o /root/shuios/br2-ext/pkgrepo
#   tools/deb-to-sqfs.sh /path/to/x.deb --icon-out /root/store-repo/icons
#
# 注意：glibc ABI 是同族（都是 GNU libc），Ubuntu 上编译的二进制可以直接跑；
# 只有 musl 发行版的包（Alpine）不适用。
set -uo pipefail

BR=${BR:-/root/shuios/buildroot}
TGT=$BR/output/target
# Buildroot 没打包、但厂商程序又真的需要的库（例如网易云自带的 libpangoft2
# 依赖 libthai）：放在这里，闭包阶段会按需补进包内。
EXTRA_LIBS=${EXTRA_LIBS:-/root/shuios/br2-ext/extra-libs}
REPO=/root/shuios/br2-ext/pkgrepo
NAME=""
DEB=""
ICONOUT=""

usage() {
	sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		-n) NAME=${2:-}; shift 2 ;;
		-o) REPO=${2:-}; shift 2 ;;
		--icon-out) ICONOUT=${2:-}; shift 2 ;;
		-h|--help) usage ;;
		*) DEB=$1; shift ;;
	esac
done

[ -n "$DEB" ] && [ -f "$DEB" ] || { echo "!!! 找不到 deb：$DEB"; usage; }

WORK=$(mktemp -d /tmp/deb2sqfs.XXXXXX)
ROOT=$WORK/root
mkdir -p "$ROOT"

echo ">>> 解包 $(basename "$DEB")"
if command -v dpkg-deb >/dev/null 2>&1; then
	dpkg-deb -x "$DEB" "$ROOT" || exit 1
	CTRL=$(dpkg-deb -f "$DEB" 2>/dev/null)
else
	# 没有 dpkg-deb 时手工拆 ar 归档
	( cd "$WORK" && ar x "$DEB" ) || { echo "!!! 无法解包（缺 dpkg-deb / ar）"; exit 1; }
	for f in data.tar.*; do tar -xf "$WORK/$f" -C "$ROOT"; done
	for f in control.tar.*; do
		mkdir -p "$WORK/ctrl" && tar -xf "$WORK/$f" -C "$WORK/ctrl"
	done
	CTRL=$(cat "$WORK/ctrl/control" 2>/dev/null)
fi

pkg_field() { printf '%s\n' "$CTRL" | sed -n "s/^$1: *//p" | head -1; }
[ -n "$NAME" ] || NAME=$(pkg_field Package)
VERSION=$(pkg_field Version)
[ -n "$NAME" ] || { echo "!!! 读不到包名（用 -n 指定）"; exit 1; }
NAME=$(printf '%s' "$NAME" | tr 'A-Z' 'a-z')
echo "    包名 $NAME  版本 $VERSION"
echo "    声明依赖：$(pkg_field Depends)"

# ---------------------------------------------------------------------------
# 绝对软链改相对：包会被挂到 /var/lib/shuios/pkg/mnt/<名字>，
# 厂商包里的 /usr/bin/x -> /opt/x/x 是相对**宿主根**写的，挂载后指到系统根，
# 一定断（飞书、钉钉都有这种链）。只要目标在包内，就改写成相对路径。
# ---------------------------------------------------------------------------
fixed=0
while IFS= read -r link; do
	target=$(readlink "$link")
	case "$target" in /*) ;; *) continue ;; esac
	[ -e "$ROOT$target" ] || continue
	rel=$(realpath --relative-to="$(dirname "$link")" "$ROOT$target" 2>/dev/null) || continue
	ln -sfn "$rel" "$link" && fixed=$((fixed + 1))
done < <(find "$ROOT" -type l 2>/dev/null)
[ "$fixed" -gt 0 ] && echo "    改写绝对软链 $fixed 条"

# ---------------------------------------------------------------------------
# 图标：优先 .desktop 里 Icon= 指向的那张，其次按包名找，最后兜底任一张。
# 复制成 <包名>.<扩展名> 放进仓库 icons/，商店（shui-pkg icons）会缓存它。
# ---------------------------------------------------------------------------
ICON_NAME="$NAME.svg"
if [ -n "$ICONOUT" ]; then
	mkdir -p "$ICONOUT"
	icname=$(sed -n 's/^Icon=//p' "$ROOT"/usr/share/applications/*.desktop 2>/dev/null |
		head -1 | tr -d '\r')

	icon=""
	# 有的包（钉钉）直接写绝对路径，例如 Icon=/opt/apps/.../logo.ico
	case "$icname" in
		/*) [ -f "$ROOT$icname" ] && icon="$ROOT$icname" ;;
	esac
	icname=$(basename "$icname" 2>/dev/null || true)

	if [ -z "$icon" ]; then
		# 候选太多（Electron 的 resources 里有成百上千张 png），按
		# 「名字像不像 + 分辨率 + 文件大小」打分，别随便抓第一张 16x16 的小图。
		while IFS=$'\t' read -r score cand; do
			[ -n "$cand" ] || continue
			icon=$cand
			break
		done < <(
			find "$ROOT/usr/share/icons" "$ROOT/usr/share/pixmaps" "$ROOT/opt" \
				-maxdepth 7 -type f \
				\( -iname '*.png' -o -iname '*.svg' -o -iname '*.xpm' -o -iname '*.ico' \) \
				2>/dev/null | while IFS= read -r cand; do
				base=$(basename "$cand")
				score=0
				case "$base" in
					*"$icname"*) [ -n "$icname" ] && score=$((score + 2000)) ;;
					*"$NAME"*) score=$((score + 1000)) ;;
					logo.*|*logo*) score=$((score + 300)) ;;
				esac
				res=$(printf '%s' "$cand" | grep -oE '(512|256|128|96|64|48)' | head -1)
				[ -n "$res" ] && score=$((score + res * 2))
				case "$base" in
					*.png) score=$((score + 20)) ;;
					*.svg) score=$((score + 10)) ;;
				esac
				bytes=$(stat -c%s "$cand" 2>/dev/null || echo 0)
				score=$((score + bytes / 1024))
				printf '%s\t%s\n' "$score" "$cand"
			done | sort -rn | head -1
		)
	fi
	if [ -n "$icon" ]; then
		ext=$(printf '%s' "${icon##*.}" | tr 'A-Z' 'a-z')
		case "$ext" in png|svg|xpm|ico) ;; *) ext=png ;; esac
		# 同名旧图标先清掉：否则上一轮的 16x16 png 会盖过这一轮的 256 svg
		rm -f "$ICONOUT/$NAME".png "$ICONOUT/$NAME".svg \
			"$ICONOUT/$NAME".xpm "$ICONOUT/$NAME".ico
		# .ico/.svg 在目标系统的 gdk-pixbuf 里不一定有 loader；构建机有
		# rsvg-convert / ImageMagick 就统一转成 256x256 PNG，商店只读 PNG 最稳。
		if [ "$ext" = svg ] && command -v rsvg-convert >/dev/null 2>&1; then
			if rsvg-convert -w 256 -h 256 "$icon" -o "$ICONOUT/$NAME.png" 2>/dev/null; then
				ICON_NAME="$NAME.png"
				echo "    图标 $ICON_NAME（${icon#"$ROOT"} 转 PNG）"
			fi
		elif [ "$ext" = ico ] && command -v convert >/dev/null 2>&1; then
			if convert "${icon}[0]" -resize 256x256 -background none \
				"$ICONOUT/$NAME.png" 2>/dev/null; then
				ICON_NAME="$NAME.png"
				echo "    图标 $ICON_NAME（${icon#"$ROOT"} 转 PNG）"
			fi
		fi
		if [ "$ICON_NAME" != "$NAME.png" ] && cp -f "$icon" "$ICONOUT/$NAME.$ext"; then
			ICON_NAME="$NAME.$ext"
			echo "    图标 $ICON_NAME（来自 ${icon#"$ROOT"}）"
		fi
	else
		echo "    没找到图标，商店里会显示首字母底板"
	fi
fi

# ---------------------------------------------------------------------------
# 闭包：包内 ELF 缺少的 .so 从 target 里补
# ---------------------------------------------------------------------------
echo ">>> 补齐运行库"
missing=()
round=0
changed=1
while [ "$changed" -eq 1 ] && [ "$round" -lt 8 ]; do
	changed=0
	round=$((round + 1))
	while IFS= read -r elf; do
		head -c 4 "$elf" 2>/dev/null | grep -q ELF || continue
		while IFS= read -r so; do
			[ -n "$so" ] || continue
			# 动态加载器与 libc 核心库绝不打进包：换掉它们等于换掉整个系统的 ABI
			case "$so" in
				ld-linux*|ld64.so*|linux-vdso*) continue ;;
				libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|\
				libresolv.so.2|libutil.so.1|libgcc_s.so.1|libstdc++.so.6) continue ;;
			esac
			find "$ROOT" -name "$so" 2>/dev/null | grep -q . && continue
			src=$(find "$TGT/lib" "$TGT/usr/lib" -maxdepth 2 -name "$so" 2>/dev/null | head -1)
			if [ -n "$src" ]; then
				rel=${src#"$TGT"}
				mkdir -p "$ROOT$(dirname "$rel")"
				cp -L "$src" "$ROOT$rel"
				changed=1
			else
				missing+=("$so")
			fi
		done < <(readelf -d "$elf" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
	done < <(find "$ROOT" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null)
done

if [ ${#missing[@]} -gt 0 ]; then
	# 厂商自带的私有库目录（Qt/Electron 应用常见）：它们的启动脚本会把
	# LD_LIBRARY_PATH 直接指向这里，系统库路径会被覆盖掉，所以缺的库得
	# 同时放一份到这些目录，否则一进启动脚本就又找不到了。
	vendor_libdirs=()
	while IFS= read -r d; do
		n=$(find "$d" -maxdepth 1 -name '*.so*' 2>/dev/null | wc -l)
		[ "$n" -ge 10 ] && vendor_libdirs+=("$d")
	done < <(find "$ROOT/opt" "$ROOT/usr/lib" -mindepth 1 -maxdepth 4 -type d \
		\( -name lib -o -name libs -o -name lib64 \) 2>/dev/null)

	# 递归补库：EXTRA_LIBS 优先，其次 target；连同它自己的 NEEDED 一起补
	copy_extra_lib() {
		local so=$1 src rel
		find "$ROOT" -name "$so" 2>/dev/null | grep -q . && return 0
		src=$(find "$EXTRA_LIBS" -name "$so" 2>/dev/null | head -1)
		[ -n "$src" ] || \
			src=$(find "$TGT/lib" "$TGT/usr/lib" -maxdepth 2 -name "$so" 2>/dev/null | head -1)
		[ -n "$src" ] || return 1
		mkdir -p "$ROOT/usr/lib"
		cp -L "$src" "$ROOT/usr/lib/$so"
		local d
		for d in "${vendor_libdirs[@]}"; do
			cp -L "$src" "$d/$so"
		done
		echo "    额外补库 $so（来自 $src）"
		local dep
		while IFS= read -r dep; do
			[ -n "$dep" ] || continue
			case "$dep" in
				ld-linux*|ld64.so*|linux-vdso*) continue ;;
				libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2|librt.so.1|\
				libresolv.so.2|libutil.so.1|libgcc_s.so.1|libstdc++.so.6) continue ;;
			esac
			copy_extra_lib "$dep" || true
		done < <(readelf -d "$src" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
	}

	still=()
	for so in $(printf '%s\n' "${missing[@]}" | sort -u); do
		copy_extra_lib "$so" || still+=("$so")
	done

	if [ ${#still[@]} -gt 0 ]; then
		echo "!!! 系统里没有这些库（需要先在 defconfig 里加对应包再重建镜像）："
		printf '%s\n' "${still[@]}" | sed 's/^/      /'
	fi
fi

# ---------------------------------------------------------------------------
# 老包的「半套 GLib/GTK 栈」问题：网易云 1.2.1（2019）自带 libglib/pango/
# libmount 的旧副本，启动脚本把私有库目录排到 LD_LIBRARY_PATH 最前，结果和
# 系统的 gio/pangocairo(2.82) 混用，报 MOUNT_2_40 / pango_font_get_hb_font
# 之类的 undefined symbol。系统这套库版本一致、ABI 是超集，包内旧副本直接
# 丢掉，统一用系统的。
# ---------------------------------------------------------------------------
SYS_STACK_GLOBS=${SYS_STACK_GLOBS:-"libglib-2.0.so.* libgobject-2.0.so.* libgio-2.0.so.*
	libgmodule-2.0.so.* libgthread-2.0.so.* libpango-1.0.so.* libpangocairo-1.0.so.*
	libpangoft2-1.0.so.* libgdk_pixbuf-2.0.so.* libmount.so.* libatk-1.0.so.*
	libcairo.so.* libcairo-gobject.so.* libfontconfig.so.* libfreetype.so.*
	libharfbuzz.so.* libfribidi.so.* libgraphite2.so.* libpixman-1.so.*
	libpng16.so.* libjpeg.so.* libtiff.so.* libwebp.so.*"}
for pat in $SYS_STACK_GLOBS; do
	while IFS= read -r old; do
		[ -n "$old" ] || continue
		base=${old##*/}
		find "$TGT/lib" "$TGT/usr/lib" -maxdepth 2 -name "$base" 2>/dev/null | grep -q . || continue
		rm -f "$old" && echo "    移除包内旧库 $base（改用系统版）"
	done < <(find "$ROOT" -name "$pat" -type f 2>/dev/null)
done

# 强制额外库：FORCE_EXTRA_LIBS 里列出的库无条件从 EXTRA_LIBS 拷进包内 /usr/lib。
# 有些包需要一个和系统构建不同的同名库（例如镜像里的 GTK 只有 Wayland 后端，
# 而 QQ音乐 这类 Electron 程序要 gdk_x11_*），闭包看到 target 有同名文件就会
# 认为"已满足"，只能靠这个强制覆盖。
if [ -n "${FORCE_EXTRA_LIBS:-}" ]; then
	for so in $FORCE_EXTRA_LIBS; do
		src=$(find "$EXTRA_LIBS" -maxdepth 2 -name "$so" 2>/dev/null | head -1)
		[ -n "$src" ] || { echo "    !!! FORCE_EXTRA_LIBS 里找不到 $so"; continue; }
		mkdir -p "$ROOT/usr/lib"
		cp -L "$src" "$ROOT/usr/lib/$so"
		echo "    强制覆盖库 $so（来自 $src）"
	done
fi

# ---------------------------------------------------------------------------
# 元数据 + 打包
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/.pkg"
# 有些厂商包把主程序放在 /opt（微信）、/opt/apps/<逆域名>/files（钉钉），
# 没有 /usr/bin 入口，但 .desktop 里写的是绝对路径。这里补一个包装脚本：
# 包挂到 /var/lib/shuios/pkg/mnt/<名字>，用 readlink -f "$0" 反推挂载根再拼路径。
has_bin=$(find "$ROOT/usr/bin" "$ROOT/usr/local/bin" -maxdepth 1 \
	\( -type f -o -type l \) 2>/dev/null | head -1)
if [ -z "$has_bin" ]; then
	main=""
	# 1) 先看 .desktop 的 Exec= 是否指向包内绝对路径
	for d in "$ROOT"/usr/share/applications/*.desktop; do
		[ -f "$d" ] || continue
		exec_cmd=$(sed -n 's/^Exec=//p' "$d" | head -1 | tr -d '\r')
		cmd=${exec_cmd%% *}
		case "$cmd" in
			/*) [ -e "$ROOT$cmd" ] && { main=$cmd; break; } ;;
		esac
	done
	# 2) 再按常见布局兜底
	if [ -z "$main" ]; then
		for cand in "$ROOT/opt/$NAME/$NAME" "$ROOT/opt/$NAME/${NAME}App"; do
			[ -x "$cand" ] && { main="/opt/$NAME/${cand##*/}"; break; }
		done
	fi
	if [ -n "$main" ]; then
		mkdir -p "$ROOT/usr/bin"
		{
			printf '#!/bin/sh\n'
			printf '# 由 tools/deb-to-sqfs.sh 生成：厂商主程序在 %s\n' "$main"
			printf 'self=$(readlink -f "$0")\n'
			# self 是 <挂载点>/usr/bin/<名字>，往上三层才是挂载根
			printf 'root=$(dirname "$(dirname "$(dirname "$self")")")\n'
			printf 'LD_LIBRARY_PATH="$root/usr/lib:/usr/lib:/lib"\n'
			printf 'export LD_LIBRARY_PATH\n'
			printf 'exec "$root%s" "$@"\n' "$main"
		} > "$ROOT/usr/bin/$NAME"
		chmod 755 "$ROOT/usr/bin/$NAME"
		echo "    生成入口 /usr/bin/$NAME -> $main"
	fi
fi

# ---------------------------------------------------------------------------
# 老包兼容层：网易云 1.2.1 这类 2019 年的包有三个坑
#   1) 把安装前缀写死在 /opt（QCef 找 icudtl.dat 用），可系统根分区是只读的，
#      包又被挂到 /var/lib/shuios/pkg/mnt/<名字>，于是 CEF 起不来；
#   2) 只带 xcb 平台插件，而桌面只给 WAYLAND_DISPLAY，没有 DISPLAY；
#   3) CEF 以 root 跑必须加 --no-sandbox，否则 sandbox 起不来。
# 检测到这些特征就给 /usr/bin/<名字> 套一层 shim：把数据分区上的 /opt 挂成
# 可写、按包内 opt/ 建软链、补 DISPLAY、补 --no-sandbox。
# ---------------------------------------------------------------------------
entry="$ROOT/usr/bin/$NAME"
cef=$(find "$ROOT" -name libcef.so -type f 2>/dev/null | head -1)
# Electron 应用（VS Code、飞书这类）同样是 Chromium 内核：root 下必须 --no-sandbox
electron=$(find "$ROOT" \( -name chrome-sandbox -o -name 'app.asar' \) 2>/dev/null | head -1)
xcb_only=0
if [ -z "$(find "$ROOT" -name 'libqwayland*.so' 2>/dev/null | head -1)" ] &&
	find "$ROOT" -name 'libqxcb.so' 2>/dev/null | grep -q .; then
	xcb_only=1
fi

if { [ -n "$cef" ] || [ -n "$electron" ] || [ "$xcb_only" -eq 1 ]; } &&
	{ [ -e "$entry" ] || [ -L "$entry" ]; }; then
	if [ -L "$entry" ]; then
		real=$(readlink -f "$entry")
		rel=${real#"$ROOT"}
		# 必须先把软链删掉：直接 > 软链会写穿到厂商的启动脚本上
		rm -f "$entry"
	else
		mkdir -p "$ROOT/usr/libexec"
		mv "$entry" "$ROOT/usr/libexec/$NAME"
		rel="/usr/libexec/$NAME"
	fi
	{
		printf '#!/bin/sh\n'
		printf '# 由 tools/deb-to-sqfs.sh 生成的兼容层（老厂商包硬编码 /opt、只带 xcb、CEF 走 root）\n'
		printf 'self=$(readlink -f "$0")\n'
		printf 'root=$(dirname "$(dirname "$(dirname "$self")")")\n'
		printf 'if [ "$(id -u)" = 0 ] && [ -d "$root/opt" ]; then\n'
		printf '  mkdir -p /var/lib/shuios/opt\n'
		printf '  grep -q " /opt " /proc/mounts || mount --bind /var/lib/shuios/opt /opt 2>/dev/null\n'
		printf '  for d in "$root"/opt/*; do\n'
		printf '    [ -d "$d" ] || continue\n'
		printf '    ln -sfn "$d" "/opt/$(basename "$d")"\n'
		printf '  done\n'
		printf 'fi\n'
		[ "$xcb_only" -eq 1 ] &&
			printf 'export DISPLAY=${DISPLAY:-:0}\nexport QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-xcb}\n'
		[ -z "$cef" ] && [ -n "$electron" ] &&
			printf 'export DISPLAY=${DISPLAY:-:0}\n'
		{ [ -n "$cef" ] || [ -n "$electron" ]; } &&
			printf '[ "$(id -u)" = 0 ] && set -- --no-sandbox "$@"\n'
		# 会话里有 WAYLAND_DISPLAY 时 Chromium 会走 Wayland/Ozone，而 sway 这边的
		# dmabuf 导入是坏的（gpu/gbm_pixmap_wayland: importing the supplied dmabufs
		# failed，随后 SIGTRAP 整个进程退出）。统一走 Xwayland 最稳。
		{ [ -n "$cef" ] || [ -n "$electron" ]; } &&
			printf 'set -- --ozone-platform=x11 "$@"\n'
		# 包内自带的运行库优先于系统：像 QQ音乐 需要带 X11 后端的 GTK，
		# 而系统那套只有 Wayland 后端（FORCE_EXTRA_LIBS 会把它换进来）。
		{ [ -n "$cef" ] || [ -n "$electron" ]; } &&
			printf 'LD_LIBRARY_PATH="$root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\nexport LD_LIBRARY_PATH\n'
		# Electron 以 root 跑还要求换一个用户数据目录（/root 是 tmpfs，64M 也不够用），
		# 指到数据分区上，顺便让设置、插件、登录态能跨重启保留。
		[ -n "$electron" ] && [ -z "$cef" ] &&
			printf '[ "$(id -u)" = 0 ] && set -- --user-data-dir=/var/lib/shuios/%s-data "$@"\n' "$NAME"
		printf 'exec "$root%s" "$@"\n' "$rel"
	} > "$entry"
	chmod 755 "$entry"
	echo "    套兼容层 /usr/bin/$NAME（/opt 前缀 + DISPLAY + --no-sandbox）"
fi

# 软链（VS Code 的 /usr/bin/code 就是软链）也算入口，-executable 会跟随软链判断
bins=$(cd "$ROOT" && find usr/bin usr/sbin bin sbin -maxdepth 1 \
	\( -type f -o -type l \) -executable 2>/dev/null | sort)
desktop=$(cd "$ROOT" && find usr/share/applications -maxdepth 1 -name '*.desktop' 2>/dev/null | sort)

{
	printf '{\n  "name": "%s",\n  "version": "%s",\n  "bins": [' "$NAME" "$VERSION"
	first=1
	for b in $bins; do
		[ $first -eq 1 ] && first=0 || printf ', '
		printf '"%s"' "$b"
	done
	printf '],\n  "desktop": ['
	first=1
	for d in $desktop; do
		[ $first -eq 1 ] && first=0 || printf ', '
		printf '"%s"' "$d"
	done
	printf ']\n}\n'
} > "$ROOT/.pkg/meta.json"

echo ">>> 需要 mksquashfs"
command -v mksquashfs >/dev/null 2>&1 || {
	apt-get update -qq >/dev/null 2>&1
	apt-get install -y -qq squashfs-tools >/dev/null 2>&1
}
command -v mksquashfs >/dev/null 2>&1 || { echo "!!! 装不上 squashfs-tools"; exit 1; }

mkdir -p "$REPO/icons"
img="$REPO/$NAME-$VERSION.sqfs"
echo ">>> 打 squashfs"
# 压缩算法用 zstd 而不是 gzip：包体积只大一点，但解压快 4-5 倍，
# Electron 这类要读上千个小文件的程序冷启动能快好几秒。
mksquashfs "$ROOT" "$img" -comp zstd -Xcompression-level 6 -noappend -no-xattrs -all-root -quiet >/dev/null || exit 1
size=$(stat -c%s "$img")
sha=$(sha256sum "$img" | cut -d' ' -f1)
echo "    $img  $size 字节  sha256=$sha"

echo ">>> 更新 index.json"
python3 - "$REPO" "$NAME" "$VERSION" "$size" "$sha" "$(basename "$img")" "$ICON_NAME" <<'PY'
import json, os, sys, time
repo, name, version, size, sha, fn, icon = sys.argv[1:8]
p = os.path.join(repo, 'index.json')
idx = {"schema": 1, "generated": "", "packages": []}
if os.path.exists(p):
    with open(p) as f:
        idx = json.load(f)
idx['packages'] = [e for e in idx.get('packages', []) if e.get('name') != name]
idx['packages'].append({
    "name": name, "version": version,
    "summary": f"{name}（第三方 deb 包）", "description": f"{name} {version}",
    "categories": ["第三方"], "icon": icon,
    "size": int(size), "sha256": sha, "file": fn, "depends": [],
})
idx['packages'].sort(key=lambda e: e['name'])
idx['generated'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
with open(p, 'w') as f:
    json.dump(idx, f, ensure_ascii=False, indent=2)
print(f"    索引现在有 {len(idx['packages'])} 个包")
PY

rm -rf "$WORK"
echo ">>> 完成。仓库：$REPO"
echo "    装到设备上：shui-pkg install $NAME"
