/*
 * shui-key — 通过 Wayland 虚拟键盘协议注入输入（验收/自动化辅助）
 *
 * sway/wlroots 提供 zwp_virtual_keyboard_manager_v1，本工具用它把
 * 文本或组合键送进当前焦点表面。用途：
 *   * 锁屏验收：真实敲 Win+L 锁定、敲密码解锁（VNC 是只读的，不能发键）
 *   * 以后给智能体做"能操作 GUI"的底层能力
 *
 * 用法：
 *   shui-key --text "shui"      输入 ASCII 文本（\n 回车）
 *   shui-key --combo logo+l     组合键：logo/super/win、shift、ctrl、alt + 键
 *   shui-key --key Return       单键（Return/Escape/BackSpace/Tab/Space）
 *
 * 需要会话环境：XDG_RUNTIME_DIR + WAYLAND_DISPLAY（SSH 里由脚本补齐）。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include "virtual-keyboard-client-protocol.h"

static struct wl_display *g_dpy;
static struct wl_seat *g_seat;
static struct zwp_virtual_keyboard_manager_v1 *g_mgr;
static struct zwp_virtual_keyboard_v1 *g_vk;
static struct xkb_keymap *g_keymap;
static struct xkb_context *g_xkb;
static struct xkb_state *g_state;
static uint32_t g_delay_us = 20000;

static void registry_global(void *data, struct wl_registry *reg, uint32_t name,
			    const char *iface, uint32_t version)
{
	(void)data;
	if (!strcmp(iface, wl_seat_interface.name)) {
		uint32_t v = version < 7 ? version : 7;
		g_seat = wl_registry_bind(reg, name, &wl_seat_interface, v);
	} else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name)) {
		g_mgr = wl_registry_bind(reg, name,
					 &zwp_virtual_keyboard_manager_v1_interface, 1);
	}
}

static void registry_remove(void *data, struct wl_registry *reg, uint32_t name)
{
	(void)data;
	(void)reg;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_remove,
};

static void send_modifiers(void)
{
	xkb_mod_mask_t depressed =
		xkb_state_serialize_mods(g_state, XKB_STATE_MODS_DEPRESSED);
	xkb_mod_mask_t latched =
		xkb_state_serialize_mods(g_state, XKB_STATE_MODS_LATCHED);
	xkb_mod_mask_t locked =
		xkb_state_serialize_mods(g_state, XKB_STATE_MODS_LOCKED);
	xkb_layout_index_t group =
		xkb_state_serialize_layout(g_state, XKB_STATE_LAYOUT_EFFECTIVE);
	zwp_virtual_keyboard_v1_modifiers(g_vk, depressed, latched, locked, group);
}

static void emit_key(uint32_t keycode, uint32_t state)
{
	zwp_virtual_keyboard_v1_key(g_vk, 0, keycode, state);
	/* wlroots 的虚拟键盘 key 事件带 update_state=false：合成器不会自己
	 * 从按键推导修饰键，必须每次同步 modifiers，否则 Win+L 里 Super
	 * 等于没按下，绑定不触发。 */
	xkb_state_update_key(g_state, keycode + 8,
			     state == 1 ? XKB_KEY_DOWN : XKB_KEY_UP);
	send_modifiers();
	wl_display_flush(g_dpy);
	usleep(g_delay_us);
}

/* 在 xkb keymap 里找 keysym：返回 wl_keyboard 用的 evdev keycode（xkb-8） */
static int find_key(xkb_keysym_t sym, int *level)
{
	for (xkb_keycode_t kc = 9; kc <= 255; kc++) {
		for (int lv = 0; lv <= 1; lv++) {
			const xkb_keysym_t *syms = NULL;
			int n = xkb_keymap_key_get_syms_by_level(g_keymap, kc, 0, lv,
								 &syms);
			for (int i = 0; i < n; i++) {
				if (syms[i] == sym) {
					*level = lv;
					return (int)kc - 8;
				}
			}
		}
	}
	return -1;
}

