/*
 * shui-lock — shuios 锁屏（GTK3 + gtk-layer-shell）
 *
 * 形态：全屏 OVERLAY 图层，盖住任务栏与所有窗口；键盘 EXCLUSIVE 独占。
 * 锁屏期间切到 sway 的 "shui-lock" binding mode——该 mode 里没有绑定默认
 * 模式的快捷键，所以 Win+Return / Win+E 之类不会在背后偷偷开窗口。
 *
 * 认证：镜像没有 PAM，直接读 /etc/shadow 的 root 哈希，用 crypt_r 比对
 * （$5$/$6$ 由 libxcrypt 支持）。锁屏进程本身已经是 root（桌面会话以
 * systemd system service 运行），所以不需要再提权。
 *
 * 单实例：flock(/run/shuios/lock.lock)；pid 写 /run/shuios/lock.pid，
 * shui-idle 用它做 watchdog（锁屏异常退出时恢复 sway 默认 mode）。
 *
 * 视觉：壁纸 + BG_WINDOW 78% 遮罩，中央时钟/日期 + 登录卡片；
 * 右下角电源按钮点一次进入确认态，3 秒内再点才执行（防误触）。
 * 色值/字号/圆角全部来自 shuios-ui.h。
 */

#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <gtk-layer-shell/gtk-layer-shell.h>
#include <crypt.h>
#include <errno.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "shuios-ui.h"

#define LOCK_RUN_DIR "/run/shuios"
#define LOCK_PIDFILE LOCK_RUN_DIR "/lock.pid"
#define LOCK_LOCKFILE LOCK_RUN_DIR "/lock.lock"
#define WALLPAPER "/usr/share/shuios/wallpaper.png"

#define LOCK_CLOCK_FS 56   /* 锁屏时钟字号（展示型大字，超出常规阶梯） */
#define LOCK_CARD_W 368
#define LOCK_ENTRY_W 320

typedef struct {
	GtkWidget *btn;
	const char *what;    /* systemctl 参数：poweroff / reboot */
	const char *label;
	gboolean armed;
	guint timer;
} PowerBtn;

static GtkWidget *g_window;
static GtkWidget *g_entry;
static GtkWidget *g_error;
static GtkWidget *g_clock;
static GtkWidget *g_date;
static GtkWidget *g_unlock;

static GdkPixbuf *g_bg_src;
static GdkPixbuf *g_bg_scaled;
static int g_bg_w;
static int g_bg_h;

static char g_hash[512];
static int g_lock_fd = -1;
static int g_quitting;

static PowerBtn g_power[2];

static void unlock_screen(void);

static void ensure_swaysock(void)
{
	if (getenv("SWAYSOCK"))
		return;
	const char *rt = getenv("XDG_RUNTIME_DIR");
	if (!rt || !*rt)
		rt = LOCK_RUN_DIR "/compositor";
	GDir *d = g_dir_open(rt, 0, NULL);
	if (!d)
		return;
	const char *fn;
	while ((fn = g_dir_read_name(d)) != NULL) {
		if (!g_str_has_prefix(fn, "sway-ipc.") || !g_str_has_suffix(fn, ".sock"))
			continue;
		char path[256];
		snprintf(path, sizeof path, "%s/%s", rt, fn);
		setenv("SWAYSOCK", path, 1);
		break;
	}
	g_dir_close(d);
}

/* 切换 binding mode；拿不到 SWAYSOCK 时静默跳过（锁屏本身仍然有效） */
static void sway_cmd(const char *cmd)
{
	if (!getenv("SWAYSOCK"))
		return;
	char line[128];
	snprintf(line, sizeof line, "/usr/bin/swaymsg %s", cmd);
	if (system(line) != 0)
		g_printerr("shui-lock: swaymsg %s 失败\n", cmd);
}

static void load_root_hash(void)
{
	FILE *f = fopen("/etc/shadow", "r");
	if (!f) {
		g_printerr("shui-lock: 打不开 /etc/shadow: %s\n", strerror(errno));
		return;
	}
	char line[1024];
	while (fgets(line, sizeof line, f)) {
		if (strncmp(line, "root:", 5) != 0)
			continue;
		char *p = line + 5;
		char *colon = strchr(p, ':');
		if (!colon)
			break;
		*colon = 0;
		snprintf(g_hash, sizeof g_hash, "%s", p);
		break;
	}
	fclose(f);
	if (!g_hash[0])
		g_printerr("shui-lock: /etc/shadow 里没有 root 哈希，锁屏将拒绝解锁\n");
}

