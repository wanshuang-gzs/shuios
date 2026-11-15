/*
 * vkbd-inject — 通过 zwp_virtual_keyboard_manager_v1 向 shuios 桌面注入按键。
 *
 * 为什么需要它：VMware 的 VNC 是只读的（键盘注入实测无效），镜像也没有
 * CONFIG_INPUT_UINPUT，没法用 ydotool。sway/wlroots 暴露了虚拟键盘协议，
 * 这里做 wtype 的最小实现，用于「终端里打中文」的自动化验收。
 *
 * 用法：
 *   vkbd-inject nihao wait:1500 1 enter
 *   vkbd-inject ctrl+d
 *
 * 键码是 Linux evdev 码（KEY_A=30 …），由合成器交给 xkb 解释。
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_display *display;
static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;
static struct zwp_virtual_keyboard_v1 *vkbd;

static void
registry_global(void *data, struct wl_registry *reg, uint32_t name,
                const char *iface, uint32_t version)
{
	(void)data;
	(void)version;
	if (strcmp(iface, wl_seat_interface.name) == 0) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
	} else if (strcmp(iface,
	                  zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
		manager = wl_registry_bind(
			reg, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
	}
}

static void
registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data;
	(void)reg;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

static int
create_vkbd(void)
{
	struct xkb_context *ctx;
	struct xkb_keymap *km;
	char *str;
	size_t len;
	int fd;

	display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "vkbd-inject: 连不上 Wayland（WAYLAND_DISPLAY 没设？）\n");
		return -1;
	}
	struct wl_registry *reg = wl_display_get_registry(display);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(display);
	if (!manager || !seat) {
		fprintf(stderr, "vkbd-inject: 合成器没有 zwp_virtual_keyboard_manager_v1\n");
		return -1;
	}
	vkbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
	if (!vkbd) {
		fprintf(stderr, "vkbd-inject: 创建虚拟键盘失败\n");
		return -1;
	}

	ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	km = xkb_keymap_new_from_names(ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
	str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
	len = strlen(str) + 1;
	fd = memfd_create("vkbd-keymap", MFD_CLOEXEC);
	if (fd < 0 || write(fd, str, len) != (ssize_t)len) {
		perror("vkbd-inject: keymap");
		return -1;
	}
	zwp_virtual_keyboard_v1_keymap(vkbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
	                               fd, len);
	close(fd);
	free(str);
	xkb_keymap_unref(km);
	xkb_context_unref(ctx);
	wl_display_roundtrip(display);
	return 0;
}

static void
tap(uint32_t code)
{
	zwp_virtual_keyboard_v1_key(vkbd, 0, code,
	                            WL_KEYBOARD_KEY_STATE_PRESSED);
	wl_display_flush(display);
	usleep(25000);
	zwp_virtual_keyboard_v1_key(vkbd, 0, code,
	                            WL_KEYBOARD_KEY_STATE_RELEASED);
	wl_display_flush(display);
	usleep(45000);
}

/* US 布局：evdev 键码 + 是否需要 Shift。
 * 字母键位不连续（a..l=30..38，z..m=44..50），不能用 30+c-'a'。 */
static const int letter_codes[26] = {
	30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50,
	49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,
};

static int
char_code(char c, int *shift)
{
	*shift = 0;
	if (c >= 'a' && c <= 'z')
		return letter_codes[c - 'a'];
	if (c >= 'A' && c <= 'Z') {
		*shift = 1;
		return letter_codes[c - 'A'];
	}
	if (c >= '1' && c <= '9')
		return 2 + (c - '1');
	if (c == '0')
		return 11;
	switch (c) {
	case ' ':
		return 57;
	case '\n':
		return 28;
	case '-':
		return 12;
	case '=':
		return 13;
	case '[':
		return 26;
	case ']':
		return 27;
	case '\\':
		return 43;
	case ';':
		return 39;
	case '\'':
		return 40;
	case '`':
		return 41;
	case ',':
		return 51;
	case '.':
		return 52;
	case '/':
		return 53;
	default:
		return -1;
	}
}

