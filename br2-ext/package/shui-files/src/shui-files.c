/*
 * shuios 文件管理器（shui-files）
 *
 * P0 目标：日常文件操作不依赖终端里的 mc。
 *
 *   * 浏览：目录列表（名称/大小/修改时间/类型），双击进入或打开；
 *   * 路径栏可直接输入或粘贴路径（~ 和相对路径都支持）；
 *   * 操作：新建文件夹、重命名（F2）、删除（Delete，递归、需确认）；
 *   * 键盘：F5 刷新、BackSpace 上级、Ctrl+H 隐藏文件、Ctrl+L 路径栏；
 *   * 打开文件：可执行文件直接运行，其余交给 shui-browser
 *     （文本/图片都能显示，避免为 MVP 引入新的预览组件）。
 *
 * 视觉一律取自 shuios-ui.h（唯一色源，见 docs/06-视觉规范.md），
 * 与 shui-store / shui-panel 保持一致。
 */

/* nftw/FTW_DP 只在 _GNU_SOURCE（或 _XOPEN_SOURCE>=500）下由 <ftw.h> 暴露，
 * 否则 struct FTW 都没定义。必须在所有 include 之前。 */
#define _GNU_SOURCE

#include <errno.h>
#include <ftw.h>
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "shuios-ui.h"

#define START_DIR "/workspace"
#define BROWSER "/usr/bin/shui-browser"

enum {
	C_ICON,
	C_NAME,
	C_SIZE,
	C_TIME,
	C_TYPE,
	C_ISDIR,
	C_PATH,
	N_COLS
};

typedef struct {
	gchar *name;    /* 显示名（UTF-8） */
	gchar *path;    /* 原始路径 */
	gboolean is_dir;
	gboolean is_exec;
	goffset size;
	time_t mtime;
} Entry;

static GtkWidget *g_window;
static GtkWidget *g_view;
static GtkWidget *g_path;
static GtkWidget *g_status;
static GtkListStore *g_store;
static gchar *g_cwd;
static GList *g_back;   /* 后退栈（gchar*） */
static gboolean g_hidden;

/* ---------------------------------------------------------------- 工具 */

static void
set_status(const char *text)
{
	gtk_label_set_text(GTK_LABEL(g_status), text);
}

static gchar *
fmt_size(goffset n)
{
	static const char *unit[] = { "B", "KB", "MB", "GB", "TB" };
	double v = (double)n;
	int i = 0;

	while (v >= 1024.0 && i < 4) {
		v /= 1024.0;
		i++;
	}
	return i ? g_strdup_printf("%.1f %s", v, unit[i])
		 : g_strdup_printf("%.0f %s", v, unit[i]);
}

static gchar *
fmt_time(time_t t)
{
	struct tm tm;
	char buf[32];

	if (!localtime_r(&t, &tm))
		return g_strdup("");
	strftime(buf, sizeof buf, "%Y-%m-%d %H:%M", &tm);
	return g_strdup(buf);
}

static const char *
type_label(Entry *e)
{
	if (e->is_dir)
		return "文件夹";
	if (e->is_exec)
		return "可执行文件";
	return "文件";
}

static const char *
icon_for(Entry *e)
{
	const char *dot;

	if (e->is_dir)
		return "folder";
	if (e->is_exec)
		return "application-x-executable";

	dot = strrchr(e->name, '.');
	if (dot) {
		static const char *img[] = { ".png", ".jpg", ".jpeg", ".gif",
					     ".svg", ".webp", ".bmp", NULL };
		static const char *aud[] = { ".mp3", ".flac", ".ogg", ".wav",
					     ".m4a", NULL };
		static const char *vid[] = { ".mp4", ".mkv", ".webm", ".avi",
					     ".mov", NULL };
		static const char *arc[] = { ".zip", ".tar", ".gz", ".xz",
					     ".7z", ".zst", NULL };
		for (int i = 0; img[i]; i++)
			if (g_ascii_strcasecmp(dot, img[i]) == 0)
				return "image-x-generic";
		for (int i = 0; aud[i]; i++)
			if (g_ascii_strcasecmp(dot, aud[i]) == 0)
				return "audio-x-generic";
		for (int i = 0; vid[i]; i++)
			if (g_ascii_strcasecmp(dot, vid[i]) == 0)
				return "video-x-generic";
		for (int i = 0; arc[i]; i++)
			if (g_ascii_strcasecmp(dot, arc[i]) == 0)
				return "package-x-generic";
	}
	return "text-x-generic";
}