static int check_password(const char *pw)
{
	if (!g_hash[0] || g_hash[0] == '!' || g_hash[0] == '*')
		return 0;
	struct crypt_data cd;
	memset(&cd, 0, sizeof cd);
	char *h = crypt_r(pw, g_hash, &cd);
	int ok = h && strcmp(h, g_hash) == 0;
	memset(&cd, 0, sizeof cd);
	return ok;
}

/* ------------------------------------------------------------ 绘制 */

static gboolean on_draw_bg(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	(void)data;
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);
	if (w < 2 || h < 2)
		return FALSE;

	if (g_bg_src) {
		if (!g_bg_scaled || g_bg_w != w || g_bg_h != h) {
			if (g_bg_scaled)
				g_object_unref(g_bg_scaled);
			g_bg_scaled = gdk_pixbuf_scale_simple(g_bg_src, w, h,
							     GDK_INTERP_BILINEAR);
			g_bg_w = w;
			g_bg_h = h;
		}
		if (g_bg_scaled) {
			gdk_cairo_set_source_pixbuf(cr, g_bg_scaled, 0, 0);
			cairo_paint(cr);
		}
	} else {
		cairo_set_source_rgb(cr, UI_RGB_BG_WINDOW);
		cairo_paint(cr);
	}

	/* 暗遮罩：保留壁纸的品牌色，同时保证白字对比度 */
	cairo_set_source_rgba(cr, UI_RGB_BG_WINDOW, 0.78);
	cairo_paint(cr);
	return FALSE;
}

static gboolean on_draw_avatar(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	(void)data;
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);
	double cx = w / 2.0;
	double cy = h / 2.0;
	double r = w / 2.0 - 1;

	cairo_set_source_rgb(cr, UI_RGB_BG_CARD);
	cairo_arc(cr, cx, cy, r, 0, 2 * M_PI);
	cairo_fill(cr);

	cairo_set_source_rgb(cr, UI_RGB_LINE);
	cairo_set_line_width(cr, 1);
	cairo_arc(cr, cx, cy, r, 0, 2 * M_PI);
	cairo_stroke(cr);

	cairo_set_source_rgb(cr, UI_RGB_ACCENT);
	cairo_select_font_face(cr, "WenQuanYi Zen Hei", CAIRO_FONT_SLANT_NORMAL,
			       CAIRO_FONT_WEIGHT_BOLD);
	cairo_set_font_size(cr, 26);
	cairo_text_extents_t ext;
	cairo_text_extents(cr, "氵", &ext);
	cairo_move_to(cr, cx - (ext.width / 2 + ext.x_bearing),
		      cy - (ext.height / 2 + ext.y_bearing));
	cairo_show_text(cr, "氵");
	return FALSE;
}

static gboolean tick_clock(gpointer data)
{
	(void)data;
	time_t t = time(NULL);
	struct tm tm;
	localtime_r(&t, &tm);

	char hm[16];
	snprintf(hm, sizeof hm, "%02d:%02d", tm.tm_hour, tm.tm_min);
	gtk_label_set_text(GTK_LABEL(g_clock), hm);

	static const char *wd[] = { "日", "一", "二", "三", "四", "五", "六" };
	char ds[64];
	snprintf(ds, sizeof ds, "%d年%d月%d日 星期%s", tm.tm_year + 1900,
		 tm.tm_mon + 1, tm.tm_mday, wd[tm.tm_wday]);
	gtk_label_set_text(GTK_LABEL(g_date), ds);
	return G_SOURCE_CONTINUE;
}

/* ------------------------------------------------------------ 解锁 */

static void hide_error(void)
{
	if (!g_error)
		return;
	gtk_widget_hide(g_error);
	if (g_entry)
		gtk_style_context_remove_class(gtk_widget_get_style_context(g_entry),
					       "error");
}

