/*
 * shui-browser — shuios 的图形浏览器（GTK3 + WebKit2GTK 4.1）
 *
 * 提供普通桌面浏览器的基本形态：地址栏、前进/后退/刷新、多标签页、
 * 下载到 /workspace/下载、错误页、本地起始页。
 *
 * 进程名固定为 shui-browser：GTK3 在 Wayland 下用进程名当 app_id，
 * shui-panel 的 Dock 靠它把运行中的窗口挂到「浏览器」图标上。
 */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <glib/gstdio.h>
#include <stdarg.h>
#include <string.h>

#define START_PAGE "/usr/share/shuios/browser-home.html"
/* 开发用：/var/lib/shuios/dev 在可写数据分区，改完 HTML 刷新即可生效 */
#define START_PAGE_DEV "/var/lib/shuios/dev/browser-home.html"
#define DOWNLOAD_DIR "/workspace/下载"

typedef struct Browser Browser;
typedef struct Tab Tab;
typedef struct DlRow DlRow;

struct Tab {
	Browser *b;
	WebKitWebView *view;
	GtkWidget *label;
	GtkWidget *tabbox;
	char *title;
	char *pending_url;
};

/* 下载面板里的一行：文件名 + 进度条 + 状态/保存位置 */
struct DlRow {
	GtkWidget *row;
	GtkWidget *prog;
	GtkWidget *info;
};

struct Browser {
	GtkWidget *win;
	GtkWidget *header;
	GtkWidget *notebook;
	GtkWidget *url;
	GtkWidget *progress;
	GtkWidget *status;
	GtkWidget *back;
	GtkWidget *forward;
	GtkWidget *reload;
	GtkWidget *dl_btn;
	GtkWidget *dl_pop;
	GtkWidget *dl_list;
	GtkWidget *dl_empty;
	guint status_timer;
	int dl_count;
	gboolean fullscreen;
};

static Browser *g_active;
static int g_nwin;
static char *g_start_uri;

/* ---------------------------------------------------------------- 工具 */

static const char *start_uri(void)
{
	if (g_start_uri)
		return g_start_uri;
	const char *page = g_file_test(START_PAGE_DEV, G_FILE_TEST_EXISTS)
				   ? START_PAGE_DEV
				   : START_PAGE;
	if (g_file_test(page, G_FILE_TEST_EXISTS))
		g_start_uri = g_filename_to_uri(page, NULL, NULL);
	return g_start_uri ? g_start_uri : "about:blank";
}

static gboolean is_start_uri(const char *uri)
{
	return uri && g_strcmp0(uri, start_uri()) == 0;
}

static gboolean clear_status_cb(gpointer data)
{
	Browser *b = data;
	b->status_timer = 0;
	gtk_label_set_text(GTK_LABEL(b->status), "");
	gtk_widget_hide(b->status);
	return G_SOURCE_REMOVE;
}

static void set_status(Browser *b, const char *fmt, ...)
{
	if (!b || !b->status)
		return;
	va_list ap;
	va_start(ap, fmt);
	char *msg = g_strdup_vprintf(fmt, ap);
	va_end(ap);
	gtk_label_set_text(GTK_LABEL(b->status), msg);
	gtk_widget_show(b->status);
	g_free(msg);
	if (b->status_timer)
		g_source_remove(b->status_timer);
	b->status_timer = g_timeout_add_seconds(15, clear_status_cb, b);
}

static gboolean on_key_press(GtkWidget *w, GdkEventKey *e, gpointer data);

static GtkWidget *icon_button(const char *icon, const char *tip, GCallback cb,
			      gpointer data)
{
	GtkWidget *btn = gtk_button_new_from_icon_name(icon, GTK_ICON_SIZE_BUTTON);
	gtk_button_set_relief(GTK_BUTTON(btn), GTK_RELIEF_NONE);
	gtk_widget_set_tooltip_text(btn, tip);
	gtk_widget_set_focus_on_click(btn, FALSE);
	g_signal_connect(btn, "clicked", cb, data);
	return btn;
}

/* ---------------------------------------------------------------- 标签页 */

static Tab *current_tab(Browser *b)
{
	if (!b || !b->notebook)
		return NULL;
	int idx = gtk_notebook_get_current_page(GTK_NOTEBOOK(b->notebook));
	if (idx < 0)
		return NULL;
	GtkWidget *page = gtk_notebook_get_nth_page(GTK_NOTEBOOK(b->notebook), idx);
	return page ? g_object_get_data(G_OBJECT(page), "shui-tab") : NULL;
}

static char *view_title(WebKitWebView *v)
{
	const char *t = webkit_web_view_get_title(v);
	if (t && *t)
		return g_strdup(t);
	if (webkit_web_view_is_loading(v))
		return g_strdup("加载中…");
	const char *u = webkit_web_view_get_uri(v);
	if (u && *u && !is_start_uri(u))
		return g_strdup(u);
	return g_strdup("新标签页");
}

static void sync_address(Browser *b)
{
	Tab *t = current_tab(b);
	if (!t || !b->url)
		return;
	if (gtk_widget_has_focus(b->url))
		return; /* 用户正在输入，别抢 */
	if (t->pending_url)
		return; /* 地址栏刚敲入的导航还没提交（下载会中断提交） */
	const char *u = webkit_web_view_get_uri(t->view);
	/* 导航被转成下载时 URI 为空，别把用户刚输入的网址清掉 */
	if (!u)
		return;
	if (is_start_uri(u))
		gtk_entry_set_text(GTK_ENTRY(b->url), "");
	else
		gtk_entry_set_text(GTK_ENTRY(b->url), u);
}

