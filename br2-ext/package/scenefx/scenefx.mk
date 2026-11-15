################################################################################
#
# scenefx — wlroots 场景图 + 特效渲染器
#
# swayfx 的"好看"全部来自这里：圆角、阴影、模糊都是 scenefx 的 fx renderer
# 在场景图上画的，wlroots 本体一行没改。
#
# 版本必须与 wlroots 对得上：
#   scenefx 0.3 → wlroots 0.18（旧）
#   scenefx 0.5 → wlroots 0.20（本版，pkg-config 名 scenefx-0.5）
#
# 升到 0.5 的动机（不只为了配合 swayfx 0.6）：
#   * 0.3 之后修了多处 damage 相关缺陷：235ea6db47(PR #173)、06fb6d8dac(PR #200)、
#     3606f3d3bb(PR #210)；0.3 的 fx pass damage 按整矩形近似，软件渲染下
#     会白白重绘大片像素
#   * 0.5 起 scenefx 不再 vendored 旧 wlroots scene 代码
#
################################################################################

SCENEFX_VERSION = 0.5
SCENEFX_SITE = $(BR2_EXTERNAL_SHUIOS_PATH)/dl
SCENEFX_SITE_METHOD = file
SCENEFX_SOURCE = scenefx-0.5.tar.gz
SCENEFX_LICENSE = MIT
SCENEFX_LICENSE_FILES = LICENSE
SCENEFX_INSTALL_STAGING = YES

# host-wayland：protocol/ 里要用 wayland-scanner 生成 xdg-shell 代码
# wayland-protocols：同上，需要 stable/xdg-shell 的 XML
# libxkbcommon：scenefx 0.5 起是硬依赖（meson 要求 >= 1.8.0）
SCENEFX_DEPENDENCIES = \
	host-pkgconf host-wayland wlroots wayland wayland-protocols \
	libdrm libxkbcommon pixman

# 源码里 werror=true；GCC 13 对老代码常报新的警告，关掉免得卡在编译期
SCENEFX_CONF_OPTS = -Dwerror=false -Dexamples=false

$(eval $(meson-package))