static gboolean clear_error_class(gpointer data)
{
	(void)data;
	if (g_entry)
		gtk_style_context_remove_class(gtk_widget_get_style_context(g_entry),
					       "error");
	return G_SOURCE_REMOVE;
}

static void do_unlock(void)
{
	const char *pw = gtk_entry_get_text(GTK_ENTRY(g_entry));
	if (!pw || !*pw) {
		gtk_widget_grab_focus(g_entry);
		return;
	}
	if (check_password(pw)) {
		unlock_screen();
		return;
	}
	/* 先清空再显示错误：清空会触发 changed → hide_error，
	   顺序反过来会把刚显示的错误提示立刻藏掉（踩过）。 */
	gtk_entry_set_text(GTK_ENTRY(g_entry), "");
	gtk_widget_grab_focus(g_entry);
	gtk_label_set_text(GTK_LABEL(g_error), "密码错误，请重试");
	gtk_widget_show(g_error);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_entry), "error");
	g_timeout_add(1200, clear_error_class, NULL);
}

static void unlock_screen(void)
{
	if (g_quitting)
		return;
	g_quitting = 1;
	gtk_entry_set_text(GTK_ENTRY(g_entry), "");
	/* 先恢复快捷键再关窗，避免中间态里按键落到桌面上 */
	sway_cmd("mode default");
	unlink(LOCK_PIDFILE);
	if (g_lock_fd >= 0) {
		flock(g_lock_fd, LOCK_UN);
		close(g_lock_fd);
		g_lock_fd = -1;
	}
	gtk_main_quit();
}

static gboolean on_term_signal(gpointer data)
{
	(void)data;
	unlock_screen();
	return G_SOURCE_REMOVE;
}

static void on_entry_changed(GtkEditable *e, gpointer data)
{
	(void)e;
	(void)data;
	if (g_error && gtk_widget_get_visible(g_error))
		hide_error();
}

static void on_unlock_clicked(GtkButton *btn, gpointer data)
{
	(void)btn;
	(void)data;
	do_unlock();
}

static gboolean on_window_key(GtkWidget *w, GdkEventKey *ev, gpointer data)
{
	(void)w;
	(void)data;
	if (ev->keyval == GDK_KEY_Escape) {
		gtk_entry_set_text(GTK_ENTRY(g_entry), "");
		hide_error();
		gtk_widget_grab_focus(g_entry);
		return TRUE;
	}
	return FALSE;
}

/* ------------------------------------------------------------ 电源 */

static void power_reset(PowerBtn *p)
{
	p->armed = FALSE;
	if (p->timer) {
		g_source_remove(p->timer);
		p->timer = 0;
	}
	if (!p->btn)
		return;
	gtk_button_set_label(GTK_BUTTON(p->btn), p->label);
	gtk_style_context_remove_class(gtk_widget_get_style_context(p->btn), "armed");
}

static gboolean power_timeout(gpointer data)
{
	PowerBtn *p = data;
	p->timer = 0;
	power_reset(p);
	return G_SOURCE_REMOVE;
}

static void on_power_clicked(GtkButton *btn, gpointer data)
{
	PowerBtn *p = data;
	if (!p->armed) {
		p->armed = TRUE;
		gtk_button_set_label(btn, "再点一次");
		gtk_style_context_add_class(gtk_widget_get_style_context(GTK_WIDGET(btn)),
					    "armed");
		p->timer = g_timeout_add_seconds(3, power_timeout, p);
		return;
	}
	power_reset(p);
	char cmd[64];
	snprintf(cmd, sizeof cmd, "/usr/bin/systemctl %s", p->what);
	if (!g_spawn_command_line_async(cmd, NULL))
		g_printerr("shui-lock: 执行 %s 失败\n", cmd);
}

/* ------------------------------------------------------------ 界面 */