static void sync_window_title(Browser *b)
{
	Tab *t = current_tab(b);
	if (t && t->title && *t->title) {
		char *s = g_strdup_printf("%s — 浏览器", t->title);
		gtk_window_set_title(GTK_WINDOW(b->win), s);
		g_free(s);
	} else {
		gtk_window_set_title(GTK_WINDOW(b->win), "浏览器");
	}
}

static void update_nav(Browser *b)
{
	Tab *t = current_tab(b);
	gboolean has = t != NULL;
	if (!b->back)
		return;
	gtk_widget_set_sensitive(b->back,
				 has && webkit_web_view_can_go_back(t->view));
	gtk_widget_set_sensitive(b->forward,
				 has && webkit_web_view_can_go_forward(t->view));
	gboolean loading = has && webkit_web_view_is_loading(t->view);
	if (b->reload)
		gtk_button_set_image(GTK_BUTTON(b->reload),
				     gtk_image_new_from_icon_name(
					     loading ? "process-stop-symbolic"
						     : "view-refresh-symbolic",
					     GTK_ICON_SIZE_BUTTON));
	sync_address(b);
	sync_window_title(b);
}

static void tab_select(Browser *b, Tab *t)
{
	int idx = gtk_notebook_page_num(GTK_NOTEBOOK(b->notebook),
					GTK_WIDGET(t->view));
	if (idx >= 0)
		gtk_notebook_set_current_page(GTK_NOTEBOOK(b->notebook), idx);
}

static gboolean free_tab_idle(gpointer data)
{
	Tab *t = data;
	g_free(t->title);
	g_free(t->pending_url);
	g_free(t);
	return G_SOURCE_REMOVE;
}

static void on_view_destroy(GtkWidget *w, gpointer data)
{
	(void)data;
	Tab *t = g_object_get_data(G_OBJECT(w), "shui-tab");
	if (t) {
		g_object_set_data(G_OBJECT(w), "shui-tab", NULL);
		/* 销毁过程中还可能有信号，Tab 延迟释放 */
		g_idle_add(free_tab_idle, t);
	}
}

static void on_notify_title(GObject *obj, GParamSpec *ps, gpointer data)
{
	(void)obj;
	(void)ps;
	Tab *t = data;
	char *title = view_title(t->view);
	g_free(t->title);
	t->title = title;
	gtk_label_set_text(GTK_LABEL(t->label), title);
	gtk_widget_set_tooltip_text(t->tabbox, title);
	if (t == current_tab(t->b))
		sync_window_title(t->b);
}

static void on_notify_uri(GObject *obj, GParamSpec *ps, gpointer data)
{
	(void)obj;
	(void)ps;
	Tab *t = data;
	if (t == current_tab(t->b))
		sync_address(t->b);
}

static void on_load_changed(WebKitWebView *v, WebKitLoadEvent ev, gpointer data)
{
	Tab *t = data;
	(void)v;
	if (ev == WEBKIT_LOAD_STARTED)
		gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(t->b->progress), 0.0);
	else if (ev == WEBKIT_LOAD_COMMITTED) {
		g_clear_pointer(&t->pending_url, g_free);
		sync_address(t->b);
	} else if (ev == WEBKIT_LOAD_FINISHED) {
		gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(t->b->progress), 0.0);
		on_notify_title(G_OBJECT(t->view), NULL, t);
	}
	update_nav(t->b);
}

static void on_progress(GObject *obj, GParamSpec *ps, gpointer data)
{
	(void)obj;
	(void)ps;
	Tab *t = data;
	double p = webkit_web_view_get_estimated_load_progress(t->view);
	gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(t->b->progress), p);
}

static gboolean on_load_failed(WebKitWebView *v, WebKitLoadEvent ev,
			       const char *uri, GError *error, gpointer data)
{
	Tab *t = data;
	(void)ev;
	if (g_error_matches(error, WEBKIT_NETWORK_ERROR,
			    WEBKIT_NETWORK_ERROR_CANCELLED))
		return TRUE;
	/* 导航被判定为下载时 WebKit 会先以“策略变更中断加载”收尾，
	   它比 download-started 更早到达；此时绝不能加载错误页——
	   那会取消尚未开始的下载。MiniBrowser 同样直接忽略。 */
	if (g_error_matches(error, WEBKIT_POLICY_ERROR,
			    WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE))
		return TRUE;
	char *eu = g_markup_escape_text(uri ? uri : "", -1);
	char *ee = g_markup_escape_text(error ? error->message : "未知错误", -1);
	char *html = g_strdup_printf(
		"<!doctype html><html><head><meta charset='utf-8'>"
		"<title>打不开这个页面</title>"
		"<style>"
		"body{margin:0;font-family:'Noto Sans CJK SC','WenQuanYi Zen Hei',sans-serif;"
		"background:#eef1f7;color:#1d2330;display:flex;align-items:center;"
		"justify-content:center;min-height:90vh}"
		".card{max-width:620px;padding:40px 44px;background:#fff;border-radius:20px;"
		"box-shadow:0 12px 40px rgba(28,39,64,.14)}"
		"h1{margin:0 0 14px;font-size:26px}"
		".u{color:#3b5bdb;word-break:break-all;font-size:15px}"
		".e{color:#8a94a6;font-size:14px;margin-top:6px}"
		"p{margin:10px 0;line-height:1.6}"
		"kbd{background:#eef1f7;border:1px solid #d5dae6;border-radius:6px;"
		"padding:1px 7px;font-size:13px}"
		"</style></head><body><div class='card'>"
		"<h1>打不开这个页面</h1>"
		"<p class='u'>%s</p><p class='e'>%s</p>"
		"<p>检查网络连接，按 <kbd>Ctrl</kbd>+<kbd>R</kbd> 重试，"
		"或在地址栏换一个网址。</p>"
		"</div></body></html>",
		eu, ee);
	webkit_web_view_load_alternate_html(v, html, uri, NULL);
	g_free(html);
	g_free(eu);
	g_free(ee);
	(void)t;
	return TRUE;
}