static int find_key_level0(xkb_keysym_t sym)
{
	for (xkb_keycode_t kc = 9; kc <= 255; kc++) {
		const xkb_keysym_t *syms = NULL;
		int n = xkb_keymap_key_get_syms_by_level(g_keymap, kc, 0, 0, &syms);
		for (int i = 0; i < n; i++)
			if (syms[i] == sym)
				return (int)kc - 8;
	}
	return -1;
}

static int setup_keymap(void)
{
	g_xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (!g_xkb)
		return -1;
	g_keymap = xkb_keymap_new_from_names(g_xkb, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
	if (!g_keymap)
		return -1;
	g_state = xkb_state_new(g_keymap);
	if (!g_state)
		return -1;

	char *str = xkb_keymap_get_as_string(g_keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
	if (!str)
		return -1;
	size_t len = strlen(str) + 1;

	int fd = memfd_create("shui-keymap", MFD_CLOEXEC);
	if (fd < 0) {
		free(str);
		return -1;
	}
	if (ftruncate(fd, (off_t)len) != 0) {
		close(fd);
		free(str);
		return -1;
	}
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		close(fd);
		free(str);
		return -1;
	}
	memcpy(p, str, len);
	munmap(p, len);
	free(str);

	zwp_virtual_keyboard_v1_keymap(g_vk, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, len);
	close(fd);
	wl_display_roundtrip(g_dpy);
	usleep(80000);
	return 0;
}

static xkb_keysym_t keysym_for_char(char c)
{
	if (c == '\n')
		return XKB_KEY_Return;
	if (c == '\t')
		return XKB_KEY_Tab;
	if ((unsigned char)c < 0x20)
		return XKB_KEY_NoSymbol;
	return (xkb_keysym_t)(unsigned char)c;
}

static int type_text(const char *text)
{
	int shift = find_key_level0(XKB_KEY_Shift_L);
	if (shift < 0) {
		fprintf(stderr, "shui-key: keymap 里找不到 Shift_L\n");
		return 4;
	}
	for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
		xkb_keysym_t sym = keysym_for_char((char)*p);
		if (sym == XKB_KEY_NoSymbol) {
			fprintf(stderr, "shui-key: 不支持的字符 0x%02x\n", *p);
			return 4;
		}
		int level = 0;
		int kc = find_key(sym, &level);
		if (kc < 0) {
			fprintf(stderr, "shui-key: 当前布局打不出字符 0x%02x\n", *p);
			return 4;
		}
		if (level == 1)
			emit_key((uint32_t)shift, 1);
		emit_key((uint32_t)kc, 1);
		emit_key((uint32_t)kc, 0);
		if (level == 1)
			emit_key((uint32_t)shift, 0);
	}
	return 0;
}

static xkb_keysym_t token_keysym(const char *tok)
{
	if (!strcmp(tok, "logo") || !strcmp(tok, "super") || !strcmp(tok, "win") ||
	    !strcmp(tok, "meta"))
		return XKB_KEY_Super_L;
	if (!strcmp(tok, "shift"))
		return XKB_KEY_Shift_L;
	if (!strcmp(tok, "ctrl") || !strcmp(tok, "control"))
		return XKB_KEY_Control_L;
	if (!strcmp(tok, "alt"))
		return XKB_KEY_Alt_L;
	if (!strcmp(tok, "Return") || !strcmp(tok, "Enter"))
		return XKB_KEY_Return;
	if (!strcmp(tok, "Escape"))
		return XKB_KEY_Escape;
	if (!strcmp(tok, "BackSpace"))
		return XKB_KEY_BackSpace;
	if (!strcmp(tok, "Tab"))
		return XKB_KEY_Tab;
	if (!strcmp(tok, "Space"))
		return XKB_KEY_space;
	if (strlen(tok) == 1)
		return (xkb_keysym_t)(unsigned char)tok[0];
	return XKB_KEY_NoSymbol;
}