static void install_css(void)
{
	const char *css =
		"window.lock { background-color: " UI_HEX_BG_WINDOW "; }\n"
		".lockclock { color: " UI_HEX_FG "; font-size: " UI_STR(LOCK_CLOCK_FS) "px;"
		"  font-weight: bold; }\n"
		".lockdate { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_BODY) "px; }\n"
		".lockcard { background-color: " UI_HEX_BG_PANEL ";"
		"  border: 1px solid " UI_HEX_LINE ";"
		"  border-radius: " UI_STR(UI_RADIUS_CARD) "px;"
		"  padding: " UI_STR(UI_SP_6) "px; }\n"
		".lockuser { color: " UI_HEX_FG "; font-size: " UI_STR(UI_FS_TITLE) "px;"
		"  font-weight: bold; }\n"
		".locksub { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		".lockcard entry { background-image: none; background-color: " UI_HEX_BG_CARD ";"
		"  color: " UI_HEX_FG "; border: 1px solid " UI_HEX_LINE ";"
		"  border-radius: " UI_STR(UI_RADIUS) "px; box-shadow: none; outline: none;"
		"  padding: " UI_STR(UI_SP_2) "px " UI_STR(UI_SP_3) "px;"
		"  caret-color: " UI_HEX_ACCENT "; }\n"
		".lockcard entry:focus { border-color: " UI_HEX_ACCENT "; }\n"
		".lockcard entry.error { border-color: " UI_HEX_DANGER "; }\n"
		"button.lockunlock { background-image: none; background-color: " UI_HEX_ACCENT ";"
		"  color: " UI_HEX_ACCENT_ON "; border: none; box-shadow: none;"
		"  border-radius: " UI_STR(UI_RADIUS) "px;"
		"  padding: " UI_STR(UI_SP_2) "px; font-weight: bold;"
		"  font-size: " UI_STR(UI_FS_BODY) "px; }\n"
		"button.lockunlock:hover { background-color: " UI_HEX_ACCENT_HI "; }\n"
		".lockerror { color: " UI_HEX_DANGER "; font-size: " UI_STR(UI_FS_LABEL) "px; }\n"
		".lockhint { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		"button.lockpower { background-image: none; background-color: " UI_HEX_BG_CARD ";"
		"  color: " UI_HEX_FG_DIM "; border: 1px solid " UI_HEX_LINE ";"
		"  box-shadow: none; border-radius: " UI_STR(UI_RADIUS) "px;"
		"  padding: " UI_STR(UI_SP_2) "px " UI_STR(UI_SP_4) "px;"
		"  font-size: " UI_STR(UI_FS_LABEL) "px; }\n"
		"button.lockpower:hover { background-color: " UI_HEX_BG_HOVER ";"
		"  color: " UI_HEX_FG "; }\n"
		"button.lockpower.armed { border-color: " UI_HEX_DANGER ";"
		"  color: " UI_HEX_DANGER "; }\n";

	GtkCssProvider *prov = gtk_css_provider_new();
	gtk_css_provider_load_from_data(prov, css, -1, NULL);
	gtk_style_context_add_provider_for_screen(
		gdk_screen_get_default(), GTK_STYLE_PROVIDER(prov),
		GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(prov);
}

static GtkWidget *new_label(const char *text, const char *cls)
{
	GtkWidget *l = gtk_label_new(text);
	gtk_style_context_add_class(gtk_widget_get_style_context(l), cls);
	return l;
}

static void build_ui(void)
{
	GtkWidget *overlay = gtk_overlay_new();
	gtk_container_add(GTK_CONTAINER(g_window), overlay);

	GtkWidget *bg = gtk_drawing_area_new();
	gtk_widget_set_hexpand(bg, TRUE);
	gtk_widget_set_vexpand(bg, TRUE);
	g_signal_connect(bg, "draw", G_CALLBACK(on_draw_bg), NULL);
	gtk_container_add(GTK_CONTAINER(overlay), bg);

	/* 中央：时钟 / 日期 / 登录卡片 */
	GtkWidget *center = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_widget_set_halign(center, GTK_ALIGN_CENTER);
	gtk_widget_set_valign(center, GTK_ALIGN_CENTER);
	gtk_overlay_add_overlay(GTK_OVERLAY(overlay), center);

	g_clock = new_label("00:00", "lockclock");
	gtk_box_pack_start(GTK_BOX(center), g_clock, FALSE, FALSE, 0);

	g_date = new_label("", "lockdate");
	gtk_widget_set_margin_top(g_date, UI_SP_1);
	gtk_box_pack_start(GTK_BOX(center), g_date, FALSE, FALSE, 0);

	GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_2);
	gtk_style_context_add_class(gtk_widget_get_style_context(card), "lockcard");
	gtk_widget_set_size_request(card, LOCK_CARD_W, -1);
	gtk_widget_set_halign(card, GTK_ALIGN_CENTER);
	gtk_widget_set_margin_top(card, UI_SP_6 + UI_SP_2);
	gtk_box_pack_start(GTK_BOX(center), card, FALSE, FALSE, 0);

	GtkWidget *avatar = gtk_drawing_area_new();
	gtk_widget_set_size_request(avatar, 64, 64);
	gtk_widget_set_halign(avatar, GTK_ALIGN_CENTER);
	g_signal_connect(avatar, "draw", G_CALLBACK(on_draw_avatar), NULL);
	gtk_box_pack_start(GTK_BOX(card), avatar, FALSE, FALSE, 0);

	GtkWidget *user = new_label("root", "lockuser");
	gtk_widget_set_halign(user, GTK_ALIGN_CENTER);
	gtk_widget_set_margin_top(user, UI_SP_2);
	gtk_box_pack_start(GTK_BOX(card), user, FALSE, FALSE, 0);

	GtkWidget *sub = new_label("shuios · 氵", "locksub");
	gtk_widget_set_halign(sub, GTK_ALIGN_CENTER);
	gtk_box_pack_start(GTK_BOX(card), sub, FALSE, FALSE, 0);

	g_entry = gtk_entry_new();
	gtk_entry_set_visibility(GTK_ENTRY(g_entry), FALSE);
	gtk_entry_set_placeholder_text(GTK_ENTRY(g_entry), "输入密码");
	gtk_entry_set_input_purpose(GTK_ENTRY(g_entry), GTK_INPUT_PURPOSE_PASSWORD);
	gtk_widget_set_size_request(g_entry, LOCK_ENTRY_W, 40);
	gtk_widget_set_margin_top(g_entry, UI_SP_4);
	g_signal_connect(g_entry, "activate", G_CALLBACK(do_unlock), NULL);
	g_signal_connect(g_entry, "changed", G_CALLBACK(on_entry_changed), NULL);
	gtk_box_pack_start(GTK_BOX(card), g_entry, FALSE, FALSE, 0);

	g_unlock = gtk_button_new_with_label("解锁");
	gtk_widget_set_size_request(g_unlock, LOCK_ENTRY_W, 40);
	gtk_widget_set_can_focus(g_unlock, FALSE);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_unlock), "lockunlock");
	g_signal_connect(g_unlock, "clicked", G_CALLBACK(on_unlock_clicked), NULL);
	gtk_box_pack_start(GTK_BOX(card), g_unlock, FALSE, FALSE, 0);

	g_error = new_label("", "lockerror");
	gtk_widget_set_halign(g_error, GTK_ALIGN_CENTER);
	gtk_widget_set_no_show_all(g_error, TRUE);
	gtk_box_pack_start(GTK_BOX(card), g_error, FALSE, FALSE, 0);

	/* 左下：操作提示 */
	GtkWidget *hint = new_label("Win + L 锁定 · 空闲自动锁定", "lockhint");
	gtk_widget_set_halign(hint, GTK_ALIGN_START);
	gtk_widget_set_valign(hint, GTK_ALIGN_END);
	gtk_widget_set_margin_start(hint, UI_SP_6);
	gtk_widget_set_margin_bottom(hint, UI_SP_6);
	gtk_overlay_add_overlay(GTK_OVERLAY(overlay), hint);

	/* 右下：关机 / 重启（两步确认） */
	GtkWidget *prow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	gtk_widget_set_halign(prow, GTK_ALIGN_END);
	gtk_widget_set_valign(prow, GTK_ALIGN_END);
	gtk_widget_set_margin_end(prow, UI_SP_6);
	gtk_widget_set_margin_bottom(prow, UI_SP_6);
	gtk_overlay_add_overlay(GTK_OVERLAY(overlay), prow);

	g_power[0] = (PowerBtn){ .what = "reboot", .label = "重启" };
	g_power[1] = (PowerBtn){ .what = "poweroff", .label = "关机" };
	for (int i = 0; i < 2; i++) {
		GtkWidget *b = gtk_button_new_with_label(g_power[i].label);
		gtk_widget_set_size_request(b, 88, 36);
		gtk_widget_set_can_focus(b, FALSE);
		gtk_style_context_add_class(gtk_widget_get_style_context(b), "lockpower");
		g_power[i].btn = b;
		g_signal_connect(b, "clicked", G_CALLBACK(on_power_clicked), &g_power[i]);
		gtk_box_pack_start(GTK_BOX(prow), b, FALSE, FALSE, 0);
	}
}

