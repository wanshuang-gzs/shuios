/*
 * shui-panel — Windows 风格底部任务栏 + 开始菜单
 *
 * 形态（docs/07-界面规划.md）：屏幕底部 40px 通栏任务栏，没有顶栏。
 *   左侧「氵」开始按钮 → 弹出开始菜单；
 *   中间是「固定应用 + 运行中应用」合并的按钮（运行中才有主色下划线）；
 *   右侧是 AI 状态（shui-ctl bar --text）+ 时钟。
 *
 * 任务栏是 **layer-shell surface**（gtk-layer-shell）：
 *   layer=TOP + 锚定底边 + exclusive_zone=40。
 *   所以它不在 sway 的窗口树里（swaymsg -t get_tree 看不到），
 *   平铺/最大化的窗口也会自动避开底部 40px，不会被任务栏盖住。
 *   旧实现是「浮动窗口 + for_window 钉坐标」的 macOS Dock 做法，
 *   在 Windows 形态下既会盖住平铺窗口、又依赖硬编码坐标，已废弃。
 *
 * 开始菜单仍是**独立进程的普通窗口**（`shui-panel --menu`，app_id=shui-panel-menu）：
 *   layer surface 不能弹 xdg_popup（GtkMenu 在 layer 上出不来），
 *   所以菜单用独立 toplevel + 失焦自动收起，位置由 sway 的 for_window 钉住。
 *
 * 色彩/字号/圆角一律取自 shuios-ui.h（唯一色源）。
 */

#include <gtk/gtk.h>
#include <gtk-layer-shell/gtk-layer-shell.h>
#include <math.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "shuios-ui.h"   /* 设计令牌（唯一色源），见 docs/06-视觉规范.md */

#define BAR_H 40      /* 任务栏总高（含 1px 上边框），也是 exclusive_zone */
#define START_W 44    /* 开始按钮宽 */
#define BTN_W 44      /* 每格应用按钮宽 */
#define ICON 24       /* 图标边长 */

typedef struct {
	const char *label;      /* 取不到真图标时，图标里画的那个字 */
	const char *icon;       /* 图标主题里的名字；取到就画真图标 */
	const char *command;    /* 没运行时点击执行 */
	const char *match;      /* Wayland app_id：用来把运行中的窗口挂到按钮上 */
	const char *tooltip;
} AppButton;

static const AppButton APPS[] = {
	{ "终", "utilities-terminal", "/usr/bin/foot -e /usr/bin/shui", "foot", "终端（shui）" },
	{ "文", "system-file-manager", "/usr/bin/shui-files", "shui-files", "文件" },
	{ "览", "web-browser", "/usr/bin/shui-browser", "shui-browser", "浏览器（shui-browser）" },
	{ "店", "system-software-install", "/usr/bin/shui-store", "shui-store", "软件商店" },
};
#define NAPPS ((int)(sizeof(APPS) / sizeof(APPS[0])))

/* 运行中但没固定的应用：按钮动态追加在固定项后面 */
typedef struct {
	char app_id[64];
	char title[160];
	char icon[64];
	char glyph[8];
	GtkWidget *btn;
	GtkWidget *area;
} DynApp;

#define MAX_DYN 16

static GtkWidget *g_window;
static GtkWidget *g_indicators[NAPPS];
static GtkWidget *g_dyn_box;
static GtkWidget *g_clock_time;
static GtkWidget *g_clock_date;
static GtkWidget *g_status;
static GtkWidget *g_vol_btn;
static GtkWidget *g_vol_image;

#define WPCTL "/usr/bin/wpctl"
#define SINK "@DEFAULT_AUDIO_SINK@"

static DynApp g_dyn[MAX_DYN];
static int g_ndyn;

/* 后文定义的函数，前面要用的先声明 */
static int count_app(const char *app_id, int *focused_idx);
static void launch_cmd(const char *cmd);
static void first_glyph(const char *name, char *out, size_t outlen);

/* ---------------------------------------------------------------- 绘图 */

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r)
{
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(cr);
}

static void draw_centered_text(cairo_t *cr, const char *text, double w, double h,
			       double size, double r, double g, double b)
{
	PangoLayout *layout = pango_cairo_create_layout(cr);
	PangoFontDescription *desc = pango_font_description_new();
	pango_font_description_set_family(desc, "WenQuanYi Zen Hei");
	pango_font_description_set_weight(desc, PANGO_WEIGHT_BOLD);
	pango_font_description_set_absolute_size(desc, size * PANGO_SCALE);
	pango_layout_set_font_description(layout, desc);
	pango_layout_set_text(layout, text, -1);

	int tw = 0, th = 0;
	pango_layout_get_pixel_size(layout, &tw, &th);
	cairo_set_source_rgb(cr, r, g, b);
	cairo_move_to(cr, (w - tw) / 2.0, (h - th) / 2.0);
	pango_cairo_show_layout(cr, layout);

	pango_font_description_free(desc);
	g_object_unref(layout);
}

/* 品牌标记「⊙」：一个圆 + 圆心里一个点（开始菜单标题用） */
static void draw_dot_mark(cairo_t *cr, double cx, double cy, double radius,
			  double r, double g, double b)
{
	cairo_set_source_rgb(cr, r, g, b);
	cairo_set_line_width(cr, radius * 0.30);
	cairo_arc(cr, cx, cy, radius, 0, 2 * M_PI);
	cairo_stroke(cr);
	cairo_arc(cr, cx, cy, radius * 0.36, 0, 2 * M_PI);
	cairo_fill(cr);
}

/* 试着从图标主题取一张图标（优先真图标）；取不到返回 NULL。
 *
 * .desktop 里的 Icon= 常常带扩展名（如 foot.svg），而图标主题是按**名字**
 * 索引的——不剥掉扩展名就查不到，只会白白回退成首字母方块（踩过）。 */
static GdkPixbuf *theme_icon(const char *name, int size)
{
	if (!name || !*name)
		return NULL;
	char base[64];
	snprintf(base, sizeof base, "%s", name);
	char *dot = strrchr(base, '.');
	if (dot && (strcmp(dot, ".svg") == 0 || strcmp(dot, ".png") == 0 ||
		    strcmp(dot, ".xpm") == 0))
		*dot = 0;
	GtkIconTheme *theme = gtk_icon_theme_get_default();
	GdkPixbuf *pb = gtk_icon_theme_load_icon(theme, base, size,
						GTK_ICON_LOOKUP_FORCE_SIZE, NULL);
	if (!pb && strcmp(base, name) != 0)
		pb = gtk_icon_theme_load_icon(theme, name, size,
					      GTK_ICON_LOOKUP_FORCE_SIZE, NULL);
	return pb;
}

/* 在 (x, y, w, h) 里居中画一张 pixbuf */
static void draw_pixbuf_centered(cairo_t *cr, GdkPixbuf *pb,
				 double x, double y, double w, double h)
{
	int pw = gdk_pixbuf_get_width(pb);
	int ph = gdk_pixbuf_get_height(pb);
	gdk_cairo_set_source_pixbuf(cr, pb, x + (w - pw) / 2.0, y + (h - ph) / 2.0);
	cairo_paint(cr);
}

/* 一格图标：优先真图标；取不到才画深色底板 + 字 */
static void draw_icon_cell(cairo_t *cr, const char *icon, const char *glyph,
			   double w, double h, double size, double fs)
{
	GdkPixbuf *pb = theme_icon(icon, (int)size);
	if (pb) {
		draw_pixbuf_centered(cr, pb, 0, 0, w, h);
		g_object_unref(pb);
		return;
	}

	double cx = (w - size) / 2.0, cy = (h - size) / 2.0;
	double r = size * 0.22;
	rounded_rect(cr, cx, cy, size, size, r);
	cairo_set_source_rgb(cr, UI_RGB_BG_CARD);
	cairo_fill(cr);
	rounded_rect(cr, cx, cy, size, size, r);
	cairo_set_source_rgb(cr, UI_RGB_LINE);
	cairo_set_line_width(cr, 1);
	cairo_stroke(cr);
	draw_centered_text(cr, glyph && *glyph ? glyph : "?", w, h, fs, UI_RGB_FG_DIM);
}

