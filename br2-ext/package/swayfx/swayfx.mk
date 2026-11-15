################################################################################
#
# swayfx — 带圆角 / 阴影 / 模糊的 sway
#
# 为什么用它：Discord 的圆角、macOS 的窗口阴影、面板后面的毛玻璃，
# 在原始 wlroots/sway 里一个都做不到（wlroots 的 scene API 只能画直角矩形）。
# swayfx 把 scenefx 的 fx renderer 接进 sway，配置里几行就能开。
#
# 版本对应关系（硬绑定，改一个就得改另一个）：
#   0.5.1 → sway 1.10.1 + scenefx 0.3 + wlroots 0.18
#   0.6   → sway 1.12.0 + scenefx 0.5 + wlroots 0.20   ← 本版
#
# 升到 0.6 的动机：
#   * 跟到 wlroots 0.20：udmabuf allocator（软件渲染少一次影子拷贝）、
#     damage ring / swapchain 重写、explicit sync
#   * scenefx 0.5 的 damage 修复（0.3 的 fx pass 按整矩形近似）
#
# 二进制名仍是 sway / swaymsg / swaybar：shui-ctl 走的 i3 IPC 协议完全不变，
# 会话脚本、systemd 单元、面板都不需要改。
#
################################################################################

SWAYFX_VERSION = 0.6
SWAYFX_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
SWAYFX_SITE_METHOD = file
SWAYFX_SOURCE = swayfx-0.6.tar.gz
SWAYFX_LICENSE = MIT
SWAYFX_LICENSE_FILES = LICENSE

# libevdev：swayfx 0.6（= sway 1.12）新增的硬依赖
SWAYFX_DEPENDENCIES = \
	systemd host-pkgconf scenefx wlroots json-c pcre2 cairo pango libevdev

SWAYFX_CONF_OPTS = \
	-Dwerror=false \
	-Dzsh-completions=false \
	-Dfish-completions=false \
	-Dbash-completions=false \
	-Dman-pages=disabled \
	-Dsd-bus-provider=libsystemd

ifeq ($(BR2_PACKAGE_GDK_PIXBUF),y)
SWAYFX_CONF_OPTS += -Dgdk-pixbuf=enabled
SWAYFX_DEPENDENCIES += gdk-pixbuf
else
SWAYFX_CONF_OPTS += -Dgdk-pixbuf=disabled
endif

# 壁纸由我们自己的 /usr/share/shuios/wallpaper.png 提供，不要上游那张
SWAYFX_CONF_OPTS += -Ddefault-wallpaper=false

ifeq ($(BR2_PACKAGE_SWAYFX_SWAYBAR),y)
SWAYFX_CONF_OPTS += -Dswaybar=true
else
SWAYFX_CONF_OPTS += -Dswaybar=false
endif

ifeq ($(BR2_PACKAGE_SWAYFX_SWAYNAG),y)
SWAYFX_CONF_OPTS += -Dswaynag=true
else
SWAYFX_CONF_OPTS += -Dswaynag=false
endif

ifeq ($(BR2_PACKAGE_SWAYFX_SWAYBAR_TRAY),y)
SWAYFX_CONF_OPTS += -Dtray=enabled
else
SWAYFX_CONF_OPTS += -Dtray=disabled
endif

$(eval $(meson-package))
