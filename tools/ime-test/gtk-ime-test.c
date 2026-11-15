/*
 * gtk-ime-test — 验证 GTK3 应用的输入法链路（浏览器同一条路径）。
 *
 * 为什么单独做：foot 走 text-input-v3，GTK 应用走 fcitx5-gtk immodule +
 * 会话 D-Bus + 客户端候选窗。shui-browser 基于 WebKitGTK/GTK3，只要这里
 * 能出中文，浏览器里就能出中文。
 *
 * 用法：gtk-ime-test [输出文件]（默认 /tmp/gtk-ime.txt）
 * 窗口里一个 GtkEntry 自动获得焦点；回车把提交后的文本写文件并退出。
 */
#include <stdio.h>
#include <string.h>
#include <gtk/gtk.h>

static GtkWidget *entry;
static const char *out_path = "/tmp/gtk-ime.txt";

static void
on_activate(GtkWidget *widget, gpointer data)
{
	const char *text = gtk_entry_get_text(GTK_ENTRY(widget));
	FILE *f;

	(void)data;
	f = fopen(out_path, "wb");
	if (f) {
		fwrite(text, 1, strlen(text), f);
		fclose(f);
	}
	g_print("GTK entry committed: %s\n", text);
	gtk_main_quit();
}

static void
probe_immodule(void)
{
	GtkIMContext *ctx = gtk_im_multicontext_new();
	const char *id = gtk_im_multicontext_get_context_id(
		GTK_IM_MULTICONTEXT(ctx));

	g_print("GTK_IM_MODULE=%s\n", g_getenv("GTK_IM_MODULE") ?: "(unset)");
	g_print("GTK_IM_MODULE_FILE=%s\n",
	        g_getenv("GTK_IM_MODULE_FILE") ?: "(unset)");
	g_print("resolved multicontext id: %s\n", id);
	g_object_unref(ctx);
}

int
main(int argc, char **argv)
{
	GtkWidget *win;

	if (argc > 1)
		out_path = argv[1];
	gtk_init(&argc, &argv);
	probe_immodule();

	win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_title(GTK_WINDOW(win), "shuios IME test");
	gtk_window_set_default_size(GTK_WINDOW(win), 480, 140);
	g_signal_connect(win, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	entry = gtk_entry_new();
	gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "type here");
	gtk_container_add(GTK_CONTAINER(win), entry);
	g_signal_connect(entry, "activate", G_CALLBACK(on_activate), NULL);

	gtk_widget_show_all(win);
	gtk_widget_grab_focus(entry);
	gtk_main();
	return 0;
}
