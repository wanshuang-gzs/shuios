/*
 * shuios 软件商店（shui-store）
 *
 * 一台给 AI 用的桌面，软件从哪来？答案不是 apt，而是 shuios 自己的
 * 包格式：每个包是一个自带依赖闭包的 squashfs，装进可写数据分区。
 * 商店界面做四件事：
 *
 *   1. 读 `shui-pkg list --tsv` 的清单（TSV，GUI 里不解析 JSON）；
 *   2. 左侧分类 + 顶部精选位，像 Microsoft Store 一样按用途找软件；
 *   3. 点卡片看详情（简介/版本/体积/厂商），点按钮 `shui-pkg install/remove`；
 *   4. 安装时给进度条 + 状态文字，跑完自动刷新。
 *
 * 图标优先读 `shui-pkg icons` 缓存下来的真图标（
 * /var/lib/shuios/pkg/icons/<图标名>，远程仓库也一样），取不到才回退
 * 图标主题，再取不到就自绘中性底板 + 首字母。
 *
 * 之所以用 GTK3 而不是自己撸 Wayland 客户端：GTK3 已经在镜像里
 * （weston/foot 的依赖链），而 Cairo 画图标让视觉完全可控。
 *
 * 色彩/字号/圆角一律取自 shuios-ui.h（唯一色源），见 docs/06-视觉规范.md。
 */

#include <gtk/gtk.h>
#include <math.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shuios-ui.h"   /* 设计令牌（唯一色源），见 docs/06-视觉规范.md */

#define ICON_SIZE 56
#define ICON_SIZE_FEATURE 64
#define ICON_SIZE_DETAIL 96
#define TILE_WIDTH 180
#define LOG_PATH "/tmp/shui-store.log"
#define ICON_DIR "/var/lib/shuios/pkg/icons"

typedef struct {
	char *name;
	char *version;
	char *size;
	char *human;
	char *summary;
	char *category;
	char *icon;
	char *title;
	char *developer;
	char *desc;
	gboolean installed;
	gboolean featured;
	GtkWidget *button;
} Pkg;

static GtkWidget *g_flow;
static GtkWidget *g_status;
static GtkWidget *g_search;
static GtkWidget *g_window;
static GtkWidget *g_feature;
static GtkWidget *g_progress;
static GPtrArray *g_pkgs;
static char *g_filter;
static int g_ready = 0;
static int g_busy = 0;
static guint g_pulse_id = 0;

/* ---------------------------------------------------------------- 工具 */

/* 仓库图标缓存（shui-pkg icons 下载好的文件）。 */
static GdkPixbuf *cached_icon(const char *name, int size)
{
	if (!name || !*name)
		return NULL;
	char path[512];
	snprintf(path, sizeof path, ICON_DIR "/%s", name);
	GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_scale(path, size, size, TRUE, NULL);
	if (pb)
		return pb;

	/* 索引里可能只写了名字（不带扩展名），两种扩展名都试一下 */
	char base[128];
	snprintf(base, sizeof base, "%s", name);
	char *dot = strrchr(base, '.');
	if (dot)
		*dot = 0;
	static const char *exts[] = { ".png", ".svg", ".xpm", ".ico" };
	for (unsigned i = 0; i < G_N_ELEMENTS(exts); i++) {
		snprintf(path, sizeof path, ICON_DIR "/%s%s", base, exts[i]);
		pb = gdk_pixbuf_new_from_file_at_scale(path, size, size, TRUE, NULL);
		if (pb)
			return pb;
	}
	return NULL;
}

/* 图标主题里的真图标；取不到返回 NULL（调用方退回自绘中性底板）。
 *
 * .desktop/PKGINFO 里的 Icon= 常常带扩展名（如 htop.svg），而图标主题是按**名字**
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

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r)
{
	cairo_new_sub_path(cr);
	cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
	cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
	cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
	cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
	cairo_close_path(cr);
}

/* ------------------------------------------------------------ 图标绘制 */

typedef struct {
	Pkg *p;
	int size;
} IconReq;

static void icon_req_free(gpointer data, GClosure *closure)
{
	(void)closure;
	g_free(data);
}

static gboolean on_draw_icon(GtkWidget *widget, cairo_t *cr, gpointer data)
{
	IconReq *req = data;
	Pkg *p = req->p;
	int size = req->size;
	(void)widget;

	/* 优先真图标（仓库缓存 → 图标主题） */
	GdkPixbuf *pb = cached_icon(p->icon, size);
	if (!pb)
		pb = theme_icon(p->icon, size);
	if (pb) {
		int pw = gdk_pixbuf_get_width(pb);
		int ph = gdk_pixbuf_get_height(pb);
		gdk_cairo_set_source_pixbuf(cr, pb, (size - pw) / 2.0,
					    (size - ph) / 2.0);
		cairo_paint(cr);
		g_object_unref(pb);
		return FALSE;
	}

	/* 取不到才自绘：中性 BG_CARD 圆角底板 + 1px LINE 描边 + FG_DIM 首字符。
	 * 曾经的「六色哈希上色 + 竖向渐变」已取消——
	 * 每个包一块饱和色是极简路线下最大的"花"来源（见 docs/06 硬规则 1）。 */
	double pad = size > 60 ? 3.0 : 2.0;
	rounded_rect(cr, pad, pad, size - 2 * pad, size - 2 * pad, UI_RADIUS_CARD);
	cairo_set_source_rgb(cr, UI_RGB_BG_CARD);
	cairo_fill(cr);
	rounded_rect(cr, pad, pad, size - 2 * pad, size - 2 * pad, UI_RADIUS_CARD);
	cairo_set_source_rgb(cr, UI_RGB_LINE);
	cairo_set_line_width(cr, 1);
	cairo_stroke(cr);

	/* 首字母（中文名取第一个字符也行） */
	char up[8] = { 0 };
	if (p->title && *p->title) {
		gchar *first = g_utf8_substring(p->title, 0, 1);
		g_strlcpy(up, first, sizeof up);
		g_free(first);
	} else {
		up[0] = (char)g_ascii_toupper(p->name[0]);
	}

	PangoLayout *layout = pango_cairo_create_layout(cr);
	PangoFontDescription *desc = pango_font_description_new();
	pango_font_description_set_family(desc, "WenQuanYi Zen Hei");
	pango_font_description_set_weight(desc, PANGO_WEIGHT_BOLD);
	pango_font_description_set_absolute_size(desc,
						 (size * 0.46) * PANGO_SCALE);
	pango_layout_set_font_description(layout, desc);
	pango_layout_set_text(layout, up, -1);

	int tw = 0, th = 0;
	pango_layout_get_pixel_size(layout, &tw, &th);
	cairo_set_source_rgb(cr, UI_RGB_FG_DIM);
	cairo_move_to(cr, (size - tw) / 2.0, (size - th) / 2.0 - 1);
	pango_cairo_show_layout(cr, layout);

	pango_font_description_free(desc);
	g_object_unref(layout);
	return FALSE;
}

