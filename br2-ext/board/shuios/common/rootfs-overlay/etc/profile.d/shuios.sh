# shuios 环境
export SHUIOS=1
export SHUIOS_VERSION=0.1.0
export SHUIOS_MODELS=/var/lib/shuios/models

# 已装软件的入口目录（由 shui-pkg 维护，见 /var/lib/shuios/pkg/bin）
export SHUIOS_PKG_BIN=/var/lib/shuios/pkg/bin
export PATH="$SHUIOS_PKG_BIN:/opt/shuios/bin:/usr/local/bin:/usr/bin:/bin"

# 桌面入口：让 Weston/sway 的启动器能看见 shui-pkg 装出来的 .desktop
export XDG_DATA_DIRS="/var/lib/shuios/pkg/share:/usr/local/share:/usr/share"

# 交互式登录默认落到工作区（唯一持久化的用户目录）
if [ -t 0 ] && [ -d /workspace ]; then
    cd /workspace 2>/dev/null || true
fi