static Tab *tab_new(Browser *b, const char *uri);

static WebKitWebView *on_create(WebKitWebView *v, WebKitNavigationAction *nav,
				gpointer data)
{
	(void)v;
	(void)nav;
	Tab *t = data;
	Tab *nt = tab_new(t->b, NULL);
	tab_select(t->b, nt);
	return nt->view;
}

static gboolean on_decide_policy(WebKitWebView *v, WebKitPolicyDecision *dec,
				 WebKitPolicyDecisionType type, gpointer data)
{
	Tab *t = data;
	(void)v;
	/* 主框架返回 WebKit 无法显示的类型（二进制、压缩包等）时转成下载，
	   否则 WebKit 只会中断加载并留下空白页 */
	if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
		WebKitResponsePolicyDecision *rd =
			WEBKIT_RESPONSE_POLICY_DECISION(dec);
		if (!webkit_response_policy_decision_is_mime_type_supported(rd) &&
		    webkit_response_policy_decision_is_main_frame_main_resource(rd)) {
			webkit_policy_decision_download(dec);
			return TRUE;
		}
		return FALSE;
	}
	if (type != WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION)
		return FALSE;
	WebKitNavigationAction *nav =
		webkit_navigation_policy_decision_get_navigation_action(
			WEBKIT_NAVIGATION_POLICY_DECISION(dec));
	if (!nav) {
		webkit_policy_decision_ignore(dec);
		return TRUE;
	}
	WebKitURIRequest *req = webkit_navigation_action_get_request(nav);
	const char *uri = req ? webkit_uri_request_get_uri(req) : NULL;
	if (!uri) {
		webkit_policy_decision_ignore(dec);
		return TRUE;
	}
	Tab *nt = tab_new(t->b, uri);
	tab_select(t->b, nt);
	webkit_policy_decision_ignore(dec);
	return TRUE;
}

static void on_tab_close(GtkButton *btn, gpointer data)
{
	(void)btn;
	Tab *t = data;
	Browser *b = t->b;
	GtkWidget *tabbox = t->tabbox;
	if (gtk_notebook_get_n_pages(GTK_NOTEBOOK(b->notebook)) <= 1) {
		gtk_widget_destroy(b->win);
		return;
	}
	int idx = gtk_notebook_page_num(GTK_NOTEBOOK(b->notebook),
					GTK_WIDGET(t->view));
	if (idx >= 0)
		gtk_notebook_remove_page(GTK_NOTEBOOK(b->notebook), idx);
	gtk_widget_destroy(GTK_WIDGET(t->view));
	gtk_widget_destroy(tabbox);
	update_nav(b);
}

static GtkWidget *make_tab_label(Browser *b, Tab *t)
{
	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
	GtkWidget *lab = gtk_label_new("新标签页");
	gtk_label_set_ellipsize(GTK_LABEL(lab), PANGO_ELLIPSIZE_END);
	gtk_label_set_max_width_chars(GTK_LABEL(lab), 18);
	/* 不给宽度时 notebook 会把标签压成 "…" */
	gtk_label_set_width_chars(GTK_LABEL(lab), 12);
	gtk_widget_set_valign(lab, GTK_ALIGN_CENTER);
	GtkWidget *close = gtk_button_new_from_icon_name("window-close-symbolic",
							 GTK_ICON_SIZE_MENU);
	gtk_button_set_relief(GTK_BUTTON(close), GTK_RELIEF_NONE);
	gtk_widget_set_focus_on_click(close, FALSE);
	gtk_widget_set_tooltip_text(close, "关闭标签页");
	gtk_style_context_add_class(gtk_widget_get_style_context(close),
				    "tab-close");
	g_signal_connect(close, "clicked", G_CALLBACK(on_tab_close), t);
	gtk_box_pack_start(GTK_BOX(box), lab, TRUE, TRUE, 0);
	gtk_box_pack_end(GTK_BOX(box), close, FALSE, FALSE, 0);
	gtk_widget_show_all(box);
	t->label = lab;
	t->tabbox = box;
	(void)b;
	return box;
}

static Tab *tab_new(Browser *b, const char *uri)
{
	WebKitSettings *settings = webkit_settings_new();
	webkit_settings_set_enable_javascript(settings, TRUE);
	webkit_settings_set_javascript_can_open_windows_automatically(settings, TRUE);
	webkit_settings_set_enable_webgl(settings, TRUE);
	webkit_settings_set_enable_mediasource(settings, TRUE);
	webkit_settings_set_enable_media_stream(settings, TRUE);
	webkit_settings_set_enable_webaudio(settings, TRUE);
	webkit_settings_set_enable_smooth_scrolling(settings, TRUE);
	/* 本地纯文本（.txt/.md）没有 <meta charset>，WebKit 默认按 Latin-1
	   解码，中文全成乱码。默认字符集必须钉成 UTF-8。 */
	webkit_settings_set_default_charset(settings, "UTF-8");
	webkit_settings_set_hardware_acceleration_policy(
		settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_ON_DEMAND);
	WebKitWebView *v =
		WEBKIT_WEB_VIEW(webkit_web_view_new_with_settings(settings));
	g_object_unref(settings);

	Tab *t = g_new0(Tab, 1);
	t->b = b;
	t->view = v;
	t->title = g_strdup("新标签页");
	g_object_set_data(G_OBJECT(v), "shui-tab", t);

	g_signal_connect(v, "destroy", G_CALLBACK(on_view_destroy), NULL);
	g_signal_connect(v, "notify::title", G_CALLBACK(on_notify_title), t);
	g_signal_connect(v, "notify::uri", G_CALLBACK(on_notify_uri), t);
	g_signal_connect(v, "notify::estimated-load-progress",
			 G_CALLBACK(on_progress), t);
	g_signal_connect(v, "load-changed", G_CALLBACK(on_load_changed), t);
	g_signal_connect(v, "load-failed", G_CALLBACK(on_load_failed), t);
	g_signal_connect(v, "create", G_CALLBACK(on_create), t);
	g_signal_connect(v, "decide-policy", G_CALLBACK(on_decide_policy), t);
	g_signal_connect(v, "key-press-event", G_CALLBACK(on_key_press), b);

	GtkWidget *tabbox = make_tab_label(b, t);
	gtk_notebook_append_page(GTK_NOTEBOOK(b->notebook), GTK_WIDGET(v), tabbox);
	gtk_notebook_set_tab_reorderable(GTK_NOTEBOOK(b->notebook), GTK_WIDGET(v),
					 TRUE);
	gtk_widget_show_all(GTK_WIDGET(v));
	gtk_notebook_set_current_page(
		GTK_NOTEBOOK(b->notebook),
		gtk_notebook_page_num(GTK_NOTEBOOK(b->notebook), GTK_WIDGET(v)));

	if (uri)
		webkit_web_view_load_uri(v, uri);
	else
		on_notify_title(G_OBJECT(v), NULL, t);

	update_nav(b);
	return t;
}