static GtkWidget *make_icon(Pkg *p, int size)
{
	GtkWidget *area = gtk_drawing_area_new();
	gtk_widget_set_size_request(area, size, size);
	gtk_widget_set_halign(area, GTK_ALIGN_CENTER);
	gtk_widget_set_valign(area, GTK_ALIGN_START);
	IconReq *req = g_new0(IconReq, 1);
	req->p = p;
	req->size = size;
	g_signal_connect_data(area, "draw", G_CALLBACK(on_draw_icon), req,
			      icon_req_free, 0);
	return area;
}

/* ------------------------------------------------------------ 清单解析 */

static void pkg_free(gpointer ptr)
{
	Pkg *p = ptr;
	if (!p)
		return;
	g_free(p->name);
	g_free(p->version);
	g_free(p->size);
	g_free(p->human);
	g_free(p->summary);
	g_free(p->category);
	g_free(p->icon);
	g_free(p->title);
	g_free(p->developer);
	g_free(p->desc);
	g_free(p);
}

/* 按 \t 切一行；末尾不足的字段补空串 */
static void split_tabs(char *line, char **out, int n)
{
	int i = 0;
	char *start = line;
	for (char *q = line;; q++) {
		if (*q == '\t' || *q == '\0' || *q == '\n') {
			if (i < n) {
				char saved = *q;
				*q = '\0';
				out[i++] = g_strdup(start);
				*q = saved;
			}
			if (*q == '\0' || *q == '\n')
				break;
			start = q + 1;
		}
	}
	while (i < n)
		out[i++] = g_strdup("");
}

/* TSV 列序（与 shui-pkg list --tsv 一致）：
 * 0 包名 1 版本 2 字节 3 体积 4 摘要 5 已装 6 分类 7 图标
 * 8 展示名 9 开发者 10 精选 11 描述（后 4 列可缺省，老索引也能读） */
static GPtrArray *load_packages(const char *query)
{
	char *cmd;
	if (query && *query) {
		char *q = g_shell_quote(query);
		cmd = g_strdup_printf("/usr/bin/shui-pkg list --tsv %s 2>/dev/null", q);
		g_free(q);
	} else {
		cmd = g_strdup("/usr/bin/shui-pkg list --tsv 2>/dev/null");
	}

	GPtrArray *arr = g_ptr_array_new_with_free_func(pkg_free);
	FILE *fp = popen(cmd, "r");
	g_free(cmd);
	if (!fp)
		return arr;

	char buf[8192];
	while (fgets(buf, sizeof buf, fp)) {
		g_strchomp(buf);
		if (!*buf)
			continue;
		char *f[12] = { 0 };
		split_tabs(buf, f, 12);
		if (!f[0] || !*f[0]) {
			for (int i = 0; i < 12; i++)
				g_free(f[i]);
			continue;
		}
		Pkg *p = g_new0(Pkg, 1);
		p->name = f[0];
		p->version = f[1];
		p->size = f[2];
		p->human = f[3];
		p->summary = f[4];
		p->installed = f[5] && f[5][0] == '1';
		p->category = f[6];
		p->icon = f[7];
		p->title = f[8];
		p->developer = f[9];
		p->featured = f[10] && f[10][0] == '1';
		p->desc = f[11];
		g_ptr_array_add(arr, p);
	}
	pclose(fp);
	return arr;
}

/* ------------------------------------------------------------ 安装动作 */

static void refresh_grid(const char *query);
static void open_detail(Pkg *p);

static gboolean on_pulse(gpointer data)
{
	(void)data;
	if (!g_busy)
		return G_SOURCE_REMOVE;
	gtk_progress_bar_pulse(GTK_PROGRESS_BAR(g_progress));
	return G_SOURCE_CONTINUE;
}

static void set_busy(int busy, const char *text)
{
	g_busy = busy;
	if (busy) {
		gtk_widget_show(g_progress);
		gtk_label_set_text(GTK_LABEL(g_status), text);
		gtk_progress_bar_set_text(GTK_PROGRESS_BAR(g_progress), text);
		if (g_pulse_id == 0)
			g_pulse_id = g_timeout_add(120, on_pulse, NULL);
	} else {
		if (g_pulse_id) {
			g_source_remove(g_pulse_id);
			g_pulse_id = 0;
		}
		gtk_widget_hide(g_progress);
	}
}

static void on_child_exit(GPid pid, gint status, gpointer data)
{
	(void)data;
	g_spawn_close_pid(pid);

	gchar *log = NULL;
	gboolean shown = FALSE;
	if (g_file_get_contents(LOG_PATH, &log, NULL, NULL)) {
		g_strstrip(log);
		if (*log) {
			/* 只显示最后一行，够用了 */
			gchar **lines = g_strsplit(log, "\n", -1);
			int n = g_strv_length(lines);
			gtk_label_set_text(GTK_LABEL(g_status), n > 0 ? lines[n - 1] : log);
			g_strfreev(lines);
			shown = TRUE;
		}
		g_free(log);
	}
	if (!shown || status != 0)
		gtk_label_set_text(GTK_LABEL(g_status),
				   status == 0 ? "操作完成" : "操作失败，详情见 " LOG_PATH);

	set_busy(0, "");
	const char *q = gtk_entry_get_text(GTK_ENTRY(g_search));
	refresh_grid(q);
}