/* 任务栏里的一格：悬停底 + 图标 + 运行下划线（聚焦的更宽） */
static void draw_bar_button(cairo_t *cr, int w, int h, const char *icon,
			    const char *glyph, gboolean hovered,
			    int running, gboolean focused)
{
	if (hovered) {
		double rr = (h - 8) / 2.0 > UI_RADIUS_SM ? UI_RADIUS_SM : (h - 8) / 2.0;
		rounded_rect(cr, 4, 4, w - 8, h - 8, rr);
		cairo_set_source_rgb(cr, UI_RGB_BG_HOVER);
		cairo_fill(cr);
	}

	draw_icon_cell(cr, icon, glyph, w, h - 4, ICON, UI_FS_META);

	/* Windows 风格：运行中 = 图标下方一条主色短线；聚焦时更长更醒目 */
	if (running) {
		double uw = focused ? 22 : 14;
		rounded_rect(cr, (w - uw) / 2.0, h - 4, uw, 3, 1.5);
		cairo_set_source_rgb(cr, UI_RGB_ACCENT);
		cairo_fill(cr);
	}
}

/* 开始按钮：「氵」，主色 */
static gboolean on_draw_start(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);
	(void)data;

	gboolean hovered = g_object_get_data(G_OBJECT(widget), "hover") != NULL;
	if (hovered) {
		rounded_rect(cr, 4, 4, w - 8, h - 8, UI_RADIUS_SM);
		cairo_set_source_rgb(cr, UI_RGB_BG_HOVER);
		cairo_fill(cr);
	}
	draw_centered_text(cr, "氵", w, h, 20, UI_RGB_ACCENT);
	return FALSE;
}

/* 固定应用的格子 */
static gboolean on_draw_pinned(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	int idx = GPOINTER_TO_INT(data);
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);
	const AppButton *a = &APPS[idx];

	int focused_idx = -1;
	int n = count_app(a->match, &focused_idx);
	gboolean hovered = g_object_get_data(G_OBJECT(widget), "hover") != NULL;
	draw_bar_button(cr, w, h, a->icon, a->label, hovered, n > 0, focused_idx >= 0);
	return FALSE;
}

/* 运行中（未固定）应用的格子 */
static gboolean on_draw_dyn(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	DynApp *d = data;
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);

	int focused_idx = -1;
	int n = count_app(d->app_id, &focused_idx);
	gboolean hovered = g_object_get_data(G_OBJECT(widget), "hover") != NULL;
	draw_bar_button(cr, w, h, d->icon, d->glyph, hovered, n > 0, focused_idx >= 0);
	return FALSE;
}

/* ------------------------------------------------------- 窗口状态（sway） */

/* 从 `shui-ctl windows` 读到的窗口。任务栏按钮与运行指示都由它驱动，
 * 不再靠"扫 /proc 数进程"——那样分不清哪个 foot 是终端、哪个是文件管理器，
 * 也做不出"点击聚焦 / 再点最小化"。 */
typedef struct {
	char app_id[64];
	char title[160];
	char workspace[48];
	int focused;
	unsigned long con_id;
} WinRec;

static WinRec g_wins[24];
static int g_nwins;

/* 用哪个 shui-ctl：优先可写分区里的开发副本（dev 闭环要用），
 * 没有就用镜像里的 /usr/bin/shui-ctl。
 * 注意必须用 access() 判断——popen() 在命令不存在时照样返回非 NULL
 * （shell 会跑起来然后报 not found），靠它做兜底会永远走不到后备分支
 * （踩过：镜像里指示线全是 0，因为一直在调不存在的 dev 副本）。 */
static const char *ctl_path(void)
{
	static char path[160];
	static int resolved;
	if (resolved)
		return path;
	const char *cands[] = { "/var/lib/shuios/dev/shui-ctl", "/usr/bin/shui-ctl" };
	for (size_t i = 0; i < G_N_ELEMENTS(cands); i++) {
		if (access(cands[i], X_OK) == 0) {
			snprintf(path, sizeof path, "%s", cands[i]);
			resolved = 1;
			return path;
		}
	}
	snprintf(path, sizeof path, "shui-ctl");
	resolved = 1;
	return path;
}

/* 跑一次 `shui-ctl windows`，刷新窗口列表 */
static void refresh_windows(void)
{
	char cmd[220];
	snprintf(cmd, sizeof cmd, "%s windows 2>/dev/null", ctl_path());
	FILE *fp = popen(cmd, "r");
	g_nwins = 0;
	if (!fp)
		return;

	char line[512];
	while (fgets(line, sizeof line, fp) && g_nwins < (int)G_N_ELEMENTS(g_wins)) {
		line[strcspn(line, "\n")] = 0;
		if (!*line)
			continue;
		/* app_id \t title \t focused \t con_id \t workspace */
		char *f[5] = { 0 };
		int n = 0;
		char *p = line;
		while (n < 5 && p) {
			f[n++] = p;
			char *tab = strchr(p, '\t');
			if (!tab)
				break;
			*tab = 0;
			p = tab + 1;
		}
		if (n < 4 || !f[0] || !*f[0])
			continue;
		WinRec *w = &g_wins[g_nwins++];
		snprintf(w->app_id, sizeof w->app_id, "%s", f[0]);
		snprintf(w->title, sizeof w->title, "%s", f[1] ? f[1] : "");
		w->focused = (f[2] && f[2][0] == '1');
		w->con_id = strtoul(f[3] ? f[3] : "0", NULL, 10);
		snprintf(w->workspace, sizeof w->workspace, "%s", f[4] ? f[4] : "");
	}
	pclose(fp);
}

/* 某个 app_id 有几个窗口、其中是否有一个聚焦；返回聚焦窗口的下标，没有返回 -1 */
static int count_app(const char *app_id, int *focused_idx)
{
	int n = 0;
	*focused_idx = -1;
	for (int i = 0; i < g_nwins; i++) {
		if (strcmp(g_wins[i].app_id, app_id) != 0)
			continue;
		n++;
		if (g_wins[i].focused)
			*focused_idx = i;
	}
	return n;
}

static int is_pinned(const char *app_id)
{
	for (int i = 0; i < NAPPS; i++)
		if (strcmp(APPS[i].match, app_id) == 0)
			return 1;
	return 0;
}

/* ------------------------------------------------------------ 交互 */

/* 点任务栏按钮：没运行就启动；在 scratchpad 里就还原；运行未聚焦就聚焦；
 * 已聚焦就收进 scratchpad（最小化）。这就是 Windows 任务栏的行为。 */
static void click_app(const char *match, const char *command)
{
	int focused_idx = -1;
	int n = count_app(match, &focused_idx);

	if (n == 0) {
		if (command && *command)
			launch_cmd(command);
		return;
	}

	/* 先看有没有被最小化到 scratchpad 的窗口——有就先还原它 */
	int hidden = -1;
	int last = -1;
	for (int i = 0; i < g_nwins; i++) {
		if (strcmp(g_wins[i].app_id, match) != 0)
			continue;
		last = i;
		if (strcmp(g_wins[i].workspace, "__i3_scratch") == 0)
			hidden = i;
	}

	char cmd[192];
	if (hidden >= 0) {
		snprintf(cmd, sizeof cmd,
			 "/usr/bin/swaymsg '[con_id=%lu] scratchpad show' >/dev/null 2>&1",
			 g_wins[hidden].con_id);
	} else if (focused_idx >= 0) {
		snprintf(cmd, sizeof cmd,
			 "/usr/bin/swaymsg '[con_id=%lu] move scratchpad' >/dev/null 2>&1",
			 g_wins[focused_idx].con_id);
	} else {
		snprintf(cmd, sizeof cmd, "/usr/bin/swaymsg '[con_id=%lu] focus' >/dev/null 2>&1",
			 g_wins[last >= 0 ? last : 0].con_id);
	}
	char *argv[] = { "/bin/sh", "-c", cmd, NULL };
	g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL);
}