/* ---------------------------------------------------------------- 导航 */

static void load_text(Browser *b, const char *text)
{
	char *s = g_strstrip(g_strdup(text ? text : ""));
	if (!*s) {
		g_free(s);
		return;
	}
	char *uri;
	if (g_str_has_prefix(s, "http://") || g_str_has_prefix(s, "https://") ||
	    g_str_has_prefix(s, "file://") || g_str_has_prefix(s, "about:") ||
	    g_str_has_prefix(s, "view-source:"))
		uri = g_strdup(s);
	else if (strstr(s, "://"))
		uri = g_strdup(s);
	else if (g_str_has_prefix(s, "localhost") || g_str_has_prefix(s, "127.") ||
		 g_str_has_prefix(s, "[::1]"))
		uri = g_strdup_printf("http://%s", s);
	else if (!strchr(s, ' ') && strchr(s, '.'))
		uri = g_strdup_printf("https://%s", s);
	else {
		char *q = g_uri_escape_string(s, NULL, TRUE);
		uri = g_strdup_printf("https://www.bing.com/search?q=%s", q);
		g_free(q);
	}
	Tab *t = current_tab(b);
	if (!t)
		t = tab_new(b, NULL);
	webkit_web_view_load_uri(t->view, uri);
	/* 下载会中断提交，网址不会回填，所以这里自己写进地址栏，
	   并用 pending_url 防止后续空 URI 通知把它清掉 */
	g_free(t->pending_url);
	t->pending_url = g_strdup(uri);
	gtk_entry_set_text(GTK_ENTRY(b->url), uri);
	gtk_widget_grab_focus(GTK_WIDGET(t->view));
	g_free(uri);
	g_free(s);
}

static void on_url_activate(GtkEntry *e, gpointer data)
{
	Browser *b = data;
	load_text(b, gtk_entry_get_text(e));
}

static void on_back(GtkButton *btn, gpointer data)
{
	(void)btn;
	Tab *t = current_tab(data);
	if (t && webkit_web_view_can_go_back(t->view))
		webkit_web_view_go_back(t->view);
}

static void on_forward(GtkButton *btn, gpointer data)
{
	(void)btn;
	Tab *t = current_tab(data);
	if (t && webkit_web_view_can_go_forward(t->view))
		webkit_web_view_go_forward(t->view);
}

static void on_reload(GtkButton *btn, gpointer data)
{
	(void)btn;
	Tab *t = current_tab(data);
	if (!t)
		return;
	if (webkit_web_view_is_loading(t->view))
		webkit_web_view_stop_loading(t->view);
	else
		webkit_web_view_reload(t->view);
}

static void on_new_tab(GtkButton *btn, gpointer data)
{
	(void)btn;
	tab_new(data, start_uri());
}

static void on_menu_new_tab(GtkMenuItem *it, gpointer data)
{
	(void)it;
	tab_new(data, start_uri());
}

static void close_current(Browser *b)
{
	Tab *t = current_tab(b);
	if (!t)
		return;
	on_tab_close(NULL, t);
}

static void on_menu_close_tab(GtkMenuItem *it, gpointer data)
{
	(void)it;
	close_current(data);
}

static void on_menu_reload(GtkMenuItem *it, gpointer data)
{
	(void)it;
	on_reload(NULL, data);
}

static void toggle_fullscreen(Browser *b)
{
	if (!b->fullscreen) {
		gtk_widget_hide(b->header);
		gtk_window_fullscreen(GTK_WINDOW(b->win));
		b->fullscreen = TRUE;
	} else {
		gtk_widget_show(b->header);
		gtk_window_unfullscreen(GTK_WINDOW(b->win));
		b->fullscreen = FALSE;
	}
}

static void on_menu_fullscreen(GtkMenuItem *it, gpointer data)
{
	(void)it;
	toggle_fullscreen(data);
}

static void zoom(Browser *b, double delta)
{
	Tab *t = current_tab(b);
	if (!t)
		return;
	double z = webkit_web_view_get_zoom_level(t->view) + delta;
	z = CLAMP(z, 0.25, 3.0);
	webkit_web_view_set_zoom_level(t->view, z);
	set_status(b, "缩放 %d%%", (int)(z * 100 + 0.5));
}

static void zoom_reset(Browser *b)
{
	Tab *t = current_tab(b);
	if (!t)
		return;
	webkit_web_view_set_zoom_level(t->view, 1.0);
	set_status(b, "缩放 100%%");
}