/* 跑一条 shui-pkg / 同步命令；完成后读日志最后一行并刷新列表。 */
static void run_cmd(const char *cmdline, GtkWidget *button,
		    const char *busy_label)
{
	if (g_busy) {
		gtk_label_set_text(GTK_LABEL(g_status), "还有操作在进行，请稍候…");
		return;
	}

	gchar *cmd = g_strdup_printf("%s >" LOG_PATH " 2>&1", cmdline);
	gchar *argv[] = { "/bin/sh", "-c", cmd, NULL };

	gint pid = 0;
	GError *err = NULL;
	gboolean ok = g_spawn_async(NULL, argv, NULL,
				    G_SPAWN_DO_NOT_REAP_CHILD |
					    G_SPAWN_SEARCH_PATH,
				    NULL, NULL, &pid, &err);
	g_free(cmd);

	if (!ok) {
		gchar *msg = g_strdup_printf("启动失败：%s",
					     err ? err->message : "未知错误");
		gtk_label_set_text(GTK_LABEL(g_status), msg);
		g_free(msg);
		if (err)
			g_error_free(err);
		return;
	}

	if (button) {
		gtk_button_set_label(GTK_BUTTON(button), busy_label);
		gtk_widget_set_sensitive(button, FALSE);
	}
	set_busy(1, busy_label);
	g_child_watch_add(pid, on_child_exit, NULL);
}

static void run_shui_pkg(const char *sub, const char *name, GtkWidget *button,
			 const char *busy_label)
{
	gchar *line;
	if (name && *name) {
		gchar *quoted = g_shell_quote(name);
		line = g_strdup_printf("/usr/bin/shui-pkg %s %s", sub, quoted);
		g_free(quoted);
	} else {
		line = g_strdup_printf("/usr/bin/shui-pkg %s", sub);
	}
	run_cmd(line, button, busy_label);
	g_free(line);
}

static void on_action_clicked(GtkButton *button, gpointer data)
{
	Pkg *p = data;
	if (p->installed)
		run_shui_pkg("remove", p->name, GTK_WIDGET(button), "卸载中…");
	else
		run_shui_pkg("install", p->name, GTK_WIDGET(button), "安装中…");
}

/* ------------------------------------------------------------ 组件构造 */

static const char *pkg_title(const Pkg *p)
{
	return (p->title && *p->title) ? p->title : p->name;
}

/* 卡片：图标 + 名字 + 两行摘要 + 版本/体积 + 安装按钮。
 * 点卡片任意空白处打开详情页。 */
static void on_tile_clicked(GtkWidget *w, GdkEventButton *ev, gpointer data)
{
	(void)w;
	if (ev->button != 1)
		return;
	open_detail((Pkg *)data);
}

static GtkWidget *make_tile(Pkg *p)
{
	/* 185 宽：1000 窗口减去 180 侧栏和两侧边距后正好 4 列。 */
	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_2);
	gtk_widget_set_size_request(box, TILE_WIDTH, -1);
	/* 顶到行首：flowbox 会把子项拉到整行高度，不设 START 的话卡片底下
	 * 会拖出一大片空底色（看着像没画完）。 */
	gtk_widget_set_valign(box, GTK_ALIGN_START);
	gtk_style_context_add_class(gtk_widget_get_style_context(box), "tile");

	/* 图标 + 已装徽标 */
	GtkWidget *top = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	gtk_box_pack_start(GTK_BOX(top), make_icon(p, ICON_SIZE), TRUE, FALSE, 0);
	if (p->installed) {
		GtkWidget *badge = gtk_label_new("已装");
		gtk_widget_set_valign(badge, GTK_ALIGN_START);
		gtk_style_context_add_class(gtk_widget_get_style_context(badge),
					    "badge");
		gtk_box_pack_start(GTK_BOX(top), badge, FALSE, FALSE, 0);
	}
	gtk_box_pack_start(GTK_BOX(box), top, FALSE, FALSE, 0);

	/* 名字 */
	gchar *name_markup = g_markup_printf_escaped("<b>%s</b>", pkg_title(p));
	GtkWidget *name = gtk_label_new(NULL);
	gtk_label_set_markup(GTK_LABEL(name), name_markup);
	gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
	gtk_widget_set_tooltip_text(name, p->summary);
	gtk_widget_set_halign(name, GTK_ALIGN_CENTER);
	gtk_style_context_add_class(gtk_widget_get_style_context(name), "pkgname");
	gtk_box_pack_start(GTK_BOX(box), name, FALSE, FALSE, 0);
	g_free(name_markup);

	/* 摘要：最多两行，不参与纵向拉伸（原来的 vexpand 是中间大空白的根因） */
	GtkWidget *summary = gtk_label_new(p->summary);
	gtk_label_set_line_wrap(GTK_LABEL(summary), TRUE);
	gtk_label_set_lines(GTK_LABEL(summary), 2);
	gtk_label_set_ellipsize(GTK_LABEL(summary), PANGO_ELLIPSIZE_END);
	gtk_label_set_max_width_chars(GTK_LABEL(summary), 20);
	gtk_label_set_justify(GTK_LABEL(summary), GTK_JUSTIFY_CENTER);
	gtk_widget_set_halign(summary, GTK_ALIGN_CENTER);
	gtk_style_context_add_class(gtk_widget_get_style_context(summary), "summary");
	gtk_box_pack_start(GTK_BOX(box), summary, FALSE, FALSE, 0);

	/* 体积 + 版本 */
	gchar *meta = g_strdup_printf("%s · %s", p->version, p->human);
	GtkWidget *metaline = gtk_label_new(meta);
	gtk_widget_set_halign(metaline, GTK_ALIGN_CENTER);
	gtk_style_context_add_class(gtk_widget_get_style_context(metaline), "meta");
	gtk_box_pack_start(GTK_BOX(box), metaline, FALSE, FALSE, 0);
	g_free(meta);

	/* 按钮（放在末尾，卡片高度一致） */
	GtkWidget *btn = gtk_button_new_with_label(p->installed ? "卸载" : "安装");
	gtk_style_context_add_class(gtk_widget_get_style_context(btn),
				    p->installed ? "remove" : "install");
	g_signal_connect(btn, "clicked", G_CALLBACK(on_action_clicked), p);
	p->button = btn;
	gtk_box_pack_start(GTK_BOX(box), btn, FALSE, FALSE, 0);

	/* 整卡可点：事件盒包一层（按钮会先吃掉自己的点击） */
	GtkWidget *evbox = gtk_event_box_new();
	gtk_event_box_set_visible_window(GTK_EVENT_BOX(evbox), FALSE);
	g_signal_connect(evbox, "button-press-event",
			 G_CALLBACK(on_tile_clicked), p);
	gtk_container_add(GTK_CONTAINER(evbox), box);
	return evbox;
}