/* 右键：关掉该应用当前聚焦（或最后打开）的窗口。
 * layer surface 不能弹 xdg_popup（GtkMenu 出不来），所以先做"直接关闭"；
 * 右键菜单（还原/最小化/关闭）留到 P2 改用独立 toplevel 实现。 */
static void close_app_window(const char *match)
{
	int focused_idx = -1;
	count_app(match, &focused_idx);
	int target = focused_idx;
	if (target < 0) {
		for (int i = 0; i < g_nwins; i++)
			if (strcmp(g_wins[i].app_id, match) == 0)
				target = i;
	}
	if (target < 0)
		return;

	char cmd[192];
	snprintf(cmd, sizeof cmd,
		 "/usr/bin/swaymsg '[con_id=%lu] kill' >/dev/null 2>&1",
		 g_wins[target].con_id);
	launch_cmd(cmd);
}

/* 点任务栏按钮时顺手收起开始菜单（任务栏不抢键盘焦点，菜单自己不会失焦） */
static void close_menu(void)
{
	if (system("pkill -f '[s]hui-panel --menu' 2>/dev/null") != 0) {
		/* 没开着就算了 */
	}
}

static void on_app_clicked(GtkButton *btn, gpointer data)
{
	int idx = GPOINTER_TO_INT(data);
	(void)btn;
	close_menu();
	click_app(APPS[idx].match, APPS[idx].command);
}

static void on_dyn_clicked(GtkButton *btn, gpointer data)
{
	DynApp *d = data;
	(void)btn;
	close_menu();
	click_app(d->app_id, NULL);
}

static gboolean on_pinned_right_click(GtkWidget *w, GdkEventButton *ev, gpointer data)
{
	int idx = GPOINTER_TO_INT(data);
	(void)w;
	if (ev->button != 3)
		return FALSE;
	close_menu();
	close_app_window(APPS[idx].match);
	return TRUE;
}

static gboolean on_dyn_right_click(GtkWidget *w, GdkEventButton *ev, gpointer data)
{
	DynApp *d = data;
	(void)w;
	if (ev->button != 3)
		return FALSE;
	close_menu();
	close_app_window(d->app_id);
	return TRUE;
}

/* 鼠标进入/离开时重画，做出悬停高亮 */
static gboolean on_enter(GtkWidget *w, GdkEventCrossing *ev, gpointer d)
{
	(void)ev; (void)d;
	g_object_set_data(G_OBJECT(w), "hover", GINT_TO_POINTER(1));
	gtk_widget_queue_draw(w);
	return FALSE;
}

static gboolean on_leave(GtkWidget *w, GdkEventCrossing *ev, gpointer d)
{
	(void)ev; (void)d;
	g_object_set_data(G_OBJECT(w), "hover", NULL);
	gtk_widget_queue_draw(w);
	return FALSE;
}

/* ------------------------------------------------- 运行中应用（动态按钮） */

/* 从 .desktop 读一个字段（Icon= / Name=）。app_id 就是文件名。 */
static gboolean desktop_field(const char *app_id, const char *key,
			      char *out, size_t outlen)
{
	const char *dirs[] = {
		"/var/lib/shuios/pkg/share/applications",
		"/usr/share/applications",
	};
	for (size_t i = 0; i < G_N_ELEMENTS(dirs); i++) {
		char path[320];
		snprintf(path, sizeof path, "%s/%s.desktop", dirs[i], app_id);
		GKeyFile *kf = g_key_file_new();
		gboolean ok = g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL);
		char *v = ok ? g_key_file_get_string(kf, "Desktop Entry", key, NULL) : NULL;
		g_key_file_free(kf);
		if (v) {
			snprintf(out, outlen, "%s", v);
			g_free(v);
			return TRUE;
		}
	}
	return FALSE;
}

/* 收集「在跑、没固定、也不是任务栏/菜单自己」的 app_id（按窗口顺序去重） */
static void collect_dynamic(DynApp *out, int *nout)
{
	int n = 0;
	for (int i = 0; i < g_nwins && n < MAX_DYN; i++) {
		const char *id = g_wins[i].app_id;
		if (!*id)
			continue;
		if (is_pinned(id))
			continue;
		if (strncmp(id, "shui-panel", 10) == 0)
			continue;
		int dup = 0;
		for (int j = 0; j < n; j++)
			if (strcmp(out[j].app_id, id) == 0)
				dup = 1;
		if (dup)
			continue;

		memset(&out[n], 0, sizeof out[n]);
		snprintf(out[n].app_id, sizeof out[n].app_id, "%s", id);
		snprintf(out[n].title, sizeof out[n].title, "%s", g_wins[i].title);
		if (!desktop_field(id, "Icon", out[n].icon, sizeof out[n].icon))
			snprintf(out[n].icon, sizeof out[n].icon, "application-x-executable");
		first_glyph(out[n].title[0] ? out[n].title : id,
			    out[n].glyph, sizeof out[n].glyph);
		n++;
	}
	*nout = n;
}

static void make_dyn_button(DynApp *d)
{
	GtkWidget *btn = gtk_button_new();
	gtk_button_set_relief(GTK_BUTTON(btn), GTK_RELIEF_NONE);
	gtk_widget_set_can_focus(btn, FALSE);
	gtk_widget_set_size_request(btn, BTN_W, -1);
	gtk_widget_set_tooltip_text(btn, d->title[0] ? d->title : d->app_id);

	GtkWidget *area = gtk_drawing_area_new();
	gtk_widget_set_size_request(area, BTN_W, -1);
	gtk_widget_set_vexpand(area, TRUE);
	g_signal_connect(area, "draw", G_CALLBACK(on_draw_dyn), d);
	gtk_container_add(GTK_CONTAINER(btn), area);

	g_signal_connect(btn, "clicked", G_CALLBACK(on_dyn_clicked), d);
	g_signal_connect(btn, "button-press-event", G_CALLBACK(on_dyn_right_click), d);
	g_signal_connect(area, "enter-notify-event", G_CALLBACK(on_enter), NULL);
	g_signal_connect(area, "leave-notify-event", G_CALLBACK(on_leave), NULL);
	gtk_style_context_add_class(gtk_widget_get_style_context(btn), "baritem");
	gtk_box_pack_start(GTK_BOX(g_dyn_box), btn, FALSE, FALSE, 0);

	d->btn = btn;
	d->area = area;
}

/* 动态按钮只在 app_id 集合变化时重建；标题变化只更新 tooltip + 重画 */
static void rebuild_dynamic(void)
{
	DynApp next[MAX_DYN];
	int n = 0;
	collect_dynamic(next, &n);

	int same = (n == g_ndyn);
	for (int i = 0; same && i < n; i++)
		if (strcmp(next[i].app_id, g_dyn[i].app_id) != 0)
			same = 0;

	if (same) {
		for (int i = 0; i < n; i++) {
			if (strcmp(next[i].title, g_dyn[i].title) != 0) {
				snprintf(g_dyn[i].title, sizeof g_dyn[i].title, "%s",
					 next[i].title);
				gtk_widget_set_tooltip_text(g_dyn[i].btn,
					g_dyn[i].title[0] ? g_dyn[i].title : g_dyn[i].app_id);
			}
			gtk_widget_queue_draw(g_dyn[i].area);
		}
		return;
	}

	GList *kids = gtk_container_get_children(GTK_CONTAINER(g_dyn_box));
	for (GList *l = kids; l; l = l->next)
		gtk_widget_destroy(GTK_WIDGET(l->data));
	g_list_free(kids);

	for (int i = 0; i < n; i++) {
		g_dyn[i] = next[i];
		make_dyn_button(&g_dyn[i]);
		gtk_widget_show_all(g_dyn[i].btn);
	}
	g_ndyn = n;
}

static void redraw_buttons(void)
{
	for (int i = 0; i < NAPPS; i++)
		if (g_indicators[i])
			gtk_widget_queue_draw(g_indicators[i]);
	for (int i = 0; i < g_ndyn; i++)
		if (g_dyn[i].area)
			gtk_widget_queue_draw(g_dyn[i].area);
}

