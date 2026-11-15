#!/bin/sh
# shuios-storage: 把数据分区（LABEL=SHUI-DATA）上的目录绑定到需要持久化的路径。
# 幂等：重复执行安全。根文件系统是只读的 squashfs，所以所有需要落盘的东西
# 都必须经由这里显式绑定出来。
set -u

DATA=/data
# 持久化根：模型仓库、已装软件、状态都在这一棵下面
STATE="$DATA/shuios"

log() { echo "shuios-storage: $*"; }

is_mounted() {
    grep -q " $1 " /proc/mounts 2>/dev/null
}

if ! is_mounted "$DATA"; then
    log "警告：$DATA 未挂载，工作区与模型仓库本次不持久化"
    mkdir -p "$DATA"
fi

mkdir -p "$STATE/models" "$STATE/pkg" "$DATA/workspace" \
    "$STATE/NetworkManager/system-connections" 2>/dev/null || true
mkdir -p /var/lib/shuios /workspace /var/log/shuios/agents 2>/dev/null || true

bind() {
    src=$1
    dst=$2
    if [ ! -d "$src" ]; then
        log "跳过 $src（不存在）"
        return 0
    fi
    if is_mounted "$dst"; then
        log "$dst 已挂载，跳过"
        return 0
    fi
    if mount --bind "$src" "$dst"; then
        log "已绑定 $src -> $dst"
    else
        log "绑定 $src -> $dst 失败"
    fi
}

# 整棵 /var/lib/shuios 落在数据分区上：模型仓库（models）与
# shui-pkg 的已装清单/包缓存/挂载点（pkg）都在里面，重启不丢。
bind "$STATE" /var/lib/shuios
bind "$DATA/workspace" /workspace

exit 0