/* ------------------------------------------------------------ 详情页 */

static GtkWidget *meta_line(const char *text, const char *cls)
{
	GtkWidget *label = gtk_label_new(text);
	gtk_widget_set_halign(label, GTK_ALIGN_START);
	gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
	gtk_label_set_max_width_chars(GTK_LABEL(label), 46);
	gtk_style_context_add_class(gtk_widget_get_style_context(label), cls);
	return label;
}

static void on_detail_action(GtkButton *button, gpointer data)
{
	Pkg *p = data;
	/* 详情页是模态的：动作一发起就关掉，避免安装完成后
	 * refresh_grid() 释放 Pkg 而对话框还引用它（use-after-free）。 */
	GtkWidget *dlg = gtk_widget_get_toplevel(GTK_WIDGET(button));
	if (p->installed)
		run_shui_pkg("remove", p->name, GTK_WIDGET(button), "卸载中…");
	else
		run_shui_pkg("install", p->name, GTK_WIDGET(button), "安装中…");
	if (GTK_IS_WIDGET(dlg))
		gtk_widget_destroy(dlg);
}

static void open_detail(Pkg *p)
{
	gchar *title = g_strdup_printf("%s - 软件详情", pkg_title(p));
	GtkWidget *dlg = gtk_dialog_new_with_buttons(
		title, GTK_WINDOW(g_window),
		GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
		"关闭", GTK_RESPONSE_CLOSE, NULL);
	g_free(title);
	gtk_window_set_default_size(GTK_WINDOW(dlg), 540, 420);
	gtk_window_set_resizable(GTK_WINDOW(dlg), FALSE);

	GtkWidget *area = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
	gtk_container_set_border_width(GTK_CONTAINER(area), UI_SP_4);

	GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_4);
	gtk_container_add(GTK_CONTAINER(area), row);
	gtk_box_pack_start(GTK_BOX(row), make_icon(p, ICON_SIZE_DETAIL), FALSE,
			   FALSE, 0);

	GtkWidget *right = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_2);
	gtk_box_pack_start(GTK_BOX(row), right, TRUE, TRUE, 0);

	gchar *name_markup = g_markup_printf_escaped(
		"<span size='xx-large' weight='bold'>%s</span>", pkg_title(p));
	GtkWidget *name = gtk_label_new(NULL);
	gtk_label_set_markup(GTK_LABEL(name), name_markup);
	gtk_widget_set_halign(name, GTK_ALIGN_START);
	gtk_box_pack_start(GTK_BOX(right), name, FALSE, FALSE, 0);
	g_free(name_markup);

	if (p->developer && *p->developer) {
		GtkWidget *dev = meta_line(p->developer, "detail-dev");
		gtk_box_pack_start(GTK_BOX(right), dev, FALSE, FALSE, 0);
	}

	gchar *meta = g_strdup_printf("%s · %s · %s", p->version, p->human,
				      p->category && *p->category ? p->category : "未分类");
	GtkWidget *metaline = meta_line(meta, "detail-meta");
	gtk_box_pack_start(GTK_BOX(right), metaline, FALSE, FALSE, 0);
	g_free(meta);

	/* 描述放进滚动区：有的包描述很长，不能把窗口撑爆 */
	const char *desc = (p->desc && *p->desc) ? p->desc : p->summary;
	GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
				       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	gtk_widget_set_size_request(scroll, -1, 140);
	gtk_widget_set_margin_top(scroll, UI_SP_2);
	GtkWidget *desclabel = meta_line(desc, "detail-desc");
	gtk_label_set_justify(GTK_LABEL(desclabel), GTK_JUSTIFY_LEFT);
	gtk_widget_set_valign(desclabel, GTK_ALIGN_START);
	/* 给死宽度，配合 line-wrap 才会按对话框宽度折行；
	 * 只设 max_width_chars 的话自然宽度仍是整段文字，会被 ScrollWindow 裁掉。 */
	gtk_widget_set_size_request(desclabel, 360, -1);
	gtk_container_add(GTK_CONTAINER(scroll), desclabel);
	gtk_box_pack_start(GTK_BOX(right), scroll, TRUE, TRUE, 0);

	GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	gtk_widget_set_halign(actions, GTK_ALIGN_START);
	GtkWidget *btn = gtk_button_new_with_label(p->installed ? "卸载" : "安装");
	gtk_style_context_add_class(gtk_widget_get_style_context(btn),
				    p->installed ? "remove" : "install");
	g_signal_connect(btn, "clicked", G_CALLBACK(on_detail_action), p);
	gtk_box_pack_start(GTK_BOX(actions), btn, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(right), actions, FALSE, FALSE, 0);

	gtk_widget_show_all(dlg);
	/* 模态：主窗口在此期间刷新不了，p 不会在对话框还开着时被释放 */
	gtk_dialog_run(GTK_DIALOG(dlg));
	gtk_widget_destroy(dlg);
}

/* ------------------------------------------------------------ 精选位 */

static void clear_box(GtkWidget *box)
{
	GList *kids = gtk_container_get_children(GTK_CONTAINER(box));
	for (GList *l = kids; l; l = l->next)
		gtk_widget_destroy(GTK_WIDGET(l->data));
	g_list_free(kids);
}