/* --------------------------------------------------------- 状态行 / 时钟 */

static gboolean update_clock(gpointer data)
{
	(void)data;
	time_t now = time(NULL);
	struct tm tm;
	localtime_r(&now, &tm);
	char t[16], d[16];
	strftime(t, sizeof t, "%H:%M", &tm);
	strftime(d, sizeof d, "%m-%d", &tm);
	gtk_label_set_text(GTK_LABEL(g_clock_time), t);
	gtk_label_set_text(GTK_LABEL(g_clock_date), d);
	return G_SOURCE_CONTINUE;
}

/* AI/内存/根文件系统状态：`shui-ctl bar --text` 一行纯文本 */
static gboolean update_status(gpointer data)
{
	(void)data;
	if (!g_status)
		return G_SOURCE_CONTINUE;

	char cmd[200];
	snprintf(cmd, sizeof cmd, "%s bar --text 2>/dev/null", ctl_path());
	FILE *fp = popen(cmd, "r");
	if (!fp)
		return G_SOURCE_CONTINUE;

	char line[256] = "";
	if (fgets(line, sizeof line, fp))
		line[strcspn(line, "\r\n")] = 0;
	pclose(fp);

	if (line[0]) {
		gtk_label_set_text(GTK_LABEL(g_status), line);
		gtk_widget_show(g_status);
	} else {
		gtk_widget_hide(g_status);
	}
	return G_SOURCE_CONTINUE;
}

/* ---------------------------------------------------- 音量（PipeWire） */

/* 读默认输出的音量/静音；wpctl 不可用或 PipeWire 没起来时返回 FALSE。
 * wpctl 输出形如 "Volume: 0.680000" 或 "Volume: 0.680000 [MUTED]"。 */
static gboolean
wpctl_volume(gint *pct, gboolean *muted)
{
	const gchar *argv[] = { WPCTL, "get-volume", SINK, NULL };
	gchar *o = NULL, *e = NULL;
	gboolean ok = g_spawn_sync(NULL, (gchar **)argv, NULL,
				   G_SPAWN_SEARCH_PATH, NULL, NULL, &o, &e,
				   NULL, NULL);
	gboolean ret = FALSE;

	if (ok && o) {
		const gchar *colon = strchr(o, ':');
		if (colon) {
			gdouble v = g_strtod(colon + 1, NULL);
			if (v < 0.0)
				v = 0.0;
			if (v > 1.0)
				v = 1.0;
			*pct = (gint)(v * 100.0 + 0.5);
			*muted = strstr(o, "MUTED") != NULL;
			ret = TRUE;
		}
	}
	g_free(o);
	g_free(e);
	return ret;
}

static void
wpctl_set_volume(gint pct)
{
	gchar vol[16];
	g_snprintf(vol, sizeof vol, "%d%%", pct);
	const gchar *argv[] = { WPCTL, "set-volume", SINK, vol, NULL };
	gchar *o = NULL, *e = NULL;
	g_spawn_sync(NULL, (gchar **)argv, NULL, G_SPAWN_SEARCH_PATH, NULL,
		     NULL, &o, &e, NULL, NULL);
	g_free(o);
	g_free(e);
}

static void
wpctl_set_mute(gboolean muted)
{
	const gchar *argv[] = { WPCTL, "set-mute", SINK,
			       muted ? "1" : "0", NULL };
	gchar *o = NULL, *e = NULL;
	g_spawn_sync(NULL, (gchar **)argv, NULL, G_SPAWN_SEARCH_PATH, NULL,
		     NULL, &o, &e, NULL, NULL);
	g_free(o);
	g_free(e);
}

/* WirePlumber 不会把默认 sink 的音量写盘（冷启动回到 40% 默认值），
 * 所以用户改音量/静音时自己记一份，会话启动时由 shuios-session.sh 回放。 */
static void
audio_state_save(gint pct, gboolean muted)
{
	g_mkdir_with_parents("/var/lib/shuios/state", 0755);
	gchar *txt = g_strdup_printf("VOLUME=%d\nMUTE=%d\n", pct,
				     muted ? 1 : 0);
	g_file_set_contents("/var/lib/shuios/state/audio.conf", txt, -1, NULL);
	g_free(txt);
}

static void
update_volume_ui(void)
{
	if (!g_vol_btn)
		return;

	gint pct = 0;
	gboolean muted = FALSE;
	if (!wpctl_volume(&pct, &muted)) {
		gtk_image_set_from_icon_name(GTK_IMAGE(g_vol_image),
					     "audio-volume-muted",
					     GTK_ICON_SIZE_MENU);
		gtk_widget_set_tooltip_text(g_vol_btn,
					    "音频服务未运行（PipeWire）");
		gtk_widget_set_sensitive(g_vol_btn, FALSE);
		return;
	}
	gtk_widget_set_sensitive(g_vol_btn, TRUE);

	const char *icon;
	if (muted || pct == 0)
		icon = "audio-volume-muted";
	else if (pct < 34)
		icon = "audio-volume-low";
	else if (pct < 67)
		icon = "audio-volume-medium";
	else
		icon = "audio-volume-high";
	gtk_image_set_from_icon_name(GTK_IMAGE(g_vol_image), icon,
				     GTK_ICON_SIZE_MENU);

	gchar *tip = muted
		? g_strdup_printf("音量 %d%%（已静音，左键取消，右键设置）", pct)
		: g_strdup_printf("音量 %d%%（左键静音，滚轮调节，右键设置）",
				  pct);
	gtk_widget_set_tooltip_text(g_vol_btn, tip);
	g_free(tip);
}

static gboolean
volume_tick(gpointer data)
{
	(void)data;
	update_volume_ui();
	return G_SOURCE_CONTINUE;
}

static void
on_volume_clicked(GtkButton *btn, gpointer data)
{
	(void)btn;
	(void)data;
	gint pct = 0;
	gboolean muted = FALSE;
	if (!wpctl_volume(&pct, &muted))
		return;
	wpctl_set_mute(!muted);
	audio_state_save(pct, !muted);
	update_volume_ui();
}

static gboolean
on_volume_scroll(GtkWidget *w, GdkEventScroll *ev, gpointer data)
{
	(void)w;
	(void)data;
	gint pct = 0;
	gboolean muted = FALSE;
	if (!wpctl_volume(&pct, &muted))
		return FALSE;

	gint delta = 0;
	if (ev->direction == GDK_SCROLL_UP)
		delta = 5;
	else if (ev->direction == GDK_SCROLL_DOWN)
		delta = -5;
	else if (ev->direction == GDK_SCROLL_SMOOTH) {
		if (ev->delta_y < 0)
			delta = 5;
		else if (ev->delta_y > 0)
			delta = -5;
	}
	if (!delta)
		return FALSE;

	gint next = CLAMP(pct + delta, 0, 100);
	wpctl_set_volume(next);
	if (muted && next > 0)
		wpctl_set_mute(FALSE);
	audio_state_save(next, muted && next == 0);
	update_volume_ui();
	return TRUE;
}

static gboolean
on_volume_pressed(GtkWidget *w, GdkEventButton *ev, gpointer data)
{
	(void)w;
	(void)data;
	if (ev->button != 3)
		return FALSE;
	const char *path =
		access("/var/lib/shuios/dev/shui-settings", X_OK) == 0
		? "/var/lib/shuios/dev/shui-settings"
		: "/usr/bin/shui-settings";
	char cmd[256];
	snprintf(cmd, sizeof cmd, "%s --sound", path);
	launch_cmd(cmd);
	return TRUE;
}

/* ------------------------------------------------------- 窗口事件流 */

static FILE *g_stream;
static guint g_pending_refresh;

static gboolean do_refresh(gpointer data)
{
	(void)data;
	g_pending_refresh = 0;
	refresh_windows();
	rebuild_dynamic();
	redraw_buttons();
	return FALSE;
}