static void
type_char(char c)
{
	int shift = 0;
	int code = char_code(c, &shift);
	if (code < 0) {
		fprintf(stderr, "vkbd-inject: 不支持的字符 '%c'（跳过）\n", c);
		return;
	}
	if (shift) {
		zwp_virtual_keyboard_v1_key(vkbd, 0, 42,
		                            WL_KEYBOARD_KEY_STATE_PRESSED);
		wl_display_flush(display);
	}
	tap((uint32_t)code);
	if (shift) {
		zwp_virtual_keyboard_v1_key(vkbd, 0, 42,
		                            WL_KEYBOARD_KEY_STATE_RELEASED);
		wl_display_flush(display);
	}
}

static void
tap_named(const char *name)
{
	if (strcmp(name, "enter") == 0)
		tap(28);
	else if (strcmp(name, "space") == 0)
		tap(57);
	else if (strcmp(name, "tab") == 0)
		tap(15);
	else if (strcmp(name, "esc") == 0)
		tap(1);
	else if (strcmp(name, "backspace") == 0)
		tap(14);
	else if (strcmp(name, "up") == 0)
		tap(103);
	else if (strcmp(name, "down") == 0)
		tap(108);
	else if (strcmp(name, "left") == 0)
		tap(105);
	else if (strcmp(name, "right") == 0)
		tap(106);
	else
		fprintf(stderr, "vkbd-inject: 未知按键 '%s'\n", name);
}

int
main(int argc, char **argv)
{
	if (create_vkbd() != 0)
		return 1;

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (strncmp(a, "wait:", 5) == 0) {
			usleep((useconds_t)atoi(a + 5) * 1000);
		} else if (strncmp(a, "tap:", 4) == 0) {
			tap((uint32_t)atoi(a + 4));
		} else if (strncmp(a, "super+", 6) == 0) {
			char c = a[6];
			int shift = 0;
			int code = char_code(c, &shift);
			if (code > 0) {
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 125, WL_KEYBOARD_KEY_STATE_PRESSED);
				/* Mod4 = 64（xkb 修饰符位），sway 的 $mod 就是 Mod4。 */
				zwp_virtual_keyboard_v1_modifiers(vkbd, 64, 0, 0, 0);
				wl_display_flush(display);
				tap((uint32_t)code);
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 125, WL_KEYBOARD_KEY_STATE_RELEASED);
				zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
				wl_display_flush(display);
			}
		} else if (strncmp(a, "ctrl+shift+", 11) == 0) {
			char c = a[11];
			int shift = 0;
			int code = char_code(c, &shift);
			if (code > 0) {
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 29, WL_KEYBOARD_KEY_STATE_PRESSED);
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 42, WL_KEYBOARD_KEY_STATE_PRESSED);
				/* GTK 的 GdkEventKey.state 来自 wl_keyboard.modifiers；
				 * 只发 key 事件时 sway 不一定广播修饰符，必须显式声明
				 * （shift=1, ctrl=4）。 */
				zwp_virtual_keyboard_v1_modifiers(vkbd, 5, 0, 0, 0);
				wl_display_flush(display);
				tap((uint32_t)code);
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 42, WL_KEYBOARD_KEY_STATE_RELEASED);
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 29, WL_KEYBOARD_KEY_STATE_RELEASED);
				zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
				wl_display_flush(display);
			}
		} else if (strncmp(a, "ctrl+", 5) == 0) {
			char c = a[5];
			int shift = 0;
			int code = char_code(c, &shift);
			if (code > 0) {
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 29, WL_KEYBOARD_KEY_STATE_PRESSED);
				zwp_virtual_keyboard_v1_modifiers(vkbd, 4, 0, 0, 0);
				wl_display_flush(display);
				tap((uint32_t)code);
				zwp_virtual_keyboard_v1_key(
					vkbd, 0, 29, WL_KEYBOARD_KEY_STATE_RELEASED);
				zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
				wl_display_flush(display);
			}
		} else if (strcmp(a, "enter") == 0 || strcmp(a, "space") == 0 ||
		           strcmp(a, "tab") == 0 || strcmp(a, "esc") == 0 ||
		           strcmp(a, "backspace") == 0 || strcmp(a, "up") == 0 ||
		           strcmp(a, "down") == 0 || strcmp(a, "left") == 0 ||
		           strcmp(a, "right") == 0) {
			tap_named(a);
		} else {
			for (const char *p = a; *p; p++)
				type_char(*p);
		}
	}
	wl_display_roundtrip(display);
	usleep(100000);
	return 0;
}