static void rebuild_feature(void)
{
	clear_box(g_feature);

	const char *q = gtk_entry_get_text(GTK_ENTRY(g_search));
	if (q && *q)
		return;
	if (g_filter && strcmp(g_filter, "精选") != 0 &&
	    strcmp(g_filter, "全部") != 0)
		return;

	Pkg *best = NULL;
	for (guint i = 0; i < g_pkgs->len; i++) {
		Pkg *p = g_ptr_array_index(g_pkgs, i);
		if (p->featured) {
			best = p;
			break;
		}
	}
	if (!best)
		return;

	GtkWidget *card = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_4);
	gtk_style_context_add_class(gtk_widget_get_style_context(card), "feature");
	/* 显式给高度：精选位里的文字是纵向自适应的，GTK 只按图标高度算请求，
	 * 结果卡片会溢出自己的分配区、压到下面网格的第一行上（踩过）。 */
	gtk_widget_set_size_request(card, -1, 104);
	gtk_widget_set_margin_start(card, UI_SP_4);
	gtk_widget_set_margin_end(card, UI_SP_4);
	gtk_widget_set_margin_top(card, UI_SP_4);
	gtk_widget_set_margin_bottom(card, UI_SP_2);

	gchar *eyebrow = g_strdup_printf("精选 · %s",
					 best->category && *best->category
						 ? best->category : "推荐");
	GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_1);
	GtkWidget *tag = gtk_label_new(eyebrow);
	gtk_widget_set_halign(tag, GTK_ALIGN_START);
	gtk_style_context_add_class(gtk_widget_get_style_context(tag), "feature-tag");
	gtk_box_pack_start(GTK_BOX(vbox), tag, FALSE, FALSE, 0);
	g_free(eyebrow);

	GtkWidget *title = gtk_label_new(pkg_title(best));
	gtk_widget_set_halign(title, GTK_ALIGN_START);
	gtk_style_context_add_class(gtk_widget_get_style_context(title),
				    "feature-title");
	gtk_box_pack_start(GTK_BOX(vbox), title, FALSE, FALSE, 0);

	GtkWidget *sub = gtk_label_new(best->summary);
	gtk_widget_set_halign(sub, GTK_ALIGN_START);
	gtk_label_set_ellipsize(GTK_LABEL(sub), PANGO_ELLIPSIZE_END);
	gtk_label_set_max_width_chars(GTK_LABEL(sub), 48);
	gtk_style_context_add_class(gtk_widget_get_style_context(sub), "feature-sub");
	gtk_box_pack_start(GTK_BOX(vbox), sub, FALSE, FALSE, 0);

	gchar *meta = g_strdup_printf("%s%s%s · %s · %s",
				      best->developer && *best->developer
					      ? best->developer : "",
				      best->developer && *best->developer ? " · " : "",
				      best->version, best->human,
				      best->installed ? "已安装" : "未安装");
	GtkWidget *metaline = gtk_label_new(meta);
	gtk_widget_set_halign(metaline, GTK_ALIGN_START);
	gtk_style_context_add_class(gtk_widget_get_style_context(metaline),
				    "feature-meta");
	gtk_box_pack_start(GTK_BOX(vbox), metaline, FALSE, FALSE, 0);
	g_free(meta);

	GtkWidget *feature_icon = make_icon(best, ICON_SIZE_FEATURE);
	gtk_widget_set_valign(feature_icon, GTK_ALIGN_CENTER);
	gtk_box_pack_start(GTK_BOX(card), feature_icon, FALSE, FALSE, 0);
	gtk_widget_set_valign(vbox, GTK_ALIGN_CENTER);
	gtk_box_pack_start(GTK_BOX(card), vbox, TRUE, TRUE, 0);

	GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_2);
	gtk_widget_set_valign(actions, GTK_ALIGN_CENTER);
	GtkWidget *install = gtk_button_new_with_label(best->installed ? "卸载"
									 : "安装");
	gtk_style_context_add_class(gtk_widget_get_style_context(install),
				    best->installed ? "remove" : "install");
	g_signal_connect(install, "clicked", G_CALLBACK(on_action_clicked), best);
	gtk_box_pack_start(GTK_BOX(actions), install, FALSE, FALSE, 0);

	GtkWidget *detail = gtk_button_new_with_label("详情");
	g_signal_connect_swapped(detail, "clicked", G_CALLBACK(open_detail), best);
	gtk_box_pack_start(GTK_BOX(actions), detail, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(card), actions, FALSE, FALSE, 0);

	gtk_container_add(GTK_CONTAINER(g_feature), card);
	gtk_widget_show_all(g_feature);
}

/* ------------------------------------------------------------ 分类过滤 */

static gboolean pkg_in_filter(const Pkg *p)
{
	if (!g_filter || !*g_filter || strcmp(g_filter, "全部") == 0)
		return TRUE;
	if (strcmp(g_filter, "精选") == 0)
		return p->featured;
	if (strcmp(g_filter, "已安装") == 0)
		return p->installed;

	gchar *copy = g_strdup(p->category ? p->category : "");
	gboolean hit = FALSE;
	for (char *save = NULL, *tok = strtok_r(copy, ",", &save); tok;
	     tok = strtok_r(NULL, ",", &save)) {
		g_strstrip(tok);
		if (strcmp(tok, g_filter) == 0) {
			hit = TRUE;
			break;
		}
	}
	g_free(copy);
	return hit;
}