static gboolean on_stream_event(GIOChannel *ch, GIOCondition cond, gpointer data)
{
	(void)ch;
	(void)data;
	char line[512];
	if (!(cond & G_IO_IN))
		return TRUE;
	/* 读掉一行（内容不用解析：事件到达后重新拉一遍完整列表更可靠） */
	if (!fgets(line, sizeof line, g_stream))
		return FALSE; /* EOF：保持现状，不再订阅 */
	if (g_pending_refresh == 0)
		g_pending_refresh = g_timeout_add(150, do_refresh, NULL);
	return TRUE;
}

static void start_window_stream(void)
{
	char cmd[240];
	snprintf(cmd, sizeof cmd, "%s windows --follow 2>/dev/null", ctl_path());
	g_stream = popen(cmd, "r");
	if (!g_stream) {
		g_printerr("shui-panel: 无法启动窗口事件流（任务栏只显示固定项）\n");
		return;
	}
	GIOChannel *chan = g_io_channel_unix_new(fileno(g_stream));
	g_io_add_watch(chan, G_IO_IN | G_IO_HUP, on_stream_event, NULL);
}

/* ------------------------------------------------------------ 开始菜单 */

/* 菜单里的一项（固定项或从 .desktop 读出来的应用） */
typedef struct {
	char name[64];  /* 显示名（已去掉品牌前缀） */
	char cmd[256];  /* 启动命令 */
	char glyph[8];  /* 取不到真图标时画的那个字 */
	char icon[64];  /* 图标主题里的名字（.desktop 的 Icon=） */
} AppEnt;

static AppEnt g_apps[48];
static int g_napps;

static GtkWidget *g_flow;    /* 应用网格 */
static GtkWidget *g_search;  /* 搜索框 */

static void launch_cmd(const char *cmd)
{
	char *argv[] = { "/bin/sh", "-c", (char *)cmd, NULL };
	GError *err = NULL;
	if (!g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, &err)) {
		g_printerr("shui-panel: 启动失败 %s: %s\n", cmd, err ? err->message : "?");
		if (err)
			g_error_free(err);
	}
}

/* 品牌前缀「氵」：.desktop 里的 Name 常写成「氵 软件商店」，
 * 单独一个偏旁当显示名难看且会让去重失效（固定项叫「软件商店」，
 * 扫出来的叫「氵 软件商店」，strcmp 判不出同一个，于是菜单里出现两份）。 */
#define BRAND_PREFIX "\xe6\xb0\xb5"

static int is_utf8_ws(unsigned char c)
{
	return c == ' ' || c == '\t';
}

/* 剥掉品牌前缀和前导空白后的显示名 */
static const char *display_name(const char *name)
{
	int skipping = 1;
	if (name && g_str_has_prefix(name, BRAND_PREFIX))
		name += strlen(BRAND_PREFIX);
	while (name && skipping) {
		skipping = 0;
		while (*name && is_utf8_ws((unsigned char)*name)) {
			name++;
			skipping = 1;
		}
	}
	return name ? name : "";
}

/* 剥掉品牌前缀和**所有**空白，只留比对用的骨架 */
static void norm_name(const char *name, char *out, size_t outlen)
{
	size_t k = 0;
	if (name && g_str_has_prefix(name, BRAND_PREFIX))
		name += strlen(BRAND_PREFIX);
	for (; name && *name && k < outlen - 1; name++)
		if (*(const unsigned char *)name > 0x20)
			out[k++] = *name;
	out[k] = 0;
}

/* 取显示名的第一个字符（UTF-8 安全：按首字节判断长度） */
static void first_glyph(const char *name, char *out, size_t outlen)
{
	out[0] = 0;
	name = display_name(name);
	if (!name || !*name)
		return;
	unsigned char c = (unsigned char)name[0];
	size_t n = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
	if (n >= outlen)
		n = outlen - 1;
	memcpy(out, name, n);
	out[n] = 0;
}

static void add_app(const char *name, const char *cmd, const char *icon)
{
	if (g_napps >= (int)G_N_ELEMENTS(g_apps))
		return;
	name = display_name(name);
	if (!name || !*name || !cmd || !*cmd)
		return;
	char key[64];
	norm_name(name, key, sizeof key);          /* 同名去重（忽略前缀/空白） */
	if (!key[0])
		return;
	for (int i = 0; i < g_napps; i++) {
		char have[64];
		norm_name(g_apps[i].name, have, sizeof have);
		if (strcmp(have, key) == 0)
			return;
	}
	AppEnt *a = &g_apps[g_napps++];
	snprintf(a->name, sizeof a->name, "%s", name);
	snprintf(a->cmd, sizeof a->cmd, "%s", cmd);
	snprintf(a->icon, sizeof a->icon, "%s", icon ? icon : "");
	first_glyph(name, a->glyph, sizeof a->glyph);
}

/* 扫描一个目录下的 .desktop，把 Name / Exec / Terminal 摘出来 */
static void scan_desktop_dir(const char *dir)
{
	GDir *d = g_dir_open(dir, 0, NULL);
	if (!d)
		return;
	const char *fn;
	while ((fn = g_dir_read_name(d)) != NULL) {
		if (!g_str_has_suffix(fn, ".desktop"))
			continue;
		char path[256];
		snprintf(path, sizeof path, "%s/%s", dir, fn);
		gchar *content = NULL;
		if (!g_file_get_contents(path, &content, NULL, NULL))
			continue;

		char name[96] = "", exec[224] = "", icon[64] = "";
		int terminal = 0, nodisplay = 0;
		gchar **lines = g_strsplit(content, "\n", -1);
		for (int i = 0; lines[i]; i++) {
			const char *ln = lines[i];
			if (g_str_has_prefix(ln, "Name=") && !name[0])
				snprintf(name, sizeof name, "%s", ln + 5);
			else if (g_str_has_prefix(ln, "Icon=") && !icon[0])
				snprintf(icon, sizeof icon, "%s", ln + 5);
			else if (g_str_has_prefix(ln, "Exec=") && !exec[0])
				snprintf(exec, sizeof exec, "%s", ln + 5);
			else if (g_str_has_prefix(ln, "Terminal=true"))
				terminal = 1;
			else if (g_str_has_prefix(ln, "NoDisplay=true"))
				nodisplay = 1;
		}
		g_strfreev(lines);
		g_free(content);

		if (!name[0] || !exec[0] || nodisplay)
			continue;

		/* 去掉 %f %U 之类的占位符 */
		char clean[224] = "";
		size_t k = 0;
		for (size_t i = 0; exec[i] && k < sizeof clean - 1; i++) {
			if (exec[i] == '%' && exec[i + 1]) {
				i++;
				continue;
			}
			clean[k++] = exec[i];
		}
		clean[k] = 0;

		if (terminal) {
			char wrapped[300];
			snprintf(wrapped, sizeof wrapped,
				 "/usr/bin/foot -e /usr/bin/env TERM=xterm-256color %s", clean);
			add_app(name, wrapped, icon);
		} else {
			add_app(name, clean, icon);
		}
	}
	g_dir_close(d);
}

static void load_apps(void)
{
	g_napps = 0;
	/* 固定项：桌面自带的几个 */
	add_app("终端", "/usr/bin/foot -e /usr/bin/shui", "utilities-terminal");
	add_app("浏览器", "/usr/bin/shui-browser", "web-browser");
	add_app("文件", "/usr/bin/shui-files", "system-file-manager");
	add_app("软件商店", "/usr/bin/shui-store", "system-software-install");
	/* 已装软件（shui-pkg 装的会在第二个目录里） */
	scan_desktop_dir("/var/lib/shuios/pkg/share/applications");
	scan_desktop_dir("/usr/share/applications");
}

/* 网格里的一格：48px 图标 + 名字 */
static gboolean on_draw_tile_icon(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	const AppEnt *a = data;
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);
	draw_icon_cell(cr, a->icon, a->glyph, w, h, 48, UI_FS_META);
	return FALSE;
}

static void on_tile_clicked(GtkButton *btn, gpointer data)
{
	AppEnt *a = data;
	(void)btn;
	launch_cmd(a->cmd);
	gtk_main_quit();   /* 菜单是独立进程：点完就收 */
}