/* ------------------------------------------------------------ 目录读取 */

static void
entry_free(gpointer ptr)
{
	Entry *e = ptr;

	g_free(e->name);
	g_free(e->path);
	g_free(e);
}

static gint
cmp_entry(gconstpointer a, gconstpointer b)
{
	const Entry *ea = *(Entry * const *)a;
	const Entry *eb = *(Entry * const *)b;

	if (ea->is_dir != eb->is_dir)
		return ea->is_dir ? -1 : 1;
	return g_utf8_collate(ea->name, eb->name);
}

static void reload(void);

static void
navigate_full(const gchar *target, gboolean record)
{
	gchar *canon = g_canonicalize_filename(target, g_cwd);
	struct stat st;

	if (stat(canon, &st) != 0 || !S_ISDIR(st.st_mode)) {
		gchar *msg = g_strdup_printf("打不开：%s", canon);
		set_status(msg);
		g_free(msg);
		g_free(canon);
		return;
	}

	if (record && g_cwd)
		g_back = g_list_prepend(g_back, g_strdup(g_cwd));
	g_free(g_cwd);
	g_cwd = canon;
	reload();
}

static void
navigate(const gchar *target)
{
	navigate_full(target, TRUE);
}

static void
reload(void)
{
	GDir *dir;
	GError *err = NULL;
	GPtrArray *arr;
	GtkTreeIter it;
	const gchar *name;
	gchar *status;

	gtk_list_store_clear(g_store);
	arr = g_ptr_array_new_with_free_func(entry_free);

	dir = g_dir_open(g_cwd, 0, &err);
	if (!dir) {
		status = g_strdup_printf("读取失败：%s",
					 err ? err->message : "未知错误");
		set_status(status);
		g_free(status);
		if (err)
			g_error_free(err);
		g_ptr_array_free(arr, TRUE);
		return;
	}

	while ((name = g_dir_read_name(dir))) {
		gchar *path;
		struct stat st;
		Entry *e;

		if (!g_hidden && name[0] == '.')
			continue;
		path = g_build_filename(g_cwd, name, NULL);
		if (stat(path, &st) != 0) {
			g_free(path);
			continue;
		}

		e = g_new0(Entry, 1);
		e->name = g_filename_display_name(name);
		e->path = path;
		e->is_dir = S_ISDIR(st.st_mode);
		e->is_exec = !e->is_dir && access(path, X_OK) == 0;
		e->size = st.st_size;
		e->mtime = st.st_mtime;
		g_ptr_array_add(arr, e);
	}
	g_dir_close(dir);

	g_ptr_array_sort(arr, cmp_entry);
	for (guint i = 0; i < arr->len; i++) {
		Entry *e = g_ptr_array_index(arr, i);
		GtkTreeIter it;
		gchar *size_s = e->is_dir ? g_strdup("-") : fmt_size(e->size);
		gchar *time_s = fmt_time(e->mtime);

		gtk_list_store_append(g_store, &it);
		gtk_list_store_set(g_store, &it,
				   C_ICON, icon_for(e),
				   C_NAME, e->name,
				   C_SIZE, size_s,
				   C_TIME, time_s,
				   C_TYPE, type_label(e),
				   C_ISDIR, e->is_dir,
				   C_PATH, e->path,
				   -1);
		g_free(size_s);
		g_free(time_s);
	}

	status = g_strdup_printf("%u 项", arr->len);
	set_status(status);
	g_free(status);
	g_ptr_array_free(arr, TRUE);

	gtk_entry_set_text(GTK_ENTRY(g_path), g_cwd);
	gtk_widget_grab_focus(g_view);
	/* 默认选中第一项：否则光标停在"0 号位"却没有选中，按一次 ↓ 会落到第二项，
	 * 回车很容易打开错文件。 */
	if (gtk_tree_model_get_iter_first(GTK_TREE_MODEL(g_store), &it)) {
		GtkTreePath *first =
			gtk_tree_model_get_path(GTK_TREE_MODEL(g_store), &it);
		gtk_tree_view_set_cursor(GTK_TREE_VIEW(g_view), first, NULL, FALSE);
		gtk_tree_path_free(first);
	}
}