static void refresh_grid(const char *query)
{
	clear_box(g_flow);
	if (g_pkgs) {
		g_ptr_array_free(g_pkgs, TRUE);
		g_pkgs = NULL;
	}
	g_pkgs = load_packages(query);

	guint shown = 0, installed = 0;
	for (guint i = 0; i < g_pkgs->len; i++) {
		Pkg *p = g_ptr_array_index(g_pkgs, i);
		if (p->installed)
			installed++;
		if (!pkg_in_filter(p))
			continue;
		gtk_flow_box_insert(GTK_FLOW_BOX(g_flow), make_tile(p), -1);
		shown++;
	}
	gtk_widget_show_all(g_flow);
	rebuild_feature();

	if (g_pkgs->len == 0) {
		GtkWidget *empty = gtk_label_new(
			"仓库里还没有软件包。\n"
			"先运行 tools/make-pkgrepo.sh，或把 /etc/shuios/pkgrepo.conf\n"
			"指向内网仓库后点「刷新」。");
		gtk_label_set_justify(GTK_LABEL(empty), GTK_JUSTIFY_CENTER);
		gtk_widget_set_margin_top(empty, 60);
		gtk_style_context_add_class(gtk_widget_get_style_context(empty),
					    "summary");
		gtk_container_add(GTK_CONTAINER(g_flow), empty);
		gtk_widget_show_all(g_flow);
		gtk_label_set_text(GTK_LABEL(g_status), "0 个软件包");
		return;
	}

	if (shown == 0) {
		GtkWidget *empty = gtk_label_new("这个分类下还没有软件。");
		gtk_widget_set_margin_top(empty, 60);
		gtk_style_context_add_class(gtk_widget_get_style_context(empty),
					    "summary");
		gtk_container_add(GTK_CONTAINER(g_flow), empty);
		gtk_widget_show_all(g_flow);
	}

	gchar *msg = g_strdup_printf("%u 个软件 · 已安装 %u 个%s%s", shown,
				     installed,
				     g_filter ? " · " : "",
				     g_filter ? g_filter : "");
	gtk_label_set_text(GTK_LABEL(g_status), msg);
	g_free(msg);
}

static void on_search_changed(GtkSearchEntry *entry, gpointer data)
{
	(void)data;
	refresh_grid(gtk_entry_get_text(GTK_ENTRY(entry)));
}

static void on_refresh_clicked(GtkButton *b, gpointer data)
{
	(void)b;
	(void)data;
	/* 同步 = 重新拉 index.json + 补图标；本地仓库时等价于重读目录 */
	run_cmd("/usr/bin/shui-pkg update && /usr/bin/shui-pkg icons",
		NULL, "正在同步软件仓库…");
}

static void on_category_selected(GtkListBox *list, GtkListBoxRow *row,
				 gpointer data)
{
	(void)list;
	(void)data;
	if (!row)
		return;
	/* make_sidebar() 里为了默认选中「全部」会触发一次 row-selected，
	 * 那时 g_flow/g_feature 还没建出来（refresh 会拿到 NULL）。
	 * 用 g_ready 挡掉初始化阶段的那一次。 */
	if (!g_ready)
		return;
	const char *cat = g_object_get_data(G_OBJECT(row), "cat");
	if (!cat)
		return;
	g_free(g_filter);
	g_filter = g_strdup(cat);
	refresh_grid(gtk_entry_get_text(GTK_ENTRY(g_search)));
}

static GtkWidget *make_sidebar(void)
{
	static const char *cats[] = { "精选", "全部", "办公", "社交通讯",
				      "开发", "影音", "系统", "工具", "网络",
				      "已安装" };
	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_widget_set_size_request(box, 180, -1);
	gtk_style_context_add_class(gtk_widget_get_style_context(box), "sidebar");

	GtkWidget *head = gtk_label_new("分类");
	gtk_widget_set_halign(head, GTK_ALIGN_START);
	gtk_style_context_add_class(gtk_widget_get_style_context(head),
				    "sidebar-title");
	gtk_box_pack_start(GTK_BOX(box), head, FALSE, FALSE, 0);

	GtkWidget *list = gtk_list_box_new();
	gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_SINGLE);
	g_signal_connect(list, "row-selected", G_CALLBACK(on_category_selected),
			 NULL);
	for (unsigned i = 0; i < G_N_ELEMENTS(cats); i++) {
		GtkWidget *row = gtk_list_box_row_new();
		GtkWidget *label = gtk_label_new(cats[i]);
		gtk_widget_set_halign(label, GTK_ALIGN_START);
		gtk_widget_set_margin_start(label, UI_SP_3);
		gtk_container_add(GTK_CONTAINER(row), label);
		g_object_set_data(G_OBJECT(row), "cat", (gpointer)cats[i]);
		gtk_list_box_insert(GTK_LIST_BOX(list), row, -1);
		if (strcmp(cats[i], "全部") == 0)
			gtk_list_box_select_row(GTK_LIST_BOX(list), GTK_LIST_BOX_ROW(row));
	}
	gtk_box_pack_start(GTK_BOX(box), list, TRUE, TRUE, 0);
	return box;
}

/* ------------------------------------------------------------ 样式 */

