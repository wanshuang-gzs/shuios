#!/bin/bash
# 丰富软件商店：按 tools/store-catalog.json 下载厂商 deb → 打成 sqfs →
# 汇总成一份可远程分发的仓库目录（index.json + icons/ + *.sqfs）。
#
# 为什么单独建一个仓库目录，而不是塞回 br2-ext/pkgrepo：
#   镜像内置仓库只放"离线也要能用"的小包；QQ/微信/WPS 这类几十上百 MB 的
#   应用放远程仓库（HTTP），镜像体积不变，点安装时再下载。
#
# 用法（WSL 里）：
#   tools/fetch-store-catalog.sh                 # 处理目录里的全部应用
#   tools/fetch-store-catalog.sh qq wps-office   # 只处理指定应用
#   tools/fetch-store-catalog.sh --download-only # 只下载 deb，不打包
#   REPO=/root/store-repo SYNC= tools/fetch-store-catalog.sh
#
# 跑完后把 REPO 目录用任意 HTTP 服务发出去。Windows 上没装 Python 的话，
# 直接用仓库里的 PowerShell 小服务（只读静态文件，支持 GET/HEAD）：
#   powershell -ExecutionPolicy Bypass -File tools\serve-store-repo.ps1
# 然后让设备指向它（根分区只读，写数据分区上的覆盖配置）：
#   echo 'repo = http://<宿主机地址>:8099' > /var/lib/shuios/pkg/repo.conf
# 再点商店的「刷新」（或 shui-pkg update）。
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CATALOG=${CATALOG:-$HERE/store-catalog.json}
DEB2SQFS=$HERE/deb-to-sqfs.sh
REPO=${REPO:-/root/store-repo}
DEBDIR=${DEBDIR:-/root/debdl}
SYNC=${SYNC-/mnt/d/shuios/store-repo}
DOWNLOAD_ONLY=0
ONLY=()

while [ $# -gt 0 ]; do
	case "$1" in
		--download-only) DOWNLOAD_ONLY=1; shift ;;
		-o) REPO=${2:-}; shift 2 ;;
		--debdir) DEBDIR=${2:-}; shift 2 ;;
		-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) ONLY+=("$1"); shift ;;
	esac
done

[ -f "$CATALOG" ] || { echo "!!! 找不到目录文件：$CATALOG"; exit 1; }
mkdir -p "$REPO/icons" "$DEBDIR"
[ -f "$REPO/index.json" ] || echo '{"schema":1,"generated":"","packages":[]}' > "$REPO/index.json"

# 目录 → TSV：name、url、file、source
# 用 | 而不是制表符：空字段（比如 wechat 没有 url）在 IFS=tab 下会被
# 折叠，后面的 source 就会顶到 file 的位置（踩过）。
python3 - "$CATALOG" <<'PY' > /tmp/store-catalog.tsv
import json, sys
cat = json.load(open(sys.argv[1], encoding='utf-8'))
for a in cat.get('apps', []):
    print('|'.join([
        a.get('name', ''), a.get('url', ''),
        a.get('file', ''), a.get('source', ''),
        a.get('title', ''),
    ]))
PY