/* ---------------------------------------------------------------- 选择 */

static gboolean
selected(GtkTreeIter *iter, gchar **path, gchar **name, gboolean *is_dir)
{
	GtkTreeSelection *sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(g_view));

	if (!gtk_tree_selection_get_selected(sel, NULL, iter))
		return FALSE;
	if (path)
		gtk_tree_model_get(GTK_TREE_MODEL(g_store), iter,
				   C_PATH, path, -1);
	if (name)
		gtk_tree_model_get(GTK_TREE_MODEL(g_store), iter,
				   C_NAME, name, -1);
	if (is_dir)
		gtk_tree_model_get(GTK_TREE_MODEL(g_store), iter,
				   C_ISDIR, is_dir, -1);
	return TRUE;
}

static void
on_selection_changed(GtkTreeSelection *sel, gpointer data)
{
	GtkTreeIter it;
	gchar *name = NULL, *size = NULL;
	gboolean is_dir;

	(void)sel;
	(void)data;
	if (!selected(&it, NULL, &name, &is_dir))
		return;
	gtk_tree_model_get(GTK_TREE_MODEL(g_store), &it, C_SIZE, &size, -1);
	if (is_dir)
		set_status(name);
	else {
		gchar *s = g_strdup_printf("%s · %s", name, size);
		set_status(s);
		g_free(s);
	}
	g_free(name);
	g_free(size);
}

/* ------------------------------------------------------------ 打开文件 */

static void
open_file(const gchar *path)
{
	GError *err = NULL;

	if (access(path, X_OK) == 0) {
		gchar *argv[] = { (gchar *)path, NULL };
		if (!g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH,
				   NULL, NULL, NULL, &err)) {
			gchar *msg = g_strdup_printf("运行失败：%s",
						     err ? err->message : "");
			set_status(msg);
			g_free(msg);
			if (err)
				g_error_free(err);
		}
		return;
	}

	if (access(BROWSER, X_OK) == 0) {
		gchar *uri = g_filename_to_uri(path, NULL, &err);
		if (uri) {
			gchar *argv[] = { BROWSER, uri, NULL };
			g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH,
				      NULL, NULL, NULL, &err);
			g_free(uri);
		}
		if (err) {
			gchar *msg = g_strdup_printf("打开失败：%s", err->message);
			set_status(msg);
			g_free(msg);
			g_error_free(err);
			err = NULL;
		}
		return;
	}

	set_status("没有可用的打开方式（shui-browser 未安装）");
}

static void
on_row_activated(GtkTreeView *view, GtkTreePath *tpath, GtkTreeViewColumn *col,
		 gpointer data)
{
	GtkTreeIter it;
	gchar *path = NULL;
	gboolean is_dir;

	(void)view;
	(void)col;
	(void)data;
	if (!gtk_tree_model_get_iter(GTK_TREE_MODEL(g_store), &it, tpath))
		return;
	gtk_tree_model_get(GTK_TREE_MODEL(g_store), &it,
			   C_PATH, &path, C_ISDIR, &is_dir, -1);
	if (!path)
		return;
	if (is_dir) {
		navigate(path);
	} else {
		open_file(path);
	}
	g_free(path);
}

/* -------------------------------------------------------------- 导航栏 */

static void
go_up(void)
{
	gchar *parent = g_path_get_dirname(g_cwd);

	navigate(parent);
	g_free(parent);
}

static void
go_back(void)
{
	gchar *prev;

	if (!g_back) {
		set_status("没有更早的目录");
		return;
	}
	prev = g_back->data;
	g_back = g_list_delete_link(g_back, g_back);
	navigate_full(prev, FALSE);
	g_free(prev);
}

