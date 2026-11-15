################################################################################
#
# waybar — 现成的 Wayland 任务栏（GTK3 + layer-shell + CSS 主题）
#
################################################################################

WAYBAR_VERSION = 0.10.4
WAYBAR_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
WAYBAR_SITE_METHOD = file
WAYBAR_SOURCE = waybar-0.10.4.tar.gz
WAYBAR_LICENSE = MIT
WAYBAR_LICENSE_FILES = LICENSE
WAYBAR_INSTALL_STAGING = NO
WAYBAR_DEPENDENCIES = \
	host-pkgconf gtkmm3 gtk-layer-shell jsoncpp fmt spdlog libsigc \
	wayland wayland-protocols libnl

# 只留下任务栏真正用得上的模块：
#   wlr/workspaces、wlr/taskbar、wlr/window、clock、battery、network(libnl)、custom
# 音频/媒体/游戏/托盘这些依赖要么体积大、要么 QEMU 里没设备，全部关掉。
WAYBAR_CONF_OPTS = \
	-Dtests=disabled \
	-Dsystemd=disabled \
	-Ddbusmenu-gtk=disabled \
	-Dlibinput=disabled \
	-Dlibnl=enabled \
	-Dlibudev=disabled \
	-Dlibevdev=disabled \
	-Dpulseaudio=disabled \
	-Dpipewire=disabled \
	-Dupower_glib=disabled \
	-Dmpris=disabled \
	-Dmpd=disabled \
	-Drfkill=disabled \
	-Dsndio=disabled \
	-Dlogind=disabled \
	-Djack=disabled \
	-Dwireplumber=disabled \
	-Dcava=disabled \
	-Dman-pages=disabled \
	-Dexperimental=false

# 注意：waybar 把 xkbregistry 当成硬依赖，而 Buildroot 的 libxkbcommon
# 默认 -Denable-xkbregistry=false（不编它）。我们的做法是**把那个开关打开**
# （见 tools/wsl-enable-xkbregistry.sh），而不是改 waybar 源码——
# 这样 waybar 保持上游原样，升级也简单。
$(eval $(meson-package))
