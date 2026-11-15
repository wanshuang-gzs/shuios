#!/usr/bin/env bash
# 为 Buildroot 预取源码包到本地扁平镜像目录，再用 BR2_PRIMARY_SITE 指过去。
#
# 三级下载策略（按速度顺序）：
#   1. 国内加速：清华 TUNA（gnu/kernel/sourceforge，约 3.8 MB/s）、
#      gh-proxy.com（github release/archive，约 260 KB/s）
#   2. Buildroot 官方源镜像 sources.buildroot.net（按包分目录，约 100 KB/s）
#   3. 原始 URL（cairographics / savannah / netsurf-browser 等，常常只有几十 KB/s）
#
# 镜像只影响下载速度：Buildroot 仍会校验每个包的 sha256。
#
# 用法：
#   tools/fetch-deps.sh
#   TUNA=... GHPROXY=... JOBS=12 tools/fetch-deps.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BR_DIR="${BR_DIR:-$ROOT/buildroot}"
BR2_EXT="${BR2_EXT:-$ROOT/br2-ext}"
MIRROR="${MIRROR:-$HOME/shuios-mirror}"
TUNA="${TUNA:-https://mirrors.tuna.tsinghua.edu.cn}"
GHPROXY="${GHPROXY:-https://gh-proxy.com}"
SBR="${SBR:-https://sources.buildroot.net}"
JOBS="${JOBS:-10}"

[ -d "$BR_DIR" ] || { echo "找不到 Buildroot：$BR_DIR" >&2; exit 1; }
mkdir -p "$MIRROR"

translate() {
	local u="$1" ver rel
	case "$u" in
		*ftp.gnu.org/gnu/*|*/ftpmirror.gnu.org/gnu/*)
			printf '%s/gnu/%s\n' "$TUNA" "${u#*/gnu/}" ;;
		*cdn.kernel.org/pub/linux/kernel/*|*www.kernel.org/pub/linux/kernel/*|*mirrors.edge.kernel.org/pub/linux/kernel/*)
			printf '%s/kernel/%s\n' "$TUNA" "${u#*/kernel/}" ;;
		*downloads.sourceforge.net/*|*download.sourceforge.net/*)
			printf '%s/sourceforge/%s\n' "$TUNA" "${u#*sourceforge.net/}" ;;
		*/cmake.org/files/v*/*)
			ver="$(basename "$u")"
			rel="$(printf '%s' "$u" | sed -n 's|.*/files/\(v[0-9.]*\)/.*|\1|p')"
			if [ -n "$rel" ]; then
				printf '%s/https://github.com/Kitware/CMake/releases/download/%s/%s\n' "$GHPROXY" "$rel" "$ver"
			else
				printf '%s\n' "$u"
			fi ;;
		*/github.com/*|*codeload.github.com/*)
			printf '%s/%s\n' "$GHPROXY" "$u" ;;
		*)
			printf '%s\n' "$u" ;;
	esac
}

echo ">>> 生成包清单"
if [ ! -f "$BR_DIR/.config" ]; then
	make -C "$BR_DIR" -s --no-print-directory BR2_EXTERNAL="$BR2_EXT" shuios_x86_64_defconfig >/dev/null 2>&1 || true
fi

echo ">>> 解析 show-info"
INFO="$(mktemp)"
make -C "$BR_DIR" -s --no-print-directory BR2_EXTERNAL="$BR2_EXT" show-info 2>/dev/null \
	| sed -n '/^{/,$p' > "$INFO"
[ -s "$INFO" ] || { echo "show-info 没有输出" >&2; exit 1; }

# 每行输出：<原始URL>\t<Buildroot 官方镜像URL>
PAIRS="$(mktemp)"
python3 - "$INFO" > "$PAIRS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
seen = set()
for _pkg, v in data.items():
    dl = v.get("dl_dir") or ""
    for d in (v.get("downloads") or []):
        src = d.get("source") or ""
        if not src:
            continue
        mirror = f"https://sources.buildroot.net/{dl}/{src}" if dl else ""
        for uri in (d.get("uris") or []):
            site = uri
            if "+" in site:
                scheme, rest = site.split("+", 1)
                scheme = scheme.split("|")[0]
                if rest.startswith("http"):
                    site = rest
                elif rest.startswith("//"):
                    site = scheme + ":" + rest
                else:
                    site = scheme + "://" + rest.lstrip("/")
            if not site.startswith("http"):
                continue
            url = site.rstrip("/") + "/" + src
            if url in seen:
                continue
            seen.add(url)
            print(url + "\t" + mirror)
PY

echo "    候选下载 URL：$(wc -l < "$PAIRS")"

fetch_one() {
	local url="$1" mirror="$2" file alt
	file="$(basename "$url")"
	case "$file" in
		*.tar.gz|*.tar.xz|*.tar.bz2|*.tgz|*.zip|*.crate|*.tar) ;;
		*) return 0 ;;
	esac
	[ -s "$MIRROR/$file" ] && return 0

	# 1. 国内加速
	alt="$(translate "$url")"
	if [ "$alt" != "$url" ]; then
		if curl -fsSL --retry 2 --connect-timeout 15 --max-time 600 \
				-o "$MIRROR/$file.part" "$alt" 2>/dev/null; then
			mv "$MIRROR/$file.part" "$MIRROR/$file"
			return 0
		fi
	fi
	# 2. Buildroot 官方镜像
	if [ -n "$mirror" ]; then
		if curl -fsSL --retry 2 --connect-timeout 15 --max-time 600 \
				-o "$MIRROR/$file.part" "$mirror" 2>/dev/null; then
			mv "$MIRROR/$file.part" "$MIRROR/$file"
			printf '    [ok/sbr] %s\n' "$file"
			return 0
		fi
	fi
	# 3. 原始源（给足时间但别无限等）
	if curl -fsSL --retry 1 --connect-timeout 15 --max-time 420 \
			-o "$MIRROR/$file.part" "$url" 2>/dev/null; then
		mv "$MIRROR/$file.part" "$MIRROR/$file"
		printf '    [ok/orig] %s\n' "$file"
		return 0
	fi
	rm -f "$MIRROR/$file.part"
	printf '    [FAIL] %s\n' "$url" >&2
	return 0
}

echo ">>> 下载到 $MIRROR（3 级回退）"
export -f fetch_one translate
export MIRROR TUNA GHPROXY SBR
while IFS=$'\t' read -r u m; do
	printf '%s\n%s\n' "$u" "${m:-}";
done < "$PAIRS" | xargs -r -d '\n' -n 2 -P "$JOBS" bash -c 'fetch_one "$@"' _

echo
echo ">>> 镜像：$(du -sh "$MIRROR" | cut -f1)，文件数：$(ls -1 "$MIRROR" | wc -l)"
echo ">>> 构建时请加：BR2_PRIMARY_SITE=file://$MIRROR"
echo "$MIRROR" > "$ROOT/.primary-site"