static void on_menu_zoom_in(GtkMenuItem *it, gpointer data)
{
	(void)it;
	zoom(data, 0.1);
}

static void on_menu_zoom_out(GtkMenuItem *it, gpointer data)
{
	(void)it;
	zoom(data, -0.1);
}

static void on_menu_zoom_reset(GtkMenuItem *it, gpointer data)
{
	(void)it;
	zoom_reset(data);
}

static void on_menu_about(GtkMenuItem *it, gpointer data)
{
	(void)it;
	Browser *b = data;
	GtkWidget *dlg = gtk_about_dialog_new();
	gtk_about_dialog_set_program_name(GTK_ABOUT_DIALOG(dlg), "shui-browser");
	gtk_about_dialog_set_version(GTK_ABOUT_DIALOG(dlg), "0.1.0");
	gtk_about_dialog_set_comments(GTK_ABOUT_DIALOG(dlg),
				      "shuios 图形浏览器（WebKitGTK 引擎）");
	gtk_about_dialog_set_website_label(GTK_ABOUT_DIALOG(dlg), "shuios");
	gtk_window_set_transient_for(GTK_WINDOW(dlg),
				     GTK_WINDOW(b->win));
	gtk_dialog_run(GTK_DIALOG(dlg));
	gtk_widget_destroy(dlg);
}

static void on_menu_quit(GtkMenuItem *it, gpointer data)
{
	(void)it;
	(void)data;
	gtk_main_quit();
}

static gboolean on_key_press(GtkWidget *w, GdkEventKey *e, gpointer data)
{
	Browser *b = data;
	(void)w;
	guint mods = e->state & gtk_accelerator_get_default_mod_mask();
	guint kv = gdk_keyval_to_lower(e->keyval);

	if (mods & GDK_CONTROL_MASK) {
		if (kv == GDK_KEY_Tab) {
			int n = gtk_notebook_get_n_pages(
				GTK_NOTEBOOK(b->notebook));
			int i = gtk_notebook_get_current_page(
				GTK_NOTEBOOK(b->notebook));
			if (n > 1) {
				int next = (mods & GDK_SHIFT_MASK)
						   ? (i + n - 1) % n
						   : (i + 1) % n;
				gtk_notebook_set_current_page(
					GTK_NOTEBOOK(b->notebook), next);
			}
			return TRUE;
		}
		switch (kv) {
		case GDK_KEY_t:
			tab_new(b, start_uri());
			return TRUE;
		case GDK_KEY_w:
			close_current(b);
			return TRUE;
		case GDK_KEY_l:
			gtk_widget_grab_focus(b->url);
			gtk_editable_select_region(GTK_EDITABLE(b->url), 0, -1);
			return TRUE;
		case GDK_KEY_r:
			on_reload(NULL, b);
			return TRUE;
		case GDK_KEY_j:
			gtk_popover_popup(GTK_POPOVER(b->dl_pop));
			return TRUE;
		case GDK_KEY_q:
			gtk_main_quit();
			return TRUE;
		case GDK_KEY_0:
			zoom_reset(b);
			return TRUE;
		case GDK_KEY_plus:
		case GDK_KEY_equal:
			zoom(b, 0.1);
			return TRUE;
		case GDK_KEY_minus:
			zoom(b, -0.1);
			return TRUE;
		}
	}
	if (mods == GDK_MOD1_MASK && kv == GDK_KEY_Left) {
		on_back(NULL, b);
		return TRUE;
	}
	if (mods == GDK_MOD1_MASK && kv == GDK_KEY_Right) {
		on_forward(NULL, b);
		return TRUE;
	}
	if (kv == GDK_KEY_F11) {
		toggle_fullscreen(b);
		return TRUE;
	}
	if (kv == GDK_KEY_Escape && b->fullscreen) {
		toggle_fullscreen(b);
		return TRUE;
	}
	return FALSE;
}

static void on_switch_page(GtkNotebook *nb, GtkWidget *page, guint idx,
			   gpointer data)
{
	(void)nb;
	(void)page;
	(void)idx;
	update_nav(data);
}

static gboolean on_focus_in(GtkWidget *w, GdkEventFocus *ev, gpointer data)
{
	(void)w;
	(void)ev;
	g_active = data;
	return FALSE;
}

/* ---------------------------------------------------------------- 下载 */

static char *unique_path(const char *dir, const char *name)
{
	char *p = g_build_filename(dir, name, NULL);
	if (!g_file_test(p, G_FILE_TEST_EXISTS))
		return p;
	char *base = g_path_get_basename(name);
	char *dot = strrchr(base, '.');
	char *stem = dot ? g_strndup(base, (gsize)(dot - base)) : g_strdup(base);
	const char *ext = dot ? dot : "";
	for (int i = 1; i < 10000; i++) {
		g_free(p);
		p = g_strdup_printf("%s/%s (%d)%s", dir, stem, i, ext);
		if (!g_file_test(p, G_FILE_TEST_EXISTS))
			break;
	}
	g_free(stem);
	g_free(base);
	return p;
}

/* 建议文件名优先取响应头，其次取 URL 路径最后一段 */
static char *download_name(WebKitDownload *dl)
{
	WebKitURIResponse *resp = webkit_download_get_response(dl);
	const char *name = resp ?
		webkit_uri_response_get_suggested_filename(resp) : NULL;
	if (name && *name)
		return g_strdup(name);
	WebKitURIRequest *req = webkit_download_get_request(dl);
	const char *u = req ? webkit_uri_request_get_uri(req) : NULL;
	GUri *g = u ? g_uri_parse(u, G_URI_FLAGS_NONE, NULL) : NULL;
	const char *p = g ? g_uri_get_path(g) : NULL;
	if (p && *p && strcmp(p, "/")) {
		char *base = g_path_get_basename(p);
		char *dec = g_uri_unescape_string(base, NULL);
		g_free(base);
		g_uri_unref(g);
		if (dec && *dec)
			return dec;
		g_free(dec);
	} else if (g) {
		g_uri_unref(g);
	}
	return g_strdup("download.bin");
}