static GtkWidget *make_tile(AppEnt *a)
{
	GtkWidget *btn = gtk_button_new();
	gtk_button_set_relief(GTK_BUTTON(btn), GTK_RELIEF_NONE);
	gtk_widget_set_tooltip_text(btn, a->cmd);

	GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
	GtkWidget *icon = gtk_drawing_area_new();
	gtk_widget_set_size_request(icon, 48, 48);
	gtk_widget_set_halign(icon, GTK_ALIGN_CENTER);
	g_signal_connect(icon, "draw", G_CALLBACK(on_draw_tile_icon), a);
	gtk_box_pack_start(GTK_BOX(col), icon, FALSE, FALSE, 0);

	GtkWidget *label = gtk_label_new(a->name);
	/* 不再单行省略号截断：最多两行，换行显示 */
	gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_NONE);
	gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
	gtk_label_set_line_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
	gtk_label_set_lines(GTK_LABEL(label), 2);
	gtk_label_set_justify(GTK_LABEL(label), GTK_JUSTIFY_CENTER);
	gtk_label_set_max_width_chars(GTK_LABEL(label), 10);
	gtk_widget_set_halign(label, GTK_ALIGN_CENTER);
	gtk_style_context_add_class(gtk_widget_get_style_context(label), "tilelabel");
	gtk_box_pack_start(GTK_BOX(col), label, FALSE, FALSE, 0);

	gtk_container_add(GTK_CONTAINER(btn), col);
	g_signal_connect(btn, "clicked", G_CALLBACK(on_tile_clicked), a);
	gtk_style_context_add_class(gtk_widget_get_style_context(btn), "menutile");
	return btn;
}

/* 按关键字重建网格（空关键字=全部） */
static void fill_grid(const char *filter)
{
	GList *kids = gtk_container_get_children(GTK_CONTAINER(g_flow));
	for (GList *l = kids; l; l = l->next)
		gtk_widget_destroy(GTK_WIDGET(l->data));
	g_list_free(kids);

	char *needle = NULL;
	if (filter && *filter)
		needle = g_ascii_strdown(filter, -1);

	int shown = 0;
	for (int i = 0; i < g_napps; i++) {
		if (needle) {
			char *hay = g_ascii_strdown(g_apps[i].name, -1);
			int hit = strstr(hay, needle) != NULL;
			g_free(hay);
			if (!hit)
				continue;
		}
		gtk_flow_box_insert(GTK_FLOW_BOX(g_flow), make_tile(&g_apps[i]), -1);
		shown++;
	}
	if (shown == 0) {
		GtkWidget *empty = gtk_label_new("没有匹配的应用");
		gtk_style_context_add_class(gtk_widget_get_style_context(empty), "menuhint");
		gtk_flow_box_insert(GTK_FLOW_BOX(g_flow), empty, -1);
	}
	gtk_widget_show_all(g_flow);
	g_free(needle);
}

static void on_search_changed(GtkSearchEntry *e, gpointer data)
{
	(void)data;
	fill_grid(gtk_entry_get_text(GTK_ENTRY(e)));
}

/* 电源按钮：data 是 "poweroff" / "reboot" */
static void on_power(GtkButton *btn, gpointer data)
{
	const char *what = data;
	(void)btn;
	char cmd[64];
	snprintf(cmd, sizeof cmd, "/usr/bin/systemctl %s", what);
	launch_cmd(cmd);
	gtk_main_quit();
}

/* 锁屏：菜单是独立进程，先收菜单再锁屏（锁屏窗口要独占键盘） */
static void on_lock(GtkButton *btn, gpointer data)
{
	(void)btn;
	(void)data;
	/* 先让菜单消失，避免锁屏第一帧下面还压着一个开始菜单 */
	gtk_widget_hide(g_window);
	launch_cmd("/usr/bin/shui-lock");
	gtk_main_quit();
}

/* 注销：退出 sway，shuios-desktop.service（Restart=always）3 秒后重建会话 */
static void on_logout(GtkButton *btn, gpointer data)
{
	(void)btn;
	(void)data;
	launch_cmd("/usr/bin/swaymsg exit");
	gtk_main_quit();
}

/* 菜单失焦就退出（等价于"点别处收起"） */
static gboolean on_menu_focus_out(GtkWidget *w, GdkEventFocus *ev, gpointer d)
{
	(void)w;
	(void)ev;
	(void)d;
	gtk_main_quit();
	return FALSE;
}

/* 菜单标题里的「⊙」（主色） */
static gboolean on_draw_menu_mark(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	int w = gtk_widget_get_allocated_width(widget);
	int h = gtk_widget_get_allocated_height(widget);
	(void)data;
	draw_dot_mark(cr, w / 2.0, h / 2.0, h * 0.34, UI_RGB_ACCENT);
	return FALSE;
}

/* 菜单模式：当作独立进程运行（`shui-panel --menu`）。
 *
 * 为什么不让任务栏直接开一个子窗口：Wayland 的 app_id 来自进程名，
 * 子窗口会和任务栏共用 app_id=shui-panel，于是 sway 的
 * `for_window [app_id="shui-panel-menu"]` 规则匹配不上。
 * 独立进程里 g_set_prgname("shui-panel-menu") 之后 app_id 才是对的。 */
static void run_menu_mode(void)
{
	load_apps();

	g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_title(GTK_WINDOW(g_window), "开始");
	gtk_window_set_decorated(GTK_WINDOW(g_window), FALSE);
	gtk_window_set_resizable(GTK_WINDOW(g_window), FALSE);
	gtk_window_set_skip_taskbar_hint(GTK_WINDOW(g_window), TRUE);
	gtk_window_set_default_size(GTK_WINDOW(g_window), 460, 520);
	/* 圆角要靠透明窗口 + 内层面板自己画，否则四角是窗口底色 */
	GdkScreen *scr = gdk_screen_get_default();
	GdkVisual *vis = gdk_screen_get_rgba_visual(scr);
	gtk_widget_set_app_paintable(g_window, TRUE);
	if (vis)
		gtk_widget_set_visual(g_window, vis);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_window), "startmenu");
	g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
	g_signal_connect(g_window, "focus-out-event", G_CALLBACK(on_menu_focus_out), NULL);

	GtkWidget *panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_style_context_add_class(gtk_widget_get_style_context(panel), "menupanel");
	gtk_container_add(GTK_CONTAINER(g_window), panel);

	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
	gtk_widget_set_margin_top(box, 12);
	gtk_widget_set_margin_bottom(box, 10);
	gtk_widget_set_margin_start(box, 12);
	gtk_widget_set_margin_end(box, 12);
	gtk_box_pack_start(GTK_BOX(panel), box, TRUE, TRUE, 0);

	/* 标题行：⊙ + shuios */
	GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
	GtkWidget *mark = gtk_drawing_area_new();
	gtk_widget_set_size_request(mark, 22, 22);
	g_signal_connect(mark, "draw", G_CALLBACK(on_draw_menu_mark), NULL);
	gtk_box_pack_start(GTK_BOX(head), mark, FALSE, FALSE, 0);
	GtkWidget *title = gtk_label_new(NULL);
	gtk_label_set_markup(GTK_LABEL(title), "<b>shuios</b>");
	gtk_widget_set_halign(title, GTK_ALIGN_START);
	gtk_style_context_add_class(gtk_widget_get_style_context(title), "menutitle");
	gtk_box_pack_start(GTK_BOX(head), title, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), head, FALSE, FALSE, 0);

	/* 搜索框 */
	g_search = gtk_search_entry_new();
	gtk_entry_set_placeholder_text(GTK_ENTRY(g_search), "搜索应用…");
	g_signal_connect(g_search, "search-changed", G_CALLBACK(on_search_changed), NULL);
	gtk_box_pack_start(GTK_BOX(box), g_search, FALSE, FALSE, 0);

	/* 「已固定」小节标题 */
	GtkWidget *section = gtk_label_new("已固定");
	gtk_widget_set_halign(section, GTK_ALIGN_START);
	gtk_widget_set_margin_start(section, 4);
	gtk_widget_set_margin_top(section, 4);
	gtk_style_context_add_class(gtk_widget_get_style_context(section), "menuhint");
	gtk_box_pack_start(GTK_BOX(box), section, FALSE, FALSE, 0);

	/* 应用网格 */
	GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
				       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	gtk_box_pack_start(GTK_BOX(box), scroll, TRUE, TRUE, 0);

	g_flow = gtk_flow_box_new();
	gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(g_flow), TRUE);
	gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(g_flow), 4);
	gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(g_flow), 3);
	gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(g_flow), 4);
	gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(g_flow), 4);
	gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(g_flow), GTK_SELECTION_NONE);
	gtk_container_add(GTK_CONTAINER(scroll), g_flow);

	/* 底部：锁屏 / 注销 / 重启 / 关机 */
	GtkWidget *foot_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
	gtk_widget_set_halign(foot_row, GTK_ALIGN_END);
	GtkWidget *b_lock = gtk_button_new_with_label("锁屏");
	GtkWidget *b_out = gtk_button_new_with_label("注销");
	GtkWidget *b_off = gtk_button_new_with_label("关机");
	GtkWidget *b_re = gtk_button_new_with_label("重启");
	gtk_style_context_add_class(gtk_widget_get_style_context(b_lock), "powerprimary");
	gtk_style_context_add_class(gtk_widget_get_style_context(b_out), "power");
	gtk_style_context_add_class(gtk_widget_get_style_context(b_off), "power");
	gtk_style_context_add_class(gtk_widget_get_style_context(b_re), "power");
	g_signal_connect(b_lock, "clicked", G_CALLBACK(on_lock), NULL);
	g_signal_connect(b_out, "clicked", G_CALLBACK(on_logout), NULL);
	g_signal_connect(b_off, "clicked", G_CALLBACK(on_power), (gpointer)"poweroff");
	g_signal_connect(b_re, "clicked", G_CALLBACK(on_power), (gpointer)"reboot");
	gtk_box_pack_start(GTK_BOX(foot_row), b_lock, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(foot_row), b_out, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(foot_row), b_re, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(foot_row), b_off, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), foot_row, FALSE, FALSE, 0);

	fill_grid("");
	gtk_widget_show_all(g_window);
}