static void
on_path_activate(GtkEntry *entry, gpointer data)
{
	const gchar *text = gtk_entry_get_text(entry);
	gchar *expanded;

	(void)data;
	if (!text || !*text)
		return;
	expanded = g_strdup(text);
	if (expanded[0] == '~' && (expanded[1] == '/' || expanded[1] == '\0')) {
		gchar *tmp = g_build_filename(g_get_home_dir(),
					      expanded[1] ? expanded + 2 : NULL,
					      NULL);
		g_free(expanded);
		expanded = tmp;
	}
	navigate(expanded);
	g_free(expanded);
}

static void
on_back_clicked(GtkButton *b, gpointer d)
{
	(void)b;
	(void)d;
	go_back();
}

static void
on_up_clicked(GtkButton *b, gpointer d)
{
	(void)b;
	(void)d;
	go_up();
}

/* ------------------------------------------------------------ 新建/改名 */

static gchar *
ask_name(const char *title, const char *initial)
{
	GtkWidget *dlg = gtk_dialog_new_with_buttons(
		title, GTK_WINDOW(g_window),
		GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, "取消",
		GTK_RESPONSE_CANCEL, "确定", GTK_RESPONSE_ACCEPT, NULL);
	GtkWidget *entry = gtk_entry_new();
	gchar *result = NULL;

	gtk_entry_set_text(GTK_ENTRY(entry), initial ? initial : "");
	gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
	gtk_widget_set_margin_start(entry, UI_SP_4);
	gtk_widget_set_margin_end(entry, UI_SP_4);
	gtk_widget_set_margin_top(entry, UI_SP_2);
	gtk_widget_set_margin_bottom(entry, UI_SP_2);
	gtk_container_add(
		GTK_CONTAINER(gtk_dialog_get_content_area(GTK_DIALOG(dlg))),
		entry);
	gtk_dialog_set_default_response(GTK_DIALOG(dlg), GTK_RESPONSE_ACCEPT);

	gtk_widget_show_all(dlg);
	if (gtk_dialog_run(GTK_DIALOG(dlg)) == GTK_RESPONSE_ACCEPT) {
		const gchar *t = gtk_entry_get_text(GTK_ENTRY(entry));
		if (t && *t)
			result = g_strdup(t);
	}
	gtk_widget_destroy(dlg);
	return result;
}

static gboolean
valid_name(const char *name)
{
	return name && *name && !strchr(name, '/') && strcmp(name, ".") != 0 &&
	       strcmp(name, "..") != 0;
}

static void
on_new_folder(GtkButton *b, gpointer d)
{
	gchar *name;
	gchar *path;
	gchar *msg;

	(void)b;
	(void)d;
	name = ask_name("新建文件夹", "新建文件夹");
	if (!name)
		return;
	if (!valid_name(name)) {
		set_status("名字不合法（不能为空、不能含 /）");
		g_free(name);
		return;
	}
	path = g_build_filename(g_cwd, name, NULL);
	if (g_mkdir(path, 0755) != 0) {
		msg = g_strdup_printf("创建失败：%s", g_strerror(errno));
		set_status(msg);
		g_free(msg);
	} else {
		msg = g_strdup_printf("已创建 %s", name);
		set_status(msg);
		g_free(msg);
		reload();
	}
	g_free(path);
	g_free(name);
}

static void
on_rename(GtkButton *b, gpointer d)
{
	GtkTreeIter it;
	gchar *old_path = NULL, *old_name = NULL;
	gchar *name, *new_path, *msg;

	(void)b;
	(void)d;
	if (!selected(&it, &old_path, &old_name, NULL)) {
		set_status("先选中一个文件或文件夹");
		return;
	}
	name = ask_name("重命名", old_name);
	if (!name) {
		g_free(old_path);
		g_free(old_name);
		return;
	}
	if (!valid_name(name)) {
		set_status("名字不合法（不能为空、不能含 /）");
		goto out;
	}
	new_path = g_build_filename(g_cwd, name, NULL);
	if (g_rename(old_path, new_path) != 0) {
		msg = g_strdup_printf("重命名失败：%s", g_strerror(errno));
		set_status(msg);
		g_free(msg);
	} else {
		msg = g_strdup_printf("已重命名为 %s", name);
		set_status(msg);
		g_free(msg);
		reload();
	}
	g_free(new_path);
out:
	g_free(name);
	g_free(old_path);
	g_free(old_name);
}