static void on_dl_progress(GObject *obj, GParamSpec *ps, gpointer data)
{
	(void)ps;
	DlRow *r = data;
	double p = webkit_download_get_estimated_progress(WEBKIT_DOWNLOAD(obj));
	gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(r->prog), p);
}

static DlRow *dl_row_add(Browser *b, const char *name)
{
	if (!b || !b->dl_list)
		return NULL;
	if (b->dl_empty) {
		gtk_widget_destroy(b->dl_empty);
		b->dl_empty = NULL;
	}
	DlRow *r = g_new0(DlRow, 1);
	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
	gtk_widget_set_margin_start(box, 14);
	gtk_widget_set_margin_end(box, 14);
	gtk_widget_set_margin_top(box, 8);
	gtk_widget_set_margin_bottom(box, 8);
	GtkWidget *nm = gtk_label_new(name);
	gtk_label_set_xalign(GTK_LABEL(nm), 0.0f);
	gtk_label_set_ellipsize(GTK_LABEL(nm), PANGO_ELLIPSIZE_MIDDLE);
	gtk_label_set_max_width_chars(GTK_LABEL(nm), 42);
	r->prog = gtk_progress_bar_new();
	gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(r->prog), FALSE);
	gtk_widget_set_size_request(r->prog, -1, 3);
	r->info = gtk_label_new("下载中…");
	gtk_label_set_xalign(GTK_LABEL(r->info), 0.0f);
	gtk_widget_set_margin_top(r->info, 2);
	gtk_style_context_add_class(gtk_widget_get_style_context(r->info),
				    "dim-label");
	gtk_box_pack_start(GTK_BOX(box), nm, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), r->prog, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), r->info, FALSE, FALSE, 0);
	r->row = gtk_list_box_row_new();
	gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(r->row), FALSE);
	gtk_container_add(GTK_CONTAINER(r->row), box);
	gtk_widget_show_all(r->row);
	gtk_list_box_prepend(GTK_LIST_BOX(b->dl_list), r->row);
	b->dl_count++;
	return r;
}

static void on_download_finished(WebKitDownload *dl, gpointer data)
{
	(void)data;
	const char *dest = webkit_download_get_destination(dl);
	char *path = dest ? g_filename_from_uri(dest, NULL, NULL) : NULL;
	DlRow *r = g_object_get_data(G_OBJECT(dl), "shui-dlrow");
	if (r) {
		gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(r->prog), 1.0);
		gtk_label_set_text(GTK_LABEL(r->info),
				   path ? path : "已保存");
		gtk_widget_set_tooltip_text(r->info, path);
	}
	if (g_active)
		set_status(g_active, "下载完成：%s", path ? path : "（未知位置）");
	g_free(path);
}

static void on_download_failed(WebKitDownload *dl, GError *error, gpointer data)
{
	(void)data;
	DlRow *r = g_object_get_data(G_OBJECT(dl), "shui-dlrow");
	if (r) {
		char *msg = g_strdup_printf("下载失败：%s",
					    error ? error->message : "未知错误");
		gtk_label_set_text(GTK_LABEL(r->info), msg);
		g_free(msg);
	}
	if (g_active)
		set_status(g_active, "下载失败：%s",
			   error ? error->message : "未知错误");
}

static void on_download_started(WebKitWebContext *ctx, WebKitDownload *dl,
				gpointer data)
{
	(void)ctx;
	(void)data;
	if (webkit_download_get_destination(dl))
		return;
	/* WebKit2GTK 4.1 没有 webkit_download_get_suggested_filename，
	   建议文件名挂在 download 的 response 上 */
	char *name = download_name(dl);
	char *dir = g_build_filename(DOWNLOAD_DIR, NULL);
	if (g_mkdir_with_parents(dir, 0755) != 0) {
		g_free(dir);
		dir = g_strdup("/tmp");
	}
	char *path = unique_path(dir, name);
	char *uri = g_filename_to_uri(path, NULL, NULL);
	webkit_download_set_destination(dl, uri);
	if (g_active) {
		DlRow *r = dl_row_add(g_active, name);
		if (r) {
			g_object_set_data_full(G_OBJECT(dl), "shui-dlrow", r,
					       g_free);
			gtk_widget_set_tooltip_text(r->row, path);
			g_signal_connect(dl, "notify::estimated-progress",
					 G_CALLBACK(on_dl_progress), r);
			/* 和 Edge 一样，下载一触即展示下载气泡 */
			if (g_active->dl_pop)
				gtk_popover_popup(GTK_POPOVER(g_active->dl_pop));
		}
		/* 下载页没有标题，用文件名占位，标签栏不至于全是“新标签页” */
		WebKitWebView *dv = webkit_download_get_web_view(dl);
		Tab *dt = dv ? g_object_get_data(G_OBJECT(dv), "shui-tab") : NULL;
		if (dt && dt->pending_url) {
			g_free(dt->title);
			dt->title = g_strdup(name);
			gtk_label_set_text(GTK_LABEL(dt->label), name);
			gtk_widget_set_tooltip_text(dt->tabbox, name);
			if (dt == current_tab(g_active))
				sync_window_title(g_active);
		}
		set_status(g_active, "开始下载：%s", name);
	}
	g_signal_connect(dl, "finished", G_CALLBACK(on_download_finished), NULL);
	g_signal_connect(dl, "failed", G_CALLBACK(on_download_failed), NULL);
	g_free(uri);
	g_free(path);
	g_free(dir);
	g_free(name);
}