/* 菜单可执行文件：dev 闭环优先用可写分区里的新二进制（与 ctl_path 同理），
 * 镜像里没有 /var/lib/shuios/dev 时自然回落到 /usr/bin。 */
static const char *panel_path(void)
{
	if (access("/var/lib/shuios/dev/shui-panel", X_OK) == 0)
		return "/var/lib/shuios/dev/shui-panel";
	return "/usr/bin/shui-panel";
}

static void on_start_clicked(GtkButton *btn, gpointer data)
{
	(void)btn;
	(void)data;
	/* 菜单交给独立进程（这样它有正确的 Wayland app_id）。
	   再点一次开始按钮 = 收起：菜单是独立进程，用 pgrep/pkill 判断与关闭。
	   模式必须写成 [s]hui-panel：system() 带重定向时 /bin/sh 会 fork 而不是
	   exec，shell 自己的 cmdline 里就含启动命令，普通模式会自匹配（永远走
	   「已打开」分支，菜单永远弹不出来）。 */
	if (system("pgrep -f '[s]hui-panel --menu' >/dev/null 2>&1") == 0) {
		if (system("pkill -f '[s]hui-panel --menu'") != 0)
			g_printerr("shui-panel: 关闭开始菜单失败\n");
		return;
	}
	char cmd[200];
	snprintf(cmd, sizeof cmd, "%s --menu", panel_path());
	launch_cmd(cmd);
}

/* ------------------------------------------------------------ 样式 */