/* ---------------------------------------------------------------- 删除 */

static int
rm_cb(const char *path, const struct stat *sb, int flag, struct FTW *ftw)
{
	(void)sb;
	(void)ftw;
	return (flag == FTW_DP) ? rmdir(path) : unlink(path);
}

static gboolean
rm_rf(const char *path)
{
	return nftw(path, rm_cb, 64, FTW_DEPTH | FTW_PHYS) == 0;
}

static void
on_delete(GtkButton *b, gpointer d)
{
	GtkTreeIter it;
	gchar *path = NULL, *name = NULL;
	gboolean is_dir;
	GtkWidget *dlg;
	gchar *text, *msg;

	(void)b;
	(void)d;
	if (!selected(&it, &path, &name, &is_dir)) {
		set_status("先选中要删除的项目");
		return;
	}
	text = g_strdup_printf("要删除「%s」吗？%s", name,
			       is_dir ? "\n文件夹里的所有内容都会一起删掉，且不可恢复。"
				      : "\n此操作不可恢复。");
	dlg = gtk_message_dialog_new(GTK_WINDOW(g_window),
				     GTK_DIALOG_MODAL |
					     GTK_DIALOG_DESTROY_WITH_PARENT,
				     GTK_MESSAGE_WARNING, GTK_BUTTONS_NONE,
				     "%s", "确认删除");
	gtk_message_dialog_format_secondary_text(
		GTK_MESSAGE_DIALOG(dlg), "%s", text);
	/* 不用 GTK_BUTTONS_CANCEL：镜像里没有 gtk30 的翻译，会显示英文 Cancel。 */
	gtk_dialog_add_button(GTK_DIALOG(dlg), "取消", GTK_RESPONSE_CANCEL);
	gtk_dialog_add_button(GTK_DIALOG(dlg), "删除", GTK_RESPONSE_ACCEPT);
	/* Enter 走「取消」：确认删除必须明确点/选到「删除」按钮。 */
	gtk_dialog_set_default_response(GTK_DIALOG(dlg), GTK_RESPONSE_CANCEL);
	gtk_widget_show_all(dlg);
	if (gtk_dialog_run(GTK_DIALOG(dlg)) == GTK_RESPONSE_ACCEPT) {
		if (rm_rf(path)) {
			msg = g_strdup_printf("已删除 %s", name);
			set_status(msg);
			g_free(msg);
		} else {
			msg = g_strdup_printf("删除失败：%s", g_strerror(errno));
			set_status(msg);
			g_free(msg);
		}
		reload();
	}
	gtk_widget_destroy(dlg);
	g_free(text);
	g_free(path);
	g_free(name);
}

static void
on_refresh(GtkButton *b, gpointer d)
{
	(void)b;
	(void)d;
	reload();
}

/* ---------------------------------------------------------------- 键盘 */

static gboolean
on_key_press(GtkWidget *w, GdkEventKey *ev, gpointer data)
{
	(void)w;
	(void)data;
	switch (ev->keyval) {
	case GDK_KEY_F5:
		reload();
		return TRUE;
	case GDK_KEY_F2:
		on_rename(NULL, NULL);
		return TRUE;
	case GDK_KEY_Delete:
		on_delete(NULL, NULL);
		return TRUE;
	case GDK_KEY_BackSpace:
		go_up();
		return TRUE;
	default:
		break;
	}
	if ((ev->state & GDK_CONTROL_MASK) && (ev->state & GDK_SHIFT_MASK) &&
	    (ev->keyval == GDK_KEY_n || ev->keyval == GDK_KEY_N)) {
		on_new_folder(NULL, NULL);
		return TRUE;
	}
	if ((ev->state & GDK_CONTROL_MASK) && (ev->keyval == GDK_KEY_h ||
					       ev->keyval == GDK_KEY_H)) {
		g_hidden = !g_hidden;
		reload();
		return TRUE;
	}
	if ((ev->state & GDK_CONTROL_MASK) && (ev->keyval == GDK_KEY_l ||
					       ev->keyval == GDK_KEY_L)) {
		gtk_widget_grab_focus(g_path);
		return TRUE;
	}
	return FALSE;
}