/* ---------------------------------------------------------------- 窗口 */

static gboolean free_browser_idle(gpointer data)
{
	g_free(data);
	return G_SOURCE_REMOVE;
}

static void on_window_destroy(GtkWidget *w, gpointer data)
{
	(void)w;
	Browser *b = data;
	if (b->status_timer)
		g_source_remove(b->status_timer);
	if (g_active == b)
		g_active = NULL;
	g_nwin--;
	if (g_nwin <= 0)
		gtk_main_quit();
	/* 子控件（WebView）还在销毁流程里，Browser 延迟释放 */
	g_idle_add(free_browser_idle, b);
}

static gboolean on_window_delete(GtkWidget *w, GdkEvent *ev, gpointer data)
{
	(void)w;
	(void)ev;
	(void)data;
	return FALSE;
}

static void menu_item(GtkWidget *menu, const char *label, GCallback cb,
		      gpointer data)
{
	GtkWidget *it = gtk_menu_item_new_with_label(label);
	g_signal_connect(it, "activate", cb, data);
	gtk_menu_shell_append(GTK_MENU_SHELL(menu), it);
}

static GtkWidget *dl_popover_new(Browser *b)
{
	GtkWidget *pop = gtk_popover_new(NULL);
	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	GtkWidget *title = gtk_label_new(NULL);
	gtk_label_set_markup(GTK_LABEL(title), "<b>下载内容</b>");
	gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
	gtk_widget_set_margin_start(title, 14);
	gtk_widget_set_margin_end(title, 14);
	gtk_widget_set_margin_top(title, 10);
	gtk_widget_set_margin_bottom(title, 6);

	GtkWidget *sw = gtk_scrolled_window_new(NULL, NULL);
	gtk_widget_set_size_request(sw, 380, 300);
	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sw),
				       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	GtkWidget *list = gtk_list_box_new();
	gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_NONE);
	gtk_container_add(GTK_CONTAINER(sw), list);

	GtkWidget *elab = gtk_label_new("暂无下载");
	gtk_label_set_xalign(GTK_LABEL(elab), 0.0f);
	gtk_widget_set_margin_start(elab, 14);
	gtk_widget_set_margin_top(elab, 6);
	gtk_widget_set_margin_bottom(elab, 10);
	gtk_style_context_add_class(gtk_widget_get_style_context(elab),
				    "dim-label");
	GtkWidget *erow = gtk_list_box_row_new();
	gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(erow), FALSE);
	gtk_list_box_row_set_selectable(GTK_LIST_BOX_ROW(erow), FALSE);
	gtk_container_add(GTK_CONTAINER(erow), elab);
	gtk_list_box_prepend(GTK_LIST_BOX(list), erow);

	b->dl_list = list;
	b->dl_empty = erow;
	gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), sw, TRUE, TRUE, 0);
	gtk_container_add(GTK_CONTAINER(pop), box);
	gtk_widget_show_all(box);
	return pop;
}

static void on_menu_downloads(GtkMenuItem *it, gpointer data)
{
	(void)it;
	Browser *b = data;
	gtk_popover_popup(GTK_POPOVER(b->dl_pop));
}