wanted() {
	[ ${#ONLY[@]} -eq 0 ] && return 0
	local n
	for n in "${ONLY[@]}"; do [ "$n" = "$1" ] && return 0; done
	return 1
}

# 没拿到官方图标时，生成一个跟桌面同风格的首字母 SVG（商店会回退到首字母底板，
# 这张图只是让远程仓库里也有图标可用）
make_fallback_icon() {
	local name=$1 title=${2:-}
	# 已经有厂商图标（不管什么扩展名）就不覆盖
	if compgen -G "$REPO/icons/$name.*" >/dev/null; then
		return 0
	fi
	local initial
	initial=$(python3 -c 'import sys; s=sys.argv[1] or sys.argv[2]; print(s[0])' "$title" "$name")
	cat > "$REPO/icons/$name.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect x="4" y="4" width="120" height="120" rx="24" fill="#181C22" stroke="#292E36" stroke-width="2"/>
  <text x="64" y="82" font-family="sans-serif" font-size="56" font-weight="bold" fill="#9AA4AE" text-anchor="middle">$initial</text>
</svg>
SVG
}

fail=0
while IFS='|' read -r name url file source title; do
	[ -n "$name" ] || continue
	wanted "$name" || continue
	echo
	echo "================ $name ================"

	deb=""
	if [ -n "$url" ] && [ -n "$file" ]; then
		deb="$DEBDIR/$file"
		# 只有能完整列出数据段才算下完（control 段在文件头，半截包也能读出来）
		if [ -s "$deb" ] && dpkg-deb -c "$deb" >/dev/null 2>&1; then
			echo ">>> 已有 $file，跳过下载"
		else
			echo ">>> 下载 $file"
			if ! curl -L --fail --retry 3 --retry-delay 3 -C - \
				-A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120 Safari/537.36' \
				--max-time 1800 -o "$deb" "$url"; then
				echo "!!! 下载失败：$url"
				fail=1
				continue
			fi
		fi
	fi

	if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
		make_fallback_icon "$name" "$title"
		continue
	fi

	if [ -n "$deb" ]; then
		"$DEB2SQFS" "$deb" -n "$name" -o "$REPO" --icon-out "$REPO/icons" || {
			echo "!!! 打包 $name 失败"
			fail=1
			continue
		}
	elif [ -n "$source" ]; then
		# 已经在本地仓库里的包（例如预装的微信）：直接复制 + 补索引
		if [ ! -f "$source" ]; then
			echo "!!! 找不到 $source，跳过 $name"
			fail=1
			continue
		fi
		base=$(basename "$source")
		version=${base#"$name"-}
		version=${version%.sqfs}
		cp -f "$source" "$REPO/$base"
		size=$(stat -c%s "$REPO/$base")
		sha=$(sha256sum "$REPO/$base" | cut -d' ' -f1)
		python3 - "$REPO" "$name" "$version" "$size" "$sha" "$base" <<'PY'
import json, os, sys, time
repo, name, version, size, sha, fn = sys.argv[1:7]
p = os.path.join(repo, 'index.json')
idx = json.load(open(p)) if os.path.exists(p) else {"schema": 1, "packages": []}
idx['packages'] = [e for e in idx.get('packages', []) if e.get('name') != name]
idx['packages'].append({
    "name": name, "version": version,
    "summary": name, "description": name,
    "icon": f"{name}.png", "size": int(size), "sha256": sha,
    "file": fn, "depends": [],
})
idx['generated'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
json.dump(idx, open(p, 'w'), ensure_ascii=False, indent=2)
PY
		echo "    已收录 $base（$size 字节）"
	else
		echo "!!! $name 既没有 url 也没有 source"
		fail=1
		continue
	fi

	# 厂商图标能拿到就用厂商的；拿不到补一张首字母图（不覆盖已有文件）
	make_fallback_icon "$name" "$title"
done < /tmp/store-catalog.tsv

[ "$DOWNLOAD_ONLY" -eq 1 ] && { echo; echo ">>> 只下载：deb 在 $DEBDIR"; exit 0; }

# ---------------------------------------------------------------------------
# 并入镜像内置仓库里的小包（htop、curl 等）：换成远程仓库后它们不该消失。
# 同名包以已打好的为准，不覆盖。
# ---------------------------------------------------------------------------
SEED=${SEED_REPO:-/root/shuios/br2-ext/pkgrepo}
if [ -d "$SEED" ] && [ "$SEED" != "$REPO" ]; then
	echo
	echo ">>> 并入内置仓库的小包"
	for f in "$SEED"/*.sqfs; do
		[ -e "$f" ] || continue
		[ -e "$REPO/$(basename "$f")" ] || cp -f "$f" "$REPO/"
	done
	if [ -d "$SEED/icons" ]; then
		cp -n "$SEED/icons/." "$REPO/icons/" 2>/dev/null || true
		# 图标统一转 PNG（目标系统的 gdk-pixbuf 不一定带 SVG loader）
		if command -v rsvg-convert >/dev/null 2>&1; then
			for f in "$REPO"/icons/*.svg; do
				[ -f "$f" ] || continue
				[ -f "${f%.svg}.png" ] ||
					rsvg-convert -w 256 -h 256 "$f" -o "${f%.svg}.png" 2>/dev/null || true
			done
		fi
	fi
	python3 - "$SEED/index.json" "$REPO/index.json" <<'PY'
import json, os, sys
seed, dst = sys.argv[1:3]
if os.path.exists(seed):
    s = json.load(open(seed, encoding='utf-8'))
    d = json.load(open(dst, encoding='utf-8'))
    have = {e['name'] for e in d['packages']}
    added = [e for e in s.get('packages', []) if e['name'] not in have]
    d['packages'] = added + d['packages']
    json.dump(d, open(dst, 'w'), ensure_ascii=False, indent=2)
    print('    并入', [e['name'] for e in added] or '无')
PY
fi

# ---------------------------------------------------------------------------
# 把目录里的中文名/简介/分类/精选位合并进 index.json
# ---------------------------------------------------------------------------
echo
echo ">>> 合并目录元数据到 index.json"
python3 - "$CATALOG" "$REPO" <<'PY'
import json, os, sys

cat_path, repo = sys.argv[1:3]
cat = json.load(open(cat_path, encoding='utf-8'))
apps = {a['name']: a for a in cat.get('apps', []) if a.get('name')}
idx_path = os.path.join(repo, 'index.json')
idx = json.load(open(idx_path, encoding='utf-8'))
by_name = {e['name']: e for e in idx.get('packages', [])}

icons = os.listdir(os.path.join(repo, 'icons')) if os.path.isdir(os.path.join(repo, 'icons')) else []

def pick_icon(name, declared):
    # 实际打包出来的扩展名可能和目录里写的不一样（png/svg），以磁盘为准
    stem = os.path.splitext(declared)[0] if declared else name
    for ext in ('.png', '.svg', '.xpm', '.ico'):
        if f'{stem}{ext}' in icons:
            return f'{stem}{ext}'
    for ext in ('.png', '.svg', '.xpm', '.ico'):
        if f'{name}{ext}' in icons:
            return f'{name}{ext}'
    return declared or f'{name}.png'

for name, a in apps.items():
    e = by_name.get(name)
    if not e:
        continue
    e['title'] = a.get('title', '')
    e['developer'] = a.get('developer', '')
    e['featured'] = bool(a.get('featured', False))
    e['summary'] = a.get('summary', e.get('summary', ''))
    e['description'] = a.get('description', e.get('description', ''))
    e['categories'] = a.get('categories', e.get('categories', []))
    e['icon'] = pick_icon(name, a.get('icon', ''))

order = [n for n in apps if n in by_name]
rest = [n for n in by_name if n not in order]
idx['packages'] = [by_name[n] for n in order + rest]
# 图标统一用 PNG（SVG 在目标系统上可能没有 loader，会退回首字母）
for e in idx['packages']:
    icon = e.get('icon', '')
    if icon.endswith('.svg') and f'{icon[:-4]}.png' in icons:
        e['icon'] = f'{icon[:-4]}.png'
json.dump(idx, open(idx_path, 'w'), ensure_ascii=False, indent=2)
print(f"    {len(idx['packages'])} 个包")
for e in idx['packages']:
    star = '★' if e.get('featured') else ' '
    print(f"    {star} {e['name']:<20} {e.get('title',''):<18} {e.get('version','')}")
PY

# 同步到 Windows 侧，方便用 python -m http.server 直接发出去（不删旧文件）
if [ -n "$SYNC" ] && [ -d "$SYNC" -o -d /mnt/d/shuios ]; then
	mkdir -p "$SYNC"
	cp -a "$REPO/." "$SYNC/" && echo ">>> 已同步到 $SYNC"
fi

echo
ls -lh "$REPO" | sed 's/^/    /'
if [ "$fail" -ne 0 ]; then
	echo "!!! 有应用处理失败（见上面日志）"
	exit 1
fi
echo ">>> 完成：$REPO"