static int send_combo(const char *combo)
{
	uint32_t keys[8];
	int n = 0;

	char buf[128];
	snprintf(buf, sizeof buf, "%s", combo);
	char *save = NULL;
	for (char *tok = strtok_r(buf, "+", &save); tok;
	     tok = strtok_r(NULL, "+", &save)) {
		xkb_keysym_t sym = token_keysym(tok);
		if (sym == XKB_KEY_NoSymbol) {
			fprintf(stderr, "shui-key: 看不懂的组合键段 '%s'\n", tok);
			return 4;
		}
		int kc = find_key_level0(sym);
		if (kc < 0) {
			fprintf(stderr, "shui-key: 布局里没有 '%s'\n", tok);
			return 4;
		}
		if (n >= (int)(sizeof keys / sizeof keys[0])) {
			fprintf(stderr, "shui-key: 组合键太长\n");
			return 4;
		}
		keys[n++] = (uint32_t)kc;
	}
	if (n == 0)
		return 2;

	for (int i = 0; i < n; i++)
		emit_key(keys[i], 1);
	for (int i = n - 1; i >= 0; i--)
		emit_key(keys[i], 0);
	return 0;
}

static int send_single(const char *name)
{
	xkb_keysym_t sym = token_keysym(name);
	if (sym == XKB_KEY_NoSymbol) {
		fprintf(stderr, "shui-key: 不认识的键 '%s'\n", name);
		return 4;
	}
	int kc = find_key_level0(sym);
	if (kc < 0) {
		fprintf(stderr, "shui-key: 布局里没有 '%s'\n", name);
		return 4;
	}
	emit_key((uint32_t)kc, 1);
	emit_key((uint32_t)kc, 0);
	return 0;
}

static void usage(const char *argv0)
{
	printf("用法: %s --text <文本> | --combo <a+b> | --key <键名> [--delay 毫秒]\n"
	       "  --text  仅 ASCII；\\n 表示回车\n"
	       "  --combo 例：logo+l、ctrl+shift+t\n"
	       "  --key   例：Return、Escape、BackSpace、Tab、Space\n",
	       argv0);
}

int main(int argc, char **argv)
{
	const char *text = NULL;
	const char *combo = NULL;
	const char *key = NULL;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--text") && i + 1 < argc) {
			text = argv[++i];
		} else if (!strcmp(argv[i], "--combo") && i + 1 < argc) {
			combo = argv[++i];
		} else if (!strcmp(argv[i], "--key") && i + 1 < argc) {
			key = argv[++i];
		} else if (!strcmp(argv[i], "--delay") && i + 1 < argc) {
			int d = atoi(argv[++i]);
			if (d >= 0 && d <= 1000)
				g_delay_us = (uint32_t)d * 1000;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(argv[0]);
			return 0;
		} else {
			usage(argv[0]);
			return 2;
		}
	}
	if ((!!text + !!combo + !!key) != 1) {
		usage(argv[0]);
		return 2;
	}

	g_dpy = wl_display_connect(NULL);
	if (!g_dpy) {
		fprintf(stderr, "shui-key: 连不上 Wayland（检查 WAYLAND_DISPLAY）\n");
		return 3;
	}
	struct wl_registry *reg = wl_display_get_registry(g_dpy);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(g_dpy);
	if (!g_seat || !g_mgr) {
		fprintf(stderr, "shui-key: 合成器不支持虚拟键盘协议\n");
		return 3;
	}

	g_vk = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(g_mgr, g_seat);
	if (!g_vk) {
		fprintf(stderr, "shui-key: 创建虚拟键盘失败\n");
		return 3;
	}
	if (setup_keymap() != 0) {
		fprintf(stderr, "shui-key: 上传 keymap 失败\n");
		return 3;
	}

	int rc;
	if (text)
		rc = type_text(text);
	else if (combo)
		rc = send_combo(combo);
	else
		rc = send_single(key);

	wl_display_roundtrip(g_dpy);
	usleep(50000);
	zwp_virtual_keyboard_v1_destroy(g_vk);
	wl_display_disconnect(g_dpy);
	if (g_state)
		xkb_state_unref(g_state);
	if (g_keymap)
		xkb_keymap_unref(g_keymap);
	if (g_xkb)
		xkb_context_unref(g_xkb);
	return rc;
}