static Browser *browser_new(const char *initial_uri)
{
	Browser *b = g_new0(Browser, 1);
	GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	b->win = win;
	g_nwin++;
	g_active = b;
	gtk_window_set_default_size(GTK_WINDOW(win), 1024, 700);
	gtk_window_set_title(GTK_WINDOW(win), "浏览器");
	gtk_window_set_icon_name(GTK_WINDOW(win), "web-browser");
	gtk_window_set_position(GTK_WINDOW(win), GTK_WIN_POS_CENTER);
	g_signal_connect(win, "destroy", G_CALLBACK(on_window_destroy), b);
	g_signal_connect(win, "delete-event", G_CALLBACK(on_window_delete), b);
	g_signal_connect(win, "key-press-event", G_CALLBACK(on_key_press), b);
	g_signal_connect(win, "focus-in-event", G_CALLBACK(on_focus_in), b);

	GtkWidget *hb = gtk_header_bar_new();
	b->header = hb;
	gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(hb), TRUE);
	gtk_header_bar_set_title(GTK_HEADER_BAR(hb), "浏览器");

	b->back = icon_button("go-previous-symbolic", "后退（Alt+←）",
			      G_CALLBACK(on_back), b);
	b->forward = icon_button("go-next-symbolic", "前进（Alt+→）",
				 G_CALLBACK(on_forward), b);
	b->reload = icon_button("view-refresh-symbolic", "刷新（Ctrl+R）",
				G_CALLBACK(on_reload), b);
	GtkWidget *newtab = icon_button("list-add-symbolic", "新建标签页（Ctrl+T）",
					G_CALLBACK(on_new_tab), b);

	b->url = gtk_entry_new();
	gtk_entry_set_placeholder_text(GTK_ENTRY(b->url), "搜索或输入网址");
	gtk_widget_set_hexpand(b->url, TRUE);
	gtk_entry_set_width_chars(GTK_ENTRY(b->url), 40);
	gtk_widget_set_valign(b->url, GTK_ALIGN_CENTER);
	g_signal_connect(b->url, "activate", G_CALLBACK(on_url_activate), b);

	GtkWidget *menu = gtk_menu_new();
	menu_item(menu, "新建标签页\tCtrl+T", G_CALLBACK(on_menu_new_tab), b);
	menu_item(menu, "关闭标签页\tCtrl+W", G_CALLBACK(on_menu_close_tab), b);
	menu_item(menu, "刷新\tCtrl+R", G_CALLBACK(on_menu_reload), b);
	menu_item(menu, "下载内容\tCtrl+J", G_CALLBACK(on_menu_downloads), b);
	gtk_menu_shell_append(GTK_MENU_SHELL(menu),
			      gtk_separator_menu_item_new());
	menu_item(menu, "放大\tCtrl++", G_CALLBACK(on_menu_zoom_in), b);
	menu_item(menu, "缩小\tCtrl+-", G_CALLBACK(on_menu_zoom_out), b);
	menu_item(menu, "实际大小\tCtrl+0", G_CALLBACK(on_menu_zoom_reset), b);
	menu_item(menu, "全屏\tF11", G_CALLBACK(on_menu_fullscreen), b);
	gtk_menu_shell_append(GTK_MENU_SHELL(menu),
			      gtk_separator_menu_item_new());
	menu_item(menu, "关于 shui-browser", G_CALLBACK(on_menu_about), b);
	menu_item(menu, "退出\tCtrl+Q", G_CALLBACK(on_menu_quit), b);
	gtk_widget_show_all(menu);

	GtkWidget *mb = gtk_menu_button_new();
	gtk_widget_set_tooltip_text(mb, "菜单");
	gtk_menu_button_set_popup(GTK_MENU_BUTTON(mb), menu);
	gtk_widget_set_focus_on_click(mb, FALSE);

	b->dl_pop = dl_popover_new(b);
	b->dl_btn = gtk_menu_button_new();
	gtk_widget_set_tooltip_text(b->dl_btn, "下载内容（Ctrl+J）");
	gtk_button_set_image(GTK_BUTTON(b->dl_btn),
			     gtk_image_new_from_icon_name("folder-download-symbolic",
							  GTK_ICON_SIZE_BUTTON));
	gtk_menu_button_set_popover(GTK_MENU_BUTTON(b->dl_btn), b->dl_pop);
	gtk_widget_set_focus_on_click(b->dl_btn, FALSE);

	gtk_header_bar_pack_start(GTK_HEADER_BAR(hb), b->back);
	gtk_header_bar_pack_start(GTK_HEADER_BAR(hb), b->forward);
	gtk_header_bar_pack_start(GTK_HEADER_BAR(hb), b->reload);
	gtk_header_bar_pack_start(GTK_HEADER_BAR(hb), b->url);
	gtk_header_bar_pack_end(GTK_HEADER_BAR(hb), mb);
	gtk_header_bar_pack_end(GTK_HEADER_BAR(hb), b->dl_btn);
	gtk_header_bar_pack_end(GTK_HEADER_BAR(hb), newtab);
	gtk_window_set_titlebar(GTK_WINDOW(win), hb);

	GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	b->progress = gtk_progress_bar_new();
	gtk_progress_bar_set_show_text(GTK_PROGRESS_BAR(b->progress), FALSE);
	gtk_widget_set_size_request(b->progress, -1, 3);
	gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(b->progress), 0.0);
	b->notebook = gtk_notebook_new();
	gtk_notebook_set_scrollable(GTK_NOTEBOOK(b->notebook), TRUE);
	b->status = gtk_label_new(NULL);
	gtk_label_set_xalign(GTK_LABEL(b->status), 0.0f);
	gtk_label_set_ellipsize(GTK_LABEL(b->status), PANGO_ELLIPSIZE_MIDDLE);
	gtk_widget_set_margin_start(b->status, 10);
	gtk_widget_set_margin_end(b->status, 10);
	gtk_widget_set_margin_top(b->status, 3);
	gtk_widget_set_margin_bottom(b->status, 4);
	gtk_style_context_add_class(gtk_widget_get_style_context(b->status),
				    "dim-label");
	gtk_widget_set_no_show_all(b->status, TRUE);

	gtk_box_pack_start(GTK_BOX(vbox), b->progress, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(vbox), b->notebook, TRUE, TRUE, 0);
	gtk_box_pack_end(GTK_BOX(vbox), b->status, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(win), vbox);

	g_signal_connect(b->notebook, "switch-page", G_CALLBACK(on_switch_page),
			 b);

	tab_new(b, initial_uri ? initial_uri : start_uri());
	gtk_widget_show_all(win);
	gtk_widget_hide(b->status);
	update_nav(b);
	return b;
}

int main(int argc, char **argv)
{
	gtk_init(&argc, &argv);
	g_set_prgname("shui-browser");

	GtkCssProvider *css = gtk_css_provider_new();
	gtk_css_provider_load_from_data(
		css,
		".tab-close { padding: 0 2px; min-width: 18px; min-height: 18px; }\n"
		"headerbar entry { min-height: 26px; }\n",
		-1, NULL);
	gtk_style_context_add_provider_for_screen(
		gdk_screen_get_default(), GTK_STYLE_PROVIDER(css),
		GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

	g_mkdir_with_parents(g_get_user_data_dir(), 0755);
	g_mkdir_with_parents(g_get_user_cache_dir(), 0755);

	WebKitWebContext *ctx = webkit_web_context_get_default();
	webkit_web_context_set_cache_model(ctx, WEBKIT_CACHE_MODEL_WEB_BROWSER);
	char *cookie_path =
		g_build_filename(g_get_user_data_dir(), "cookies.sqlite", NULL);
	WebKitCookieManager *cm = webkit_web_context_get_cookie_manager(ctx);
	webkit_cookie_manager_set_persistent_storage(
		cm, cookie_path, WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
	webkit_cookie_manager_set_accept_policy(
		cm, WEBKIT_COOKIE_POLICY_ACCEPT_NO_THIRD_PARTY);
	g_free(cookie_path);
	g_signal_connect(ctx, "download-started",
			 G_CALLBACK(on_download_started), NULL);

	Browser *b = browser_new(NULL);
	for (int i = 1; i < argc; i++) {
		if (i > 1)
			tab_new(b, NULL);
		load_text(b, argv[i]);
	}

	gtk_main();
	g_free(g_start_uri);
	return 0;
}