static int acquire_singleton(void)
{
	g_lock_fd = open(LOCK_LOCKFILE, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
	if (g_lock_fd < 0)
		return 0;   /* 运行目录不可写：无法保证单实例 */
	if (flock(g_lock_fd, LOCK_EX | LOCK_NB) != 0)
		return 0;
	FILE *f = fopen(LOCK_PIDFILE, "w");
	if (f) {
		fprintf(f, "%d\n", (int)getpid());
		fclose(f);
	}
	return 1;
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--version")) {
			puts("shui-lock 0.1.0");
			return 0;
		}
		if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			puts("用法: shui-lock\n全屏锁屏；正确输入 root 密码后解锁。");
			return 0;
		}
	}

	ensure_swaysock();
	if (!acquire_singleton()) {
		/* 已有锁屏在跑：静默退出，不叠加窗口 */
		return 0;
	}

	gtk_init(&argc, &argv);
	/* 锁屏不接输入法：fcitx 在中文态会把字母吃进 preedit、把 Enter 当候选
	   提交，物理键盘输密码可能根本到不了输入框。强制 GTK 内置 simple IM。 */
	g_object_set(gtk_settings_get_default(), "gtk-im-module",
		     "gtk-im-context-simple", NULL);
	load_root_hash();

	g_bg_src = gdk_pixbuf_new_from_file(WALLPAPER, NULL);

	install_css();

	g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_title(GTK_WINDOW(g_window), "shui-lock");
	gtk_window_set_decorated(GTK_WINDOW(g_window), FALSE);
	gtk_window_set_resizable(GTK_WINDOW(g_window), FALSE);
	gtk_window_set_skip_taskbar_hint(GTK_WINDOW(g_window), TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_window), "lock");
	gtk_layer_init_for_window(GTK_WINDOW(g_window));
	gtk_layer_set_namespace(GTK_WINDOW(g_window), "shui-lock");
	gtk_layer_set_layer(GTK_WINDOW(g_window), GTK_LAYER_SHELL_LAYER_OVERLAY);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_TOP, TRUE);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
	/* -1 是 layer-shell 的“使用整块输出”语义：0 会被任务栏的
	   exclusive_zone=40 裁成 760 高，底部露出一条任务栏。 */
	gtk_layer_set_exclusive_zone(GTK_WINDOW(g_window), -1);
	gtk_layer_set_keyboard_mode(GTK_WINDOW(g_window),
				    GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);

	build_ui();
	g_signal_connect(g_window, "key-press-event", G_CALLBACK(on_window_key), NULL);
	g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	gtk_widget_show_all(g_window);
	gtk_window_set_focus(GTK_WINDOW(g_window), g_entry);
	gtk_widget_grab_focus(g_entry);

	tick_clock(NULL);
	g_timeout_add_seconds(1, tick_clock, NULL);

	/* 界面已经上屏再切 mode：避免切 mode 与首帧之间的空窗 */
	sway_cmd("mode shui-lock");

	g_unix_signal_add(SIGTERM, on_term_signal, NULL);
	g_unix_signal_add(SIGINT, on_term_signal, NULL);
	g_unix_signal_add(SIGHUP, on_term_signal, NULL);

	gtk_main();

	unlink(LOCK_PIDFILE);
	if (g_lock_fd >= 0) {
		flock(g_lock_fd, LOCK_UN);
		close(g_lock_fd);
	}
	if (g_bg_scaled)
		g_object_unref(g_bg_scaled);
	if (g_bg_src)
		g_object_unref(g_bg_src);
	return 0;
}