/* ---------------------------------------------------------------- 样式 */

static void
install_css(void)
{
	const char *css =
		"window { background-image: none; background-color: "
		UI_HEX_BG_PANEL "; color: " UI_HEX_FG "; }\n"
		"headerbar { background-image: none; background-color: "
		UI_HEX_BG_PANEL "; color: " UI_HEX_FG "; border-bottom: 1px solid "
		UI_HEX_LINE "; padding: " UI_STR(UI_SP_1) "px;"
		"  box-shadow: none; }\n"
		"headerbar .title { font-weight: bold; font-size: "
		UI_STR(UI_FS_TITLE) "px; }\n"
		"headerbar .subtitle { color: " UI_HEX_FG_WEAK "; font-size: "
		UI_STR(UI_FS_META) "px; }\n"
		"headerbar button { background-image: none;"
		"  background-color: transparent; border: none; color: "
		UI_HEX_FG_DIM "; padding: 0 " UI_STR(UI_SP_2) "px; }\n"
		"headerbar button:hover { background-color: " UI_HEX_BG_HOVER ";"
		"  color: " UI_HEX_FG "; }\n"
		"entry { background-color: " UI_HEX_BG_CARD "; color: " UI_HEX_FG
		"; border-radius: " UI_STR(UI_RADIUS) "px; border: 1px solid "
		UI_HEX_LINE "; padding: " UI_STR(UI_SP_1) "px " UI_STR(UI_SP_2)
		"px; }\n"
		"entry:focus { border-color: " UI_HEX_ACCENT "; }\n"
		"button { background-image: none; background-color: "
		UI_HEX_BG_CARD "; color: " UI_HEX_FG "; border: 1px solid "
		UI_HEX_LINE "; border-radius: " UI_STR(UI_RADIUS) "px;"
		"  padding: " UI_STR(UI_SP_1) "px " UI_STR(UI_SP_3) "px;"
		"  box-shadow: none; text-shadow: none; }\n"
		"button:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		"scrolledwindow { background-color: " UI_HEX_BG_WINDOW "; }\n"
		"treeview.view { background-color: " UI_HEX_BG_WINDOW ";"
		"  color: " UI_HEX_FG "; font-size: " UI_STR(UI_FS_BODY) "px;"
		"  outline-style: none; }\n"
		"treeview.view:selected { background-color: " UI_HEX_ACCENT ";"
		"  color: " UI_HEX_ACCENT_ON "; }\n"
		"treeview header button { background-image: none;"
		"  background-color: " UI_HEX_BG_PANEL "; color: " UI_HEX_FG_DIM
		"; border: none; border-bottom: 1px solid " UI_HEX_LINE ";"
		"  border-radius: 0; padding: " UI_STR(UI_SP_1) "px;"
		"  box-shadow: none; text-shadow: none; }\n"
		".pathbar { padding: " UI_STR(UI_SP_2) "px " UI_STR(UI_SP_3)
		"px; }\n"
		"label.status { color: " UI_HEX_FG_WEAK "; font-size: "
		UI_STR(UI_FS_META) "px; }\n";

	GtkCssProvider *prov = gtk_css_provider_new();

	gtk_css_provider_load_from_data(prov, css, -1, NULL);
	gtk_style_context_add_provider_for_screen(
		gdk_screen_get_default(), GTK_STYLE_PROVIDER(prov),
		GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(prov);
}

/* ---------------------------------------------------------------- 主程序 */

int
main(int argc, char **argv)
{
	GtkWidget *header, *outer, *toolbar, *scroll;
	GtkCellRenderer *r;
	GtkTreeViewColumn *c;
	GtkTreeSelection *sel;
	gchar *start;

	setenv("GTK_THEME", "Adwaita:dark", 0);
	gtk_init(&argc, &argv);
	install_css();

	start = argc > 1 ? g_canonicalize_filename(argv[1], NULL)
			 : g_strdup(START_DIR);
	if (!g_file_test(start, G_FILE_TEST_IS_DIR)) {
		g_free(start);
		start = g_strdup(g_get_home_dir() ?: START_DIR);
	}
	if (!g_file_test(start, G_FILE_TEST_IS_DIR)) {
		g_free(start);
		start = g_strdup("/");
	}
	g_cwd = start;

	g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	/* 只给默认尺寸，不设 size_request：文件管理器会像终端一样被平铺到半屏，
	 * 强制最小宽度会让 GTK 按 900 排版、右侧列被裁掉（V21 踩过）。 */
	gtk_window_set_default_size(GTK_WINDOW(g_window), 900, 600);
	gtk_window_set_title(GTK_WINDOW(g_window), "文件");
	g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	header = gtk_header_bar_new();
	gtk_header_bar_set_title(GTK_HEADER_BAR(header), "文件");
	gtk_header_bar_set_subtitle(GTK_HEADER_BAR(header), "浏览与管理");
	gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
	gtk_header_bar_set_decoration_layout(GTK_HEADER_BAR(header),
					     "menu:minimize,maximize,close");
	gtk_window_set_titlebar(GTK_WINDOW(g_window), header);

	GtkWidget *btn_back = gtk_button_new_with_label("后退");
	GtkWidget *btn_up = gtk_button_new_with_label("上级");
	GtkWidget *btn_new = gtk_button_new_with_label("新建文件夹");
	GtkWidget *btn_refresh = gtk_button_new_with_label("刷新");
	g_signal_connect(btn_back, "clicked", G_CALLBACK(on_back_clicked), NULL);
	g_signal_connect(btn_up, "clicked", G_CALLBACK(on_up_clicked), NULL);
	g_signal_connect(btn_new, "clicked", G_CALLBACK(on_new_folder), NULL);
	g_signal_connect(btn_refresh, "clicked", G_CALLBACK(on_refresh), NULL);
	gtk_header_bar_pack_start(GTK_HEADER_BAR(header), btn_back);
	gtk_header_bar_pack_start(GTK_HEADER_BAR(header), btn_up);
	gtk_header_bar_pack_end(GTK_HEADER_BAR(header), btn_new);
	gtk_header_bar_pack_end(GTK_HEADER_BAR(header), btn_refresh);

	outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_container_add(GTK_CONTAINER(g_window), outer);

	toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	gtk_style_context_add_class(gtk_widget_get_style_context(toolbar),
				    "pathbar");
	g_path = gtk_entry_new();
	gtk_entry_set_placeholder_text(GTK_ENTRY(g_path), "路径");
	g_signal_connect(g_path, "activate", G_CALLBACK(on_path_activate), NULL);
	gtk_box_pack_start(GTK_BOX(toolbar), g_path, TRUE, TRUE, 0);
	gtk_box_pack_start(GTK_BOX(outer), toolbar, FALSE, FALSE, 0);

	g_store = gtk_list_store_new(N_COLS, G_TYPE_STRING, G_TYPE_STRING,
				     G_TYPE_STRING, G_TYPE_STRING, G_TYPE_STRING,
				     G_TYPE_BOOLEAN, G_TYPE_STRING);
	g_view = gtk_tree_view_new_with_model(GTK_TREE_MODEL(g_store));
	gtk_tree_view_set_headers_visible(GTK_TREE_VIEW(g_view), TRUE);
	/* 关掉 treeview 自带的「输入即搜索」：它会先吞掉 Ctrl+Shift+N 这类组合键，
	 * 窗口级的快捷键永远收不到（表现为按了没反应）。 */
	gtk_tree_view_set_enable_search(GTK_TREE_VIEW(g_view), FALSE);

	r = gtk_cell_renderer_pixbuf_new();
	g_object_set(r, "xpad", 6, "ypad", 4, NULL);
	c = gtk_tree_view_column_new_with_attributes("", r, "icon-name",
						     C_ICON, NULL);
	gtk_tree_view_column_set_sizing(c, GTK_TREE_VIEW_COLUMN_FIXED);
	gtk_tree_view_column_set_fixed_width(c, 28);
	gtk_tree_view_append_column(GTK_TREE_VIEW(g_view), c);

	r = gtk_cell_renderer_text_new();
	g_object_set(r, "ellipsize", PANGO_ELLIPSIZE_END, "ypad", 4, NULL);
	c = gtk_tree_view_column_new_with_attributes("名称", r, "text", C_NAME,
						     NULL);
	/* 固定基准宽度 + expand 吸收余量：AUTOSIZE 会让长文件名把整张表撑宽，
	 * 平铺到 620px 时右侧「修改时间/类型」就被挤出窗口。 */
	gtk_tree_view_column_set_sizing(c, GTK_TREE_VIEW_COLUMN_FIXED);
	gtk_tree_view_column_set_fixed_width(c, 160);
	gtk_tree_view_column_set_min_width(c, 120);
	gtk_tree_view_column_set_expand(c, TRUE);
	gtk_tree_view_column_set_resizable(c, TRUE);
	gtk_tree_view_append_column(GTK_TREE_VIEW(g_view), c);

	r = gtk_cell_renderer_text_new();
	g_object_set(r, "xalign", 1.0f, "ypad", 4, NULL);
	c = gtk_tree_view_column_new_with_attributes("大小", r, "text", C_SIZE,
						     NULL);
	gtk_tree_view_column_set_sizing(c, GTK_TREE_VIEW_COLUMN_FIXED);
	gtk_tree_view_column_set_fixed_width(c, 100);
	gtk_tree_view_column_set_resizable(c, TRUE);
	gtk_tree_view_append_column(GTK_TREE_VIEW(g_view), c);

	r = gtk_cell_renderer_text_new();
	g_object_set(r, "ypad", 4, NULL);
	c = gtk_tree_view_column_new_with_attributes("修改时间", r, "text",
						     C_TIME, NULL);
	gtk_tree_view_column_set_sizing(c, GTK_TREE_VIEW_COLUMN_FIXED);
	gtk_tree_view_column_set_fixed_width(c, 150);
	gtk_tree_view_column_set_resizable(c, TRUE);
	gtk_tree_view_append_column(GTK_TREE_VIEW(g_view), c);

	r = gtk_cell_renderer_text_new();
	g_object_set(r, "ypad", 4, NULL);
	c = gtk_tree_view_column_new_with_attributes("类型", r, "text", C_TYPE,
						     NULL);
	gtk_tree_view_column_set_sizing(c, GTK_TREE_VIEW_COLUMN_FIXED);
	gtk_tree_view_column_set_fixed_width(c, 110);
	gtk_tree_view_column_set_resizable(c, TRUE);
	gtk_tree_view_append_column(GTK_TREE_VIEW(g_view), c);

	sel = gtk_tree_view_get_selection(GTK_TREE_VIEW(g_view));
	g_signal_connect(sel, "changed", G_CALLBACK(on_selection_changed), NULL);
	g_signal_connect(g_view, "row-activated", G_CALLBACK(on_row_activated),
			 NULL);

	scroll = gtk_scrolled_window_new(NULL, NULL);
	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
				       GTK_POLICY_AUTOMATIC,
				       GTK_POLICY_AUTOMATIC);
	gtk_container_add(GTK_CONTAINER(scroll), g_view);
	gtk_box_pack_start(GTK_BOX(outer), scroll, TRUE, TRUE, 0);

	g_status = gtk_label_new("正在读取…");
	gtk_style_context_add_class(gtk_widget_get_style_context(g_status),
				    "status");
	gtk_widget_set_halign(g_status, GTK_ALIGN_START);
	gtk_widget_set_margin_start(g_status, UI_SP_3);
	gtk_widget_set_margin_bottom(g_status, UI_SP_2);
	gtk_box_pack_start(GTK_BOX(outer), g_status, FALSE, FALSE, 0);

	g_signal_connect(g_window, "key-press-event", G_CALLBACK(on_key_press),
			 NULL);

	reload();
	gtk_widget_show_all(g_window);
	gtk_main();
	return 0;
}