static void install_css(void)
{
	/* 所有色值/字号/圆角/间距都来自 shuios-ui.h，不在本函数里再写一遍 hex */
	const char *css =
		/* 窗口底色用 BG_PANEL 而不是 BG_WINDOW：壁纸也是 #0A0C0F，窗口和壁纸
		 * 同色时四周完全看不出边界（截图上像一堆卡片直接飘在壁纸上）。
		 * 层级：壁纸 BG_WINDOW < 窗口 BG_PANEL < 卡片 BG_CARD。 */
		"window { background-image: none; background-color: " UI_HEX_BG_PANEL ";"
		"  color: " UI_HEX_FG "; }\n"
		/* background-image 必须显式清掉：Adwaita 用 background-image 渐变画标题栏，
		 * 它画在 background-color 之上，只写 background-color 会被盖住
		 * （症状：标题栏还是浅色，白色标题文字在浅灰底上完全看不清）。 */
		"headerbar { background-image: none; background-color: " UI_HEX_BG_PANEL ";"
		"  color: " UI_HEX_FG "; border-bottom: 1px solid " UI_HEX_LINE ";"
		"  padding: " UI_STR(UI_SP_1) "px; box-shadow: none; }\n"
		"headerbar .title { font-weight: bold; font-size: " UI_STR(UI_FS_TITLE) "px; }\n"
		"headerbar .subtitle { color: " UI_HEX_FG_WEAK "; font-size: "
		UI_STR(UI_FS_META) "px; }\n"
		/* 标题栏里的窗口控制按钮：不要通用按钮那身底板，只留图标 */
		"headerbar button { background-image: none; background-color: transparent;"
		"  border: none; color: " UI_HEX_FG_DIM "; padding: 0 "
		UI_STR(UI_SP_2) "px; }\n"
		"headerbar button:hover { background-color: " UI_HEX_BG_HOVER ";"
		"  color: " UI_HEX_FG "; }\n"
		"entry { background-color: " UI_HEX_BG_CARD "; color: " UI_HEX_FG ";"
		"  border-radius: " UI_STR(UI_RADIUS) "px; border: 1px solid " UI_HEX_LINE ";"
		"  padding: " UI_STR(UI_SP_1) "px " UI_STR(UI_SP_2) "px; }\n"
		"entry:focus { border-color: " UI_HEX_ACCENT "; }\n"
		/* 左侧分类栏：比窗口再暗一档，用 1px 竖线跟内容分开 */
		".sidebar { background-color: " UI_HEX_BG_WINDOW ";"
		"  border-right: 1px solid " UI_HEX_LINE "; padding: " UI_STR(UI_SP_2) "px; }\n"
		".sidebar list { background-color: transparent; }\n"
		".sidebar-title { color: " UI_HEX_FG_WEAK "; font-size: "
		UI_STR(UI_FS_META) "px; padding: " UI_STR(UI_SP_2) "px "
		UI_STR(UI_SP_2) "px " UI_STR(UI_SP_1) "px; }\n"
		".sidebar row { background-image: none; border-radius: "
		UI_STR(UI_RADIUS_SM) "px;"
		"  padding: " UI_STR(UI_SP_2) "px " UI_STR(UI_SP_2) "px; }\n"
		".sidebar row:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		".sidebar row:selected { background-color: " UI_HEX_BG_HOVER "; }\n"
		".sidebar row label { color: " UI_HEX_FG_DIM "; font-size: "
		UI_STR(UI_FS_BODY) "px; }\n"
		".sidebar row:selected label { color: " UI_HEX_FG "; font-weight: bold; }\n"
		"flowbox { background-color: transparent; }\n"
		".tile { background-color: " UI_HEX_BG_CARD "; border-radius: "
		UI_STR(UI_RADIUS_CARD) "px; padding: " UI_STR(UI_SP_3) "px;"
		"  border: 1px solid " UI_HEX_LINE "; }\n"
		".tile:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		".pkgname { color: " UI_HEX_FG "; font-size: " UI_STR(UI_FS_BODY) "px;"
		"  font-weight: bold; }\n"
		".summary { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		".meta { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		/* 精选横幅：比卡片亮一档，主色只出现在「安装」按钮上 */
		".feature { background-color: " UI_HEX_BG_CARD "; border-radius: "
		UI_STR(UI_RADIUS_CARD) "px; border: 1px solid " UI_HEX_LINE ";"
		"  padding: " UI_STR(UI_SP_3) "px; }\n"
		".feature-tag { color: " UI_HEX_ACCENT "; font-size: " UI_STR(UI_FS_META) "px;"
		"  font-weight: bold; }\n"
		".feature-title { color: " UI_HEX_FG "; font-size: 20px; font-weight: bold; }\n"
		".feature-sub { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_BODY) "px; }\n"
		".feature-meta { color: " UI_HEX_FG_WEAK "; font-size: "
		UI_STR(UI_FS_META) "px; }\n"
		/* 详情页 */
		".detail-dev { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_BODY) "px; }\n"
		".detail-meta { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		".detail-desc { color: " UI_HEX_FG_DIM "; font-size: " UI_STR(UI_FS_BODY) "px; }\n"
		/* 徽标：中性底 + 次文字（主色只留给主操作按钮） */
		".badge { background-color: " UI_HEX_BG_HOVER "; color: " UI_HEX_FG_DIM ";"
		"  border-radius: " UI_STR(UI_RADIUS_SM) "px; padding: 1px "
		UI_STR(UI_SP_1) "px; font-size: " UI_STR(UI_FS_META) "px;"
		"  font-weight: bold; }\n"
		"button { background-image: none; background-color: " UI_HEX_BG_CARD ";"
		"  color: " UI_HEX_FG "; border: 1px solid " UI_HEX_LINE ";"
		"  border-radius: " UI_STR(UI_RADIUS) "px; padding: " UI_STR(UI_SP_1) "px "
		UI_STR(UI_SP_4) "px; box-shadow: none; text-shadow: none; }\n"
		/* 主操作：全窗口唯一的实心 accent 按钮 */
		"button.install { background-color: " UI_HEX_ACCENT "; color: " UI_HEX_ACCENT_ON ";"
		"  border: none; font-weight: bold; }\n"
		"button.install:hover { background-color: " UI_HEX_ACCENT_HI "; }\n"
		/* 次要操作：1px 描边中性按钮，把视觉重量让给「安装」 */
		"button.remove { background-color: transparent; color: " UI_HEX_FG_DIM ";"
		"  border: 1px solid " UI_HEX_LINE "; font-weight: normal; }\n"
		"button.remove:hover { background-color: " UI_HEX_BG_HOVER "; color: "
		UI_HEX_FG "; }\n"
		"label.status { color: " UI_HEX_FG_WEAK "; font-size: " UI_STR(UI_FS_META) "px; }\n"
		"progressbar trough { background-color: " UI_HEX_BG_HOVER ";"
		"  border-radius: " UI_STR(UI_RADIUS_SM) "px; min-height: 4px; }\n"
		"progressbar progress { background-color: " UI_HEX_ACCENT ";"
		"  border-radius: " UI_STR(UI_RADIUS_SM) "px; min-height: 4px; }\n";

	GtkCssProvider *prov = gtk_css_provider_new();
	gtk_css_provider_load_from_data(prov, css, -1, NULL);
	gtk_style_context_add_provider_for_screen(
		gdk_screen_get_default(), GTK_STYLE_PROVIDER(prov),
		GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(prov);
}

/* ------------------------------------------------------------ 启动补图 */

static void on_icons_done(GPid pid, gint status, gpointer data)
{
	(void)status;
	(void)data;
	g_spawn_close_pid(pid);
	refresh_grid(gtk_entry_get_text(GTK_ENTRY(g_search)));
}

/* 启动时静默同步仓库：先显示缓存里的列表（秒开），后台拉新索引 +
 * 补图标，完成后再刷新一次。网络不通时 update 失败，界面上仍是旧列表。 */
static void prefetch_icons(void)
{
	gchar *argv[] = {
		"/bin/sh", "-c",
		"/usr/bin/shui-pkg update >/tmp/shui-store-icons.log 2>&1;"
		" /usr/bin/shui-pkg icons >>/tmp/shui-store-icons.log 2>&1", NULL
	};
	gint pid = 0;
	GError *err = NULL;
	if (g_spawn_async(NULL, argv, NULL, G_SPAWN_DO_NOT_REAP_CHILD |
						 G_SPAWN_SEARCH_PATH,
			  NULL, NULL, &pid, &err))
		g_child_watch_add(pid, on_icons_done, NULL);
	if (err)
		g_error_free(err);
}

int main(int argc, char **argv)
{
	/* 显式 CSS 只管我们要的那几个面（窗口/卡片/按钮/输入框），
	 * 其余控件（滚动条、选中高亮、提示框）交给 Adwaita 深色主题，
	 * 否则浅色主题会在近黑底上漏出白条。必须在 gtk_init 之前设。 */
	setenv("GTK_THEME", "Adwaita:dark", 0);
	gtk_init(&argc, &argv);
	install_css();

	g_filter = g_strdup("全部");

	g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_default_size(GTK_WINDOW(g_window), 1000, 660);
	/* 锁住设计尺寸：只给 default_size 的话，GTK 会按内容自然尺寸收缩
	 * （2 个包时窗口只剩 700 宽），和 sway 里 for_window 的尺寸对不上。 */
	gtk_widget_set_size_request(g_window, 1000, 660);
	gtk_window_set_title(GTK_WINDOW(g_window), "软件商店");
	g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	GtkWidget *header = gtk_header_bar_new();
	/* 日常界面用文字标题而不是品牌字「氵」——「氵」只留给开机/关机画面（docs/06 第 5 节） */
	gtk_header_bar_set_title(GTK_HEADER_BAR(header), "软件商店");
	gtk_header_bar_set_subtitle(GTK_HEADER_BAR(header), "发现并安装常用软件");
	gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
	/* 仿 Windows：右侧「最小化 / 最大化 / 关闭」三个按钮 */
	gtk_header_bar_set_decoration_layout(GTK_HEADER_BAR(header),
					     "menu:minimize,maximize,close");
	gtk_window_set_titlebar(GTK_WINDOW(g_window), header);

	/* 搜索框 + 刷新按钮进标题栏 */
	g_search = gtk_search_entry_new();
	gtk_entry_set_placeholder_text(GTK_ENTRY(g_search), "搜索软件…");
	gtk_widget_set_size_request(g_search, 220, -1);
	g_signal_connect(g_search, "search-changed",
			 G_CALLBACK(on_search_changed), NULL);
	gtk_header_bar_pack_start(GTK_HEADER_BAR(header), g_search);

	GtkWidget *refresh = gtk_button_new_with_label("刷新");
	g_signal_connect(refresh, "clicked", G_CALLBACK(on_refresh_clicked), NULL);
	gtk_header_bar_pack_end(GTK_HEADER_BAR(header), refresh);

	/* 主体：左侧分类 + 右侧「精选 + 网格 + 状态栏」 */
	GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	gtk_container_add(GTK_CONTAINER(g_window), outer);
	gtk_box_pack_start(GTK_BOX(outer), make_sidebar(), FALSE, FALSE, 0);

	GtkWidget *right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_box_pack_start(GTK_BOX(outer), right, TRUE, TRUE, 0);

	g_feature = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_box_pack_start(GTK_BOX(right), g_feature, FALSE, FALSE, 0);

	GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
				       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	gtk_box_pack_start(GTK_BOX(right), scroll, TRUE, TRUE, 0);

	g_flow = gtk_flow_box_new();
	gtk_flow_box_set_homogeneous(GTK_FLOW_BOX(g_flow), TRUE);
	gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(g_flow), 4);
	gtk_flow_box_set_min_children_per_line(GTK_FLOW_BOX(g_flow), 3);
	gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(g_flow), UI_SP_3);
	gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(g_flow), UI_SP_3);
	gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(g_flow),
					GTK_SELECTION_NONE);
	gtk_widget_set_margin_start(g_flow, UI_SP_4);
	gtk_widget_set_margin_end(g_flow, UI_SP_4);
	gtk_widget_set_margin_top(g_flow, UI_SP_4);
	gtk_widget_set_margin_bottom(g_flow, UI_SP_4);
	gtk_container_add(GTK_CONTAINER(scroll), g_flow);

	GtkWidget *statusbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_3);
	gtk_widget_set_margin_start(statusbar, UI_SP_4);
	gtk_widget_set_margin_end(statusbar, UI_SP_4);
	gtk_widget_set_margin_bottom(statusbar, UI_SP_2);
	g_status = gtk_label_new("正在读取软件仓库…");
	gtk_style_context_add_class(gtk_widget_get_style_context(g_status), "status");
	gtk_widget_set_halign(g_status, GTK_ALIGN_START);
	gtk_box_pack_start(GTK_BOX(statusbar), g_status, TRUE, TRUE, 0);

	g_progress = gtk_progress_bar_new();
	gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(g_progress), FALSE);
	gtk_widget_set_valign(g_progress, GTK_ALIGN_CENTER);
	gtk_widget_set_size_request(g_progress, 180, -1);
	gtk_box_pack_start(GTK_BOX(statusbar), g_progress, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(right), statusbar, FALSE, FALSE, 0);

	g_ready = 1;
	refresh_grid("");
	gtk_widget_show_all(g_window);
	gtk_widget_hide(g_progress);
	prefetch_icons();
	gtk_main();
	return 0;
}