static void install_css(void)
{
	/* 所有色值/字号/圆角都来自 shuios-ui.h，不在本函数里再写一遍 hex */
	const char *css =
		/* 任务栏：深色面板 + 1px 顶边线（Windows 风格） */
		"window.taskbar { background-image: none; background-color: " UI_HEX_BG_PANEL ";"
		"  border-top: 1px solid " UI_HEX_LINE "; }\n"
		/* 按钮一律去掉主题底：任务栏与菜单里的格子都自己画 */
		"button { background: none; border: none; padding: 0; margin: 0;"
		"  min-height: 0; min-width: 0; box-shadow: none; background-image: none;"
		"  outline: none; }\n"
		"button:hover { background: none; }\n"
		".taskclock { color: " UI_HEX_FG "; font-size: " UI_STR(UI_FS_LABEL) "px; font-weight: bold; }\n"
		".taskdate { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		".taskstatus { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		".taskvol { border-radius: " UI_STR(UI_RADIUS) "px;"
		"  padding: 0 6px; }\n"
		".taskvol:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		/* 开始菜单：窗口本身透明，圆角/描边由内层 menupanel 画 */
		"window.startmenu { background-color: transparent; }\n"
		".menupanel { background-color: " UI_HEX_BG_PANEL ";"
		"  border: 1px solid " UI_HEX_LINE ";"
		"  border-radius: " UI_STR(UI_RADIUS_CARD) "px; }\n"
		"button.menutile { border-radius: " UI_STR(UI_RADIUS) "px; background: none;"
		"  background-image: none; box-shadow: none; padding: " UI_STR(UI_SP_1) "px; }\n"
		"button.menutile:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		".menutitle { color: " UI_HEX_FG "; font-size: " UI_STR(UI_FS_BODY) "px; font-weight: bold; }\n"
		".menuhint { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		".tilelabel { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		"window.startmenu entry { background-image: none; background-color: " UI_HEX_BG_CARD ";"
		"  color: " UI_HEX_FG "; border-radius: " UI_STR(UI_RADIUS) "px;"
		"  border: 1px solid " UI_HEX_LINE "; box-shadow: none; outline: none;"
		"  padding: " UI_STR(UI_SP_1) "px " UI_STR(UI_SP_2) "px; }\n"
		"window.startmenu entry:focus { border-color: " UI_HEX_ACCENT "; }\n"
		"button.power { background-color: " UI_HEX_BG_CARD "; color: " UI_HEX_FG_DIM ";"
		"  border-radius: " UI_STR(UI_RADIUS) "px; padding: " UI_STR(UI_SP_1) "px "
		UI_STR(UI_SP_4) "px; background-image: none; }\n"
		"button.power:hover { background-color: " UI_HEX_BG_HOVER "; color: " UI_HEX_FG "; }\n"
		"button.powerprimary { background-color: " UI_HEX_ACCENT "; color: " UI_HEX_ACCENT_ON ";"
		"  border-radius: " UI_STR(UI_RADIUS) "px; padding: " UI_STR(UI_SP_1) "px "
		UI_STR(UI_SP_4) "px; font-weight: bold; background-image: none; }\n"
		"button.powerprimary:hover { background-color: " UI_HEX_ACCENT_HI "; }\n";

	GtkCssProvider *prov = gtk_css_provider_new();
	gtk_css_provider_load_from_data(prov, css, -1, NULL);
	gtk_style_context_add_provider_for_screen(
		gdk_screen_get_default(), GTK_STYLE_PROVIDER(prov),
		GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(prov);
}

/* 任务栏里的一个方格按钮：固定尺寸 + 自绘区（悬停/运行状态都在 draw 里画） */
static GtkWidget *make_bar_button(int width, GCallback draw_cb, gpointer data)
{
	GtkWidget *btn = gtk_button_new();
	gtk_button_set_relief(GTK_BUTTON(btn), GTK_RELIEF_NONE);
	gtk_widget_set_can_focus(btn, FALSE);
	gtk_widget_set_size_request(btn, width, -1);

	GtkWidget *area = gtk_drawing_area_new();
	gtk_widget_set_size_request(area, width, -1);
	gtk_widget_set_vexpand(area, TRUE);
	g_signal_connect(area, "draw", draw_cb, data);
	gtk_container_add(GTK_CONTAINER(btn), area);
	g_signal_connect(area, "enter-notify-event", G_CALLBACK(on_enter), NULL);
	g_signal_connect(area, "leave-notify-event", G_CALLBACK(on_leave), NULL);
	return btn;
}

/* ------------------------------------------------------------ 主任务栏 */

/* sway 通过 exec 给会话进程导出 SWAYSOCK，但手动/SSH 起面板时没有，
 * 这时里面对 swaymsg 的调用会静默失败（点击最小化/聚焦全不生效，踩过）。
 * 兜底：在运行目录里找一次 sway-ipc.*.sock 并补上环境变量。 */
static void ensure_swaysock(void)
{
	if (getenv("SWAYSOCK"))
		return;
	const char *rt = getenv("XDG_RUNTIME_DIR");
	if (!rt || !*rt)
		rt = "/run/shuios/compositor";
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

static void setup_taskbar(void)
{
	ensure_swaysock();

	g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_title(GTK_WINDOW(g_window), "shui-taskbar");
	gtk_window_set_decorated(GTK_WINDOW(g_window), FALSE);
	gtk_window_set_resizable(GTK_WINDOW(g_window), FALSE);
	gtk_window_set_skip_taskbar_hint(GTK_WINDOW(g_window), TRUE);
	gtk_window_set_accept_focus(GTK_WINDOW(g_window), FALSE);
	gtk_widget_set_size_request(g_window, -1, BAR_H);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_window), "taskbar");
	g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	/* layer-shell：底部通栏、置顶图层、独占 40px。
	 * exclusive_zone 是关键——平铺/最大化的窗口会自动停在这 40px 之上。 */
	gtk_layer_init_for_window(GTK_WINDOW(g_window));
	gtk_layer_set_namespace(GTK_WINDOW(g_window), "shui-panel");
	gtk_layer_set_layer(GTK_WINDOW(g_window), GTK_LAYER_SHELL_LAYER_TOP);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_BOTTOM, TRUE);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_LEFT, TRUE);
	gtk_layer_set_anchor(GTK_WINDOW(g_window), GTK_LAYER_SHELL_EDGE_RIGHT, TRUE);
	gtk_layer_set_exclusive_zone(GTK_WINDOW(g_window), BAR_H);
	gtk_layer_set_keyboard_mode(GTK_WINDOW(g_window),
				    GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);

	GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
	gtk_container_add(GTK_CONTAINER(g_window), row);

	/* 开始按钮（最左） */
	GtkWidget *btn_start = make_bar_button(START_W, G_CALLBACK(on_draw_start), NULL);
	gtk_widget_set_margin_start(btn_start, 6);
	gtk_widget_set_tooltip_text(btn_start, "开始");
	g_signal_connect(btn_start, "clicked", G_CALLBACK(on_start_clicked), NULL);
	gtk_box_pack_start(GTK_BOX(row), btn_start, FALSE, FALSE, 0);

	/* 固定应用 */
	for (int i = 0; i < NAPPS; i++) {
		GtkWidget *btn = make_bar_button(BTN_W, G_CALLBACK(on_draw_pinned),
						 GINT_TO_POINTER(i));
		g_indicators[i] = gtk_bin_get_child(GTK_BIN(btn));
		gtk_widget_set_tooltip_text(btn, APPS[i].tooltip);
		g_signal_connect(btn, "clicked", G_CALLBACK(on_app_clicked),
				 GINT_TO_POINTER(i));
		g_signal_connect(btn, "button-press-event",
				 G_CALLBACK(on_pinned_right_click), GINT_TO_POINTER(i));
		gtk_box_pack_start(GTK_BOX(row), btn, FALSE, FALSE, 0);
	}

	/* 运行中但未固定的应用（动态） */
	g_dyn_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
	gtk_box_pack_start(GTK_BOX(row), g_dyn_box, FALSE, FALSE, 0);

	GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	gtk_box_pack_start(GTK_BOX(row), spacer, TRUE, TRUE, 0);

	/* 音量（PipeWire）：左键静音、滚轮调节、右键打开设置的声音页 */
	g_vol_btn = gtk_button_new();
	g_vol_image = gtk_image_new_from_icon_name("audio-volume-high",
						   GTK_ICON_SIZE_MENU);
	gtk_image_set_pixel_size(GTK_IMAGE(g_vol_image), 16);
	gtk_container_add(GTK_CONTAINER(g_vol_btn), g_vol_image);
	gtk_widget_set_size_request(g_vol_btn, 32, 28);
	gtk_widget_set_can_focus(g_vol_btn, FALSE);
	gtk_widget_set_valign(g_vol_btn, GTK_ALIGN_CENTER);
	gtk_widget_set_margin_end(g_vol_btn, 2);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_vol_btn),
				    "taskvol");
	g_signal_connect(g_vol_btn, "clicked",
			 G_CALLBACK(on_volume_clicked), NULL);
	g_signal_connect(g_vol_btn, "scroll-event",
			 G_CALLBACK(on_volume_scroll), NULL);
	g_signal_connect(g_vol_btn, "button-press-event",
			 G_CALLBACK(on_volume_pressed), NULL);
	gtk_box_pack_start(GTK_BOX(row), g_vol_btn, FALSE, FALSE, 0);

	/* 状态（AI 智能体 / 内存 / 根文件系统） */
	g_status = gtk_label_new(NULL);
	gtk_label_set_ellipsize(GTK_LABEL(g_status), PANGO_ELLIPSIZE_END);
	gtk_label_set_max_width_chars(GTK_LABEL(g_status), 32);
	gtk_widget_set_valign(g_status, GTK_ALIGN_CENTER);
	gtk_widget_set_margin_end(g_status, 12);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_status), "taskstatus");
	gtk_box_pack_start(GTK_BOX(row), g_status, FALSE, FALSE, 0);

	/* 时钟：上行 HH:MM、下行 MM-DD（竖排，适配 40px 高） */
	GtkWidget *clk = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_widget_set_valign(clk, GTK_ALIGN_CENTER);
	gtk_widget_set_margin_start(clk, 4);
	gtk_widget_set_margin_end(clk, 12);
	g_clock_time = gtk_label_new("");
	g_clock_date = gtk_label_new("");
	gtk_widget_set_halign(g_clock_time, GTK_ALIGN_END);
	gtk_widget_set_halign(g_clock_date, GTK_ALIGN_END);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_clock_time), "taskclock");
	gtk_style_context_add_class(gtk_widget_get_style_context(g_clock_date), "taskdate");
	gtk_box_pack_start(GTK_BOX(clk), g_clock_time, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(clk), g_clock_date, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(row), clk, FALSE, FALSE, 0);

	update_clock(NULL);
	refresh_windows();
	rebuild_dynamic();
	redraw_buttons();

	gtk_widget_show_all(g_window);
	update_status(NULL);
	update_volume_ui();
	start_window_stream();
	g_timeout_add_seconds(10, update_clock, NULL);
	g_timeout_add_seconds(20, update_status, NULL);
	g_timeout_add_seconds(3, volume_tick, NULL);
}

int main(int argc, char **argv)
{
	gboolean menu_mode = FALSE;
	for (int i = 1; i < argc; i++)
		if (strcmp(argv[i], "--menu") == 0)
			menu_mode = TRUE;

	/* 菜单是独立进程：先定进程名，Wayland 的 app_id 会跟着变，
	   这样 sway 的 for_window [app_id="shui-panel-menu"] 才能命中。 */
	if (menu_mode)
		g_set_prgname("shui-panel-menu");

	/* 显式 CSS 只管任务栏/菜单这几个面；滚动条、选中高亮等交给 Adwaita 深色，
	 * 否则浅色主题会在近黑底上漏出白条。必须在 gtk_init 之前设。 */
	setenv("GTK_THEME", "Adwaita:dark", 0);
	gtk_init(&argc, &argv);
	install_css();

	if (menu_mode) {
		run_menu_mode();
		gtk_main();
		return 0;
	}

	setup_taskbar();
	gtk_main();
	return 0;
}
