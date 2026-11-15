/*
 * shuios 设置中心（shui-settings）
 *
 * P0 MVP：网络、声音、AI 助手与系统信息。
 *
 *   * 网络页：有线/无线状态、Wi-Fi 开关、扫描列表、点选连接；
 *     WPA2/WPA3 弹密码框，连接配置直接写成 NM keyfile（0600），
 *     密码不进 argv、也不依赖 nmtui；
 *   * 声音页：默认输出设备、音量滑杆、静音开关、测试音；
 *     后端调用 WirePlumber 的 wpctl（PipeWire 会话管理器）；
 *   * AI 页：提供商预设、端点/模型、API 密钥与连通性测试；
 *     密钥经 0600 临时文件交给 shui-ctl（不进 argv），由 shuiosd
 *     写入 /var/lib/shuios/state/ai.json；所有推理请求都由守护进程发出；
 *   * 关于页：发行版、内核、主机名、内存、运行时间。
 *
 * 后端一律调用镜像自带的 nmcli（NetworkManager 1.50）。所有命令都走
 * argv 数组，不经过 shell；动态文本（SSID）只写进 keyfile，不作为
 * 命令行参数拼接。
 *
 * 视觉 token 取自 shuios-ui.h（唯一色源，见 docs/06-视觉规范.md）。
 */

#include <errno.h>
#include <fcntl.h>
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <string.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

#include "shuios-ui.h"

#define NMCLI "/usr/bin/nmcli"
#define NM_DIR "/etc/NetworkManager/system-connections"
#define WPCTL "/usr/bin/wpctl"
#define SINK "@DEFAULT_AUDIO_SINK@"
#define SHUI_CTL "/usr/bin/shui-ctl"

typedef struct {
	const gchar *id;
	const gchar *name;
	const gchar *endpoint;
	const gchar *model;
	gboolean local;
} AiPreset;

/* 与 shuios-proto::ai::AI_PROVIDERS 保持一致。 */
static const AiPreset ai_presets[] = {
	{ "local", "本地模型（llama.cpp）", "http://127.0.0.1:8080", "local", TRUE },
	{ "deepseek", "DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat", FALSE },
	{ "qwen", "通义千问（DashScope）",
	  "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus", FALSE },
	{ "moonshot", "Moonshot（Kimi）", "https://api.moonshot.cn/v1",
	  "moonshot-v1-8k", FALSE },
	{ "openai", "OpenAI", "https://api.openai.com/v1", "gpt-4o-mini", FALSE },
	{ "custom", "自定义（OpenAI 兼容）", "", "", FALSE },
};

typedef struct {
	gchar *ssid;
	gchar *security;
	gchar *chan;
	gint signal;
	gboolean in_use;
} Ap;

typedef struct {
	GPtrArray *aps;
	gchar *error;
} ScanRes;

typedef struct {
	gchar *wired;
	gchar *wifi;
	gboolean radio_on;
	gboolean present;
} StatusRes;

typedef struct {
	gchar *ssid;
	gchar *psk;
	gboolean sae;
} ConnectReq;

typedef struct {
	gboolean ok;
	gchar *msg;
} ConnectRes;

typedef struct {
	gchar *path;
	gchar *uuid;
	gboolean has_psk;
} Profile;

static GtkWidget *g_window;
static GtkWidget *g_list;
static GtkWidget *g_status;
static GtkWidget *g_refresh_btn;
static GtkWidget *g_wifi_switch;
static GtkLabel *g_wired_label;
static GtkLabel *g_wifi_label;
static gchar *g_ifname;
static gboolean g_scanning;
static gboolean g_connecting;
static gboolean g_updating_switch;

static GtkWidget *g_stack;
static GtkWidget *g_sound_page;
static GtkLabel *g_sink_label;
static GtkLabel *g_audio_label;
static GtkWidget *g_vol_label;
static GtkWidget *g_sound_note;
static GtkRange *g_vol_scale;
static GtkSwitch *g_mute_switch;
static gboolean g_sound_updating;
static gint g_pending_volume;
static guint g_vol_apply_timer;

static GtkWidget *g_ai_page;
static GtkLabel *g_ai_state_label;
static GtkLabel *g_ai_key_label;
static GtkLabel *g_ai_result_label;
static GtkComboBoxText *g_ai_provider;
static GtkEntry *g_ai_endpoint;
static GtkEntry *g_ai_model;
static GtkEntry *g_ai_key;
static GtkWidget *g_ai_save;
static GtkWidget *g_ai_test;
static GtkWidget *g_ai_clear;
static gboolean g_ai_busy;
static gboolean g_ai_updating;
static gboolean g_ai_key_set;
static gboolean g_ai_daemon_ok;

/* ---------------------------------------------------------------- 工具 */

static gchar *
last_line(const gchar *s)
{
	if (!s)
		return g_strdup("");
	gchar **lines = g_strsplit(s, "\n", -1);
	gchar *ret = g_strdup("");
	for (int i = 0; lines[i]; i++) {
		gchar *t = g_strstrip(lines[i]);
		if (*t) {
			g_free(ret);
			ret = g_strdup(t);
		}
	}
	g_strfreev(lines);
	return ret;
}

static gboolean
run_cmd(const gchar *const *argv, gchar **out, gchar **err, gint *code)
{
	gchar *o = NULL, *e = NULL;
	gint st = 0;
	gboolean ok = g_spawn_sync(NULL, (gchar **)argv, NULL,
				   G_SPAWN_SEARCH_PATH, NULL, NULL, &o, &e,
				   &st, NULL);
	if (out)
		*out = o;
	else
		g_free(o);
	if (err)
		*err = e;
	else
		g_free(e);
	if (code)
		*code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
	return ok;
}

/* nmcli -t 的转义：字段里的 ':' 和 '\' 前有反斜杠。 */
static GPtrArray *
split_terse(const gchar *line)
{
	GPtrArray *f = g_ptr_array_new_with_free_func(g_free);
	GString *cur = g_string_new(NULL);

	for (const gchar *p = line; *p; p++) {
		if (*p == '\\' && p[1]) {
			g_string_append_c(cur, p[1]);
			p++;
		} else if (*p == ':') {
			g_ptr_array_add(f, g_strdup(cur->str));
			g_string_truncate(cur, 0);
		} else {
			g_string_append_c(cur, *p);
		}
	}
	g_ptr_array_add(f, g_strdup(cur->str));
	g_string_free(cur, TRUE);
	return f;
}

static void
ap_free(Ap *a)
{
	if (!a)
		return;
	g_free(a->ssid);
	g_free(a->security);
	g_free(a->chan);
	g_free(a);
}

static gint
ap_cmp(gconstpointer p1, gconstpointer p2)
{
	const Ap *a = *(Ap *const *)p1;
	const Ap *b = *(Ap *const *)p2;

	if (a->in_use != b->in_use)
		return a->in_use ? -1 : 1;
	return b->signal - a->signal;
}

static const gchar *
signal_icon(int sig)
{
	if (sig >= 80)
		return "network-wireless-signal-excellent";
	if (sig >= 60)
		return "network-wireless-signal-good";
	if (sig >= 40)
		return "network-wireless-signal-ok";
	if (sig >= 20)
		return "network-wireless-signal-weak";
	return "network-wireless-signal-none";
}

static gboolean
wifi_security_is_open(const gchar *sec)
{
	return !sec || !*sec || strcmp(sec, "--") == 0;
}

static gboolean
wifi_security_is_sae(const gchar *sec)
{
	return sec && strstr(sec, "WPA3") && !strstr(sec, "WPA2");
}

/* ---------------------------------------------------------------- 配置 */

static Profile *
find_profile(const gchar *ssid)
{
	GDir *d = g_dir_open(NM_DIR, 0, NULL);
	if (!d)
		return NULL;

	const gchar *name;
	Profile *found = NULL;
	while (!found && (name = g_dir_read_name(d))) {
		if (!g_str_has_suffix(name, ".nmconnection"))
			continue;
		gchar *path = g_build_filename(NM_DIR, name, NULL);
		GKeyFile *kf = g_key_file_new();
		if (g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, NULL)) {
			gchar *type = g_key_file_get_string(kf, "connection",
							    "type", NULL);
			gchar *ssidv = g_key_file_get_string(kf, "wifi",
							     "ssid", NULL);
			if (type && ssidv && strcmp(ssidv, ssid) == 0 &&
			    (strcmp(type, "wifi") == 0 ||
			     strcmp(type, "802-11-wireless") == 0)) {
				gchar *uuid = g_key_file_get_string(
					kf, "connection", "uuid", NULL);
				gchar *psk = g_key_file_get_string(
					kf, "wifi-security", "psk", NULL);
				if (uuid) {
					found = g_new0(Profile, 1);
					found->path = g_strdup(path);
					found->uuid = uuid;
					found->has_psk = psk && *psk;
				}
				g_free(psk);
			}
			g_free(type);
			g_free(ssidv);
		}
		g_key_file_free(kf);
		g_free(path);
	}
	g_dir_close(d);
	return found;
}

static void
profile_free(Profile *p)
{
	if (!p)
		return;
	g_free(p->path);
	g_free(p->uuid);
	g_free(p);
}

/* 0600 临时文件 + rename：密码在写入过程中不会短暂暴露给其他用户。 */
static gboolean
write_private(const gchar *path, const gchar *data)
{
	gchar *tmp = g_strdup_printf("%s.tmpXXXXXX", path);
	gboolean ok = FALSE;
	int fd = g_mkstemp_full(tmp, O_WRONLY | O_CREAT, 0600);

	if (fd >= 0) {
		gsize len = strlen(data);
		gsize off = 0;
		while (off < len) {
			gssize n = write(fd, data + off, len - off);
			if (n <= 0) {
				if (errno == EINTR)
					continue;
				break;
			}
			off += n;
		}
		close(fd);
		if (off == len && g_rename(tmp, path) == 0) {
			g_chmod(path, 0600);
			ok = TRUE;
		} else {
			g_unlink(tmp);
		}
	}
	g_free(tmp);
	return ok;
}

static gchar *
write_profile(const gchar *ssid, const gchar *psk, const gchar *ifname,
	      gboolean sae)
{
	GKeyFile *kf = g_key_file_new();
	gchar *uuid = g_uuid_string_random();
	gchar *name = NULL, *path = NULL, *data = NULL;

	g_key_file_set_string(kf, "connection", "id", ssid);
	g_key_file_set_string(kf, "connection", "uuid", uuid);
	g_key_file_set_string(kf, "connection", "type", "wifi");
	g_key_file_set_string(kf, "connection", "interface-name", ifname);
	g_key_file_set_boolean(kf, "connection", "autoconnect", TRUE);
	g_key_file_set_string(kf, "wifi", "mode", "infrastructure");
	g_key_file_set_string(kf, "wifi", "ssid", ssid);
	if (psk && *psk) {
		g_key_file_set_string(kf, "wifi-security", "key-mgmt",
				      sae ? "sae" : "wpa-psk");
		g_key_file_set_string(kf, "wifi-security", "psk", psk);
	}
	g_key_file_set_string(kf, "ipv4", "method", "auto");
	g_key_file_set_string(kf, "ipv6", "method", "auto");

	data = g_key_file_to_data(kf, NULL, NULL);
	name = g_strdup_printf("shui-settings-%08x.nmconnection",
			       g_str_hash(ssid));
	path = g_build_filename(NM_DIR, name, NULL);
	if (!write_private(path, data)) {
		g_free(path);
		path = NULL;
	}
	g_free(name);
	g_free(data);
	g_free(uuid);
	g_key_file_free(kf);
	return path;
}

static gboolean
profile_set_psk(Profile *p, const gchar *psk, gboolean sae)
{
	GKeyFile *kf = g_key_file_new();
	gchar *data = NULL;
	gboolean ok = FALSE;

	if (!g_key_file_load_from_file(kf, p->path, G_KEY_FILE_NONE, NULL))
		goto out;
	g_key_file_set_string(kf, "wifi-security", "key-mgmt",
			      sae ? "sae" : "wpa-psk");
	g_key_file_set_string(kf, "wifi-security", "psk", psk);
	data = g_key_file_to_data(kf, NULL, NULL);
	ok = write_private(p->path, data);
out:
	g_free(data);
	g_key_file_free(kf);
	return ok;
}

/* ---------------------------------------------------------------- 网络 */

static gboolean
scan_done(gpointer data)
{
	ScanRes *r = data;
	g_scanning = FALSE;
	gtk_widget_set_sensitive(g_refresh_btn, TRUE);

	GList *rows = gtk_container_get_children(GTK_CONTAINER(g_list));
	for (GList *it = rows; it; it = it->next)
		gtk_widget_destroy(GTK_WIDGET(it->data));
	g_list_free(rows);

	if (r->error) {
		GtkWidget *row = gtk_list_box_row_new();
		GtkWidget *l = gtk_label_new(r->error);
		gtk_label_set_xalign(GTK_LABEL(l), 0);
		gtk_widget_set_margin_start(l, UI_SP_3);
		gtk_widget_set_margin_end(l, UI_SP_3);
		gtk_widget_set_margin_top(l, UI_SP_3);
		gtk_widget_set_margin_bottom(l, UI_SP_3);
		gtk_container_add(GTK_CONTAINER(row), l);
		gtk_list_box_insert(GTK_LIST_BOX(g_list), row, -1);
		gtk_widget_show_all(g_list);
		g_free(r->error);
		g_ptr_array_free(r->aps, TRUE);
		g_free(r);
		return G_SOURCE_REMOVE;
	}

	for (guint i = 0; i < r->aps->len; i++) {
		Ap *a = g_ptr_array_index(r->aps, i);
		GtkWidget *row = gtk_list_box_row_new();
		GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_3);
		GtkWidget *icon = gtk_image_new_from_icon_name(
			signal_icon(a->signal), GTK_ICON_SIZE_LARGE_TOOLBAR);
		GtkWidget *v = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
		GtkWidget *ssid = gtk_label_new(a->ssid);
		GString *sub = g_string_new(NULL);
		GtkWidget *sub_l = NULL;
		GtkWidget *right = gtk_label_new(a->in_use ? "已连接" : "");
		Ap *copy = g_new0(Ap, 1);

		copy->ssid = g_strdup(a->ssid);
		copy->security = g_strdup(a->security);
		copy->chan = g_strdup(a->chan);
		copy->signal = a->signal;
		copy->in_use = a->in_use;
		g_object_set_data_full(G_OBJECT(row), "ap", copy,
				       (GDestroyNotify)ap_free);

		if (wifi_security_is_open(a->security))
			g_string_append(sub, "开放网络");
		else
			g_string_append(sub, a->security);
		if (a->chan && *a->chan && strcmp(a->chan, "--") != 0)
			g_string_append_printf(sub, " · 信道 %s", a->chan);
		g_string_append_printf(sub, " · %d%%", a->signal);
		if (a->in_use)
			g_string_append(sub, " · 点击断开");
		sub_l = gtk_label_new(sub->str);
		g_string_free(sub, TRUE);

		gtk_label_set_xalign(GTK_LABEL(ssid), 0);
		gtk_label_set_xalign(GTK_LABEL(sub_l), 0);
		gtk_label_set_xalign(GTK_LABEL(right), 1);
		gtk_style_context_add_class(gtk_widget_get_style_context(ssid),
					    "ap-ssid");
		gtk_style_context_add_class(gtk_widget_get_style_context(sub_l),
					    "dim");
		if (a->in_use)
			gtk_style_context_add_class(
				gtk_widget_get_style_context(right), "accent");
		gtk_box_pack_start(GTK_BOX(v), ssid, FALSE, FALSE, 0);
		gtk_box_pack_start(GTK_BOX(v), sub_l, FALSE, FALSE, 0);
		gtk_box_pack_start(GTK_BOX(box), icon, FALSE, FALSE, 0);
		gtk_box_pack_start(GTK_BOX(box), v, TRUE, TRUE, 0);
		gtk_box_pack_start(GTK_BOX(box), right, FALSE, FALSE, 0);
		gtk_widget_set_margin_start(box, UI_SP_3);
		gtk_widget_set_margin_end(box, UI_SP_3);
		gtk_widget_set_margin_top(box, UI_SP_2);
		gtk_widget_set_margin_bottom(box, UI_SP_2);
		gtk_container_add(GTK_CONTAINER(row), box);
		gtk_list_box_insert(GTK_LIST_BOX(g_list), row, -1);
	}
	gtk_widget_show_all(g_list);

	/* 只有“正在扫描”的提示才换成结果数；不要覆盖连接结果/断开提示。 */
	const gchar *cur = gtk_label_get_text(GTK_LABEL(g_status));
	if (g_str_has_prefix(cur, "正在扫描")) {
		gchar *msg = g_strdup_printf("找到 %u 个网络", r->aps->len);
		gtk_label_set_text(GTK_LABEL(g_status), msg);
		g_free(msg);
	}
	g_ptr_array_free(r->aps, TRUE);
	g_free(r);
	return G_SOURCE_REMOVE;
}

static gpointer
scan_thread(gpointer data)
{
	(void)data;
	ScanRes *r = g_new0(ScanRes, 1);
	r->aps = g_ptr_array_new_with_free_func((GDestroyNotify)ap_free);

	if (!g_ifname) {
		r->error = g_strdup("未检测到无线网卡");
		g_idle_add((GSourceFunc)scan_done, r);
		return NULL;
	}

	const gchar *argv[] = { NMCLI, "-t", "-f",
				"IN-USE,SSID,SIGNAL,SECURITY,CHAN",
				"device", "wifi", "list", "--rescan", "yes",
				"ifname", g_ifname, NULL };
	gchar *out = NULL, *err = NULL;
	gint code = 0;
	if (!run_cmd(argv, &out, &err, &code) || code != 0) {
		gchar *e = last_line(err);
		r->error = g_strdup_printf("扫描失败：%s", *e ? e : "nmcli 不可用");
		g_free(e);
	} else {
		gchar **lines = g_strsplit(out, "\n", -1);
		for (int i = 0; lines[i]; i++) {
			gchar *line = g_strstrip(lines[i]);
			if (!*line)
				continue;
			GPtrArray *f = split_terse(line);
			if (f->len >= 5) {
				const gchar *inuse = g_ptr_array_index(f, 0);
				const gchar *ssid = g_ptr_array_index(f, 1);
				if (*ssid) {
					Ap *a = g_new0(Ap, 1);
					a->in_use = *inuse == '*';
					a->ssid = g_strdup(ssid);
					a->signal = atoi(g_ptr_array_index(f, 2));
					a->security = g_strdup(g_ptr_array_index(f, 3));
					a->chan = g_strdup(g_ptr_array_index(f, 4));
					g_ptr_array_add(r->aps, a);
				}
			}
			g_ptr_array_free(f, TRUE);
		}
		g_strfreev(lines);
	}
	g_free(out);
	g_free(err);

	/* 已连接优先，其余按信号强度降序 */
	g_ptr_array_sort(r->aps, ap_cmp);

	g_idle_add((GSourceFunc)scan_done, r);
	return NULL;
}

static gboolean
status_done(gpointer data)
{
	StatusRes *r = data;

	if (!r->wired)
		gtk_label_set_text(g_wired_label, "未检测到有线网卡");
	else
		gtk_label_set_text(g_wired_label, r->wired);
	gtk_label_set_text(g_wifi_label, r->present ? r->wifi : "未检测到无线网卡");

	g_updating_switch = TRUE;
	gtk_switch_set_active(GTK_SWITCH(g_wifi_switch), r->radio_on);
	g_updating_switch = FALSE;
	gtk_widget_set_sensitive(g_wifi_switch, r->present);
	gtk_widget_set_sensitive(g_refresh_btn, r->present && !g_scanning);

	g_free(r->wired);
	g_free(r->wifi);
	g_free(r);
	return G_SOURCE_REMOVE;
}

static gpointer
status_thread(gpointer data)
{
	(void)data;
	StatusRes *r = g_new0(StatusRes, 1);
	const gchar *dev_argv[] = { NMCLI, "-t", "-f",
				    "DEVICE,TYPE,STATE,CONNECTION",
				    "device", "status", NULL };
	gchar *out = NULL, *err = NULL;
	gint code = 0;
	gchar *wdev = NULL, *edev = NULL;

	if (run_cmd(dev_argv, &out, &err, &code) && code == 0) {
		gchar **lines = g_strsplit(out, "\n", -1);
		for (int i = 0; lines[i]; i++) {
			GPtrArray *f = split_terse(g_strstrip(lines[i]));
			if (f->len >= 4) {
				const gchar *dev = g_ptr_array_index(f, 0);
				const gchar *type = g_ptr_array_index(f, 1);
				if (!wdev && strcmp(type, "wifi") == 0)
					wdev = g_strdup(dev);
				if (!edev && strcmp(type, "ethernet") == 0)
					edev = g_strdup(dev);
			}
			g_ptr_array_free(f, TRUE);
		}
		g_strfreev(lines);
	}
	g_free(out);
	g_free(err);

	if (!g_ifname && wdev)
		g_ifname = g_strdup(wdev);

	gchar *wifi_desc = g_strdup("未连接");
	if (wdev) {
		const gchar *argv[] = { NMCLI, "-t", "-f",
					"GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS",
					"device", "show", wdev, NULL };
		gchar *o = NULL, *e = NULL;
		if (run_cmd(argv, &o, &e, &code) && code == 0) {
			gchar *state = NULL, *conn = NULL, *ip = NULL;
			gchar **lines = g_strsplit(o, "\n", -1);
			for (int i = 0; lines[i]; i++) {
				gchar *line = g_strstrip(lines[i]);
				if (g_str_has_prefix(line, "GENERAL.STATE:"))
					state = g_strdup(line + 14);
				else if (g_str_has_prefix(line,
							  "GENERAL.CONNECTION:"))
					conn = g_strdup(line + 19);
				else if (!ip && g_str_has_prefix(
						       line, "IP4.ADDRESS[1]:"))
					ip = g_strdup(line + 16);
			}
			gchar *st = last_line(state);
			if (g_str_has_prefix(st, "100") || g_str_has_prefix(st, "connected")) {
				g_free(wifi_desc);
				if (conn && *conn) {
					wifi_desc = ip && *ip
						? g_strdup_printf("%s · %s", conn, ip)
						: g_strdup(conn);
				} else {
					wifi_desc = g_strdup("已连接");
				}
			} else if (g_str_has_prefix(st, "30") ||
				   g_strstr_len(st, -1, "disconnected")) {
				g_free(wifi_desc);
				wifi_desc = g_strdup("未连接");
			} else {
				g_free(wifi_desc);
				wifi_desc = g_strdup("无线不可用");
			}
			g_free(st);
			g_free(state);
			g_free(conn);
			g_free(ip);
			g_strfreev(lines);
		}
		g_free(o);
		g_free(e);
	}
	if (!wdev) {
		g_free(wifi_desc);
		wifi_desc = g_strdup("未检测到无线网卡");
	}

	gchar *wired_desc = NULL;
	if (edev) {
		const gchar *argv[] = { NMCLI, "-t", "-f",
					"GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS",
					"device", "show", edev, NULL };
		gchar *o = NULL, *e = NULL;
		gchar *conn = NULL, *ip = NULL;
		if (run_cmd(argv, &o, &e, &code) && code == 0) {
			gchar **lines = g_strsplit(o, "\n", -1);
			for (int i = 0; lines[i]; i++) {
				gchar *line = g_strstrip(lines[i]);
				if (g_str_has_prefix(line, "GENERAL.CONNECTION:"))
					conn = g_strdup(line + 19);
				else if (!ip && g_str_has_prefix(
						       line, "IP4.ADDRESS[1]:"))
					ip = g_strdup(line + 16);
			}
			g_strfreev(lines);
		}
		g_free(o);
		g_free(e);
		if (conn && *conn)
			wired_desc = ip && *ip
				? g_strdup_printf("%s · %s", conn, ip)
				: g_strdup(conn);
		else
			wired_desc = g_strdup("未连接");
		g_free(conn);
		g_free(ip);
	}

	const gchar *radio_argv[] = { NMCLI, "-t", "-f", "WIFI",
				      "general", NULL };
	gchar *ro = NULL, *re = NULL;
	r->radio_on = TRUE;
	if (run_cmd(radio_argv, &ro, &re, &code) && code == 0)
		r->radio_on = strstr(ro, "enabled") != NULL;
	g_free(ro);
	g_free(re);

	r->present = wdev != NULL;
	r->wifi = wifi_desc;
	r->wired = wired_desc;
	g_free(wdev);
	g_free(edev);
	g_idle_add((GSourceFunc)status_done, r);
	return NULL;
}

/* ---------------------------------------------------------------- 连接 */

static gboolean
connect_done(gpointer data)
{
	ConnectRes *r = data;
	g_connecting = FALSE;
	gtk_label_set_text(GTK_LABEL(g_status), r->msg);
	g_free(r->msg);
	g_free(r);

	g_thread_new("settings-status", status_thread, NULL);
	g_thread_new("settings-scan", scan_thread, NULL);
	return G_SOURCE_REMOVE;
}

static gpointer
connect_thread(gpointer data)
{
	ConnectReq *req = data;
	ConnectRes *res = g_new0(ConnectRes, 1);
	Profile *p = find_profile(req->ssid);
	gchar *uuid = NULL;

	if (p) {
		if (req->psk && *req->psk && !p->has_psk &&
		    !profile_set_psk(p, req->psk, req->sae)) {
			res->msg = g_strdup("无法保存 Wi-Fi 密码（数据分区不可写）");
			goto out;
		}
		uuid = g_strdup(p->uuid);
	} else {
		gchar *path = write_profile(req->ssid, req->psk, g_ifname,
					    req->sae);
		if (!path) {
			res->msg = g_strdup("无法写入连接配置（数据分区不可写）");
			goto out;
		}
		g_free(path);
		Profile *np = find_profile(req->ssid);
		if (np) {
			uuid = g_strdup(np->uuid);
			profile_free(np);
		}
	}

	if (!uuid) {
		res->msg = g_strdup("找不到连接配置");
		goto out;
	}

	const gchar *reload_argv[] = { NMCLI, "connection", "reload", NULL };
	run_cmd(reload_argv, NULL, NULL, NULL);
	g_usleep(200 * 1000);

	const gchar *up_argv[] = { NMCLI, "connection", "up", "uuid", uuid,
				   NULL };
	gchar *o = NULL, *e = NULL;
	gint code = 0;
	gboolean ok = run_cmd(up_argv, &o, &e, &code) && code == 0;
	if (ok) {
		res->ok = TRUE;
		res->msg = g_strdup_printf("已连接到 %s", req->ssid);
	} else {
		gchar *el = last_line(e);
		res->msg = g_strdup_printf("连接失败：%s",
					   *el ? el : "请检查密码后重试");
		g_free(el);
	}
	g_free(o);
	g_free(e);
	g_free(uuid);
out:
	if (p)
		profile_free(p);
	g_free(req->ssid);
	g_free(req->psk);
	g_free(req);
	g_idle_add((GSourceFunc)connect_done, res);
	return NULL;
}

static void
start_connect(const gchar *ssid, const gchar *psk, const gchar *security)
{
	if (g_connecting)
		return;
	if (!g_ifname) {
		gtk_label_set_text(GTK_LABEL(g_status), "没有可用的无线网卡");
		return;
	}
	ConnectReq *req = g_new0(ConnectReq, 1);
	req->ssid = g_strdup(ssid);
	req->psk = psk ? g_strdup(psk) : NULL;
	req->sae = wifi_security_is_sae(security);
	g_connecting = TRUE;
	gchar *msg = g_strdup_printf("正在连接 %s…", ssid);
	gtk_label_set_text(GTK_LABEL(g_status), msg);
	g_free(msg);
	g_thread_new("settings-connect", connect_thread, req);
}

static void
on_password_toggle(GtkToggleButton *b, gpointer data)
{
	gtk_entry_set_visibility(GTK_ENTRY(data),
				 gtk_toggle_button_get_active(b));
}

static gchar *
ask_password(GtkWindow *parent, const gchar *ssid)
{
	GtkWidget *dlg = gtk_dialog_new_with_buttons(
		"连接到 Wi-Fi", parent,
		GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
		"取消", GTK_RESPONSE_CANCEL, "连接", GTK_RESPONSE_ACCEPT, NULL);
	GtkWidget *area = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
	GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_2);
	GtkWidget *title = gtk_label_new(NULL);
	gchar *markup = g_markup_printf_escaped(
		"输入「%s」的密码", ssid);
	GtkWidget *entry = gtk_entry_new();
	GtkWidget *show = gtk_check_button_new_with_label("显示密码");
	gchar *psk = NULL;

	gtk_label_set_markup(GTK_LABEL(title), markup);
	g_free(markup);
	gtk_label_set_xalign(GTK_LABEL(title), 0);
	gtk_entry_set_visibility(GTK_ENTRY(entry), FALSE);
	gtk_entry_set_input_purpose(GTK_ENTRY(entry), GTK_INPUT_PURPOSE_PASSWORD);
	gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
	gtk_dialog_set_default_response(GTK_DIALOG(dlg), GTK_RESPONSE_ACCEPT);
	g_signal_connect(show, "toggled", G_CALLBACK(on_password_toggle), entry);

	gtk_widget_set_margin_start(box, UI_SP_4);
	gtk_widget_set_margin_end(box, UI_SP_4);
	gtk_widget_set_margin_top(box, UI_SP_2);
	gtk_widget_set_margin_bottom(box, UI_SP_2);
	gtk_box_pack_start(GTK_BOX(box), title, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(box), show, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(area), box);
	gtk_widget_show_all(dlg);
	gtk_widget_grab_focus(entry);

	for (;;) {
		gint resp = gtk_dialog_run(GTK_DIALOG(dlg));
		if (resp != GTK_RESPONSE_ACCEPT)
			break;
		const gchar *text = gtk_entry_get_text(GTK_ENTRY(entry));
		if (text && *text) {
			psk = g_strdup(text);
			break;
		}
		gtk_label_set_text(GTK_LABEL(title), "密码不能为空，请重新输入");
	}
	gtk_widget_destroy(dlg);
	return psk;
}

static void
on_row_activated(GtkListBox *lb, GtkListBoxRow *row, gpointer data)
{
	(void)lb;
	(void)data;
	Ap *a = g_object_get_data(G_OBJECT(row), "ap");
	if (!a)
		return;

	if (a->security && strstr(a->security, "802.1X")) {
		gtk_label_set_text(GTK_LABEL(g_status),
				   "暂不支持企业级认证（802.1X）网络");
		return;
	}
	if (a->security && strstr(a->security, "WEP")) {
		gtk_label_set_text(GTK_LABEL(g_status),
				   "暂不支持 WEP 加密网络");
		return;
	}

	if (a->in_use) {
		const gchar *argv[] = { NMCLI, "device", "disconnect",
					g_ifname, NULL };
		gchar *o = NULL, *e = NULL;
		gint code = 0;
		gboolean ok = g_ifname &&
			run_cmd(argv, &o, &e, &code) && code == 0;
		g_free(o);
		g_free(e);
		gtk_label_set_text(GTK_LABEL(g_status),
				   ok ? "已断开 Wi-Fi" : "断开失败（没有活动连接）");
		g_thread_new("settings-status", status_thread, NULL);
		g_thread_new("settings-scan", scan_thread, NULL);
		return;
	}

	gchar *psk = NULL;
	if (!wifi_security_is_open(a->security)) {
		Profile *p = find_profile(a->ssid);
		gboolean has_secret = p && p->has_psk;
		profile_free(p);
		if (!has_secret) {
			psk = ask_password(GTK_WINDOW(g_window), a->ssid);
			if (!psk)
				return;
		}
	}
	start_connect(a->ssid, psk, a->security);
	g_free(psk);
}

/* ---------------------------------------------------------------- 界面 */

static void
install_css(void)
{
	const char *css =
		"window { background-image: none; background-color: "
		UI_HEX_BG_PANEL "; color: " UI_HEX_FG "; }\n"
		"headerbar { background-image: none; background-color: "
		UI_HEX_BG_PANEL "; color: " UI_HEX_FG "; border-bottom: 1px "
		"solid " UI_HEX_LINE "; padding: " UI_STR(UI_SP_1) "px;"
		"  box-shadow: none; }\n"
		"headerbar .title { font-weight: bold; font-size: "
		UI_STR(UI_FS_TITLE) "px; }\n"
		"headerbar button { background-image: none; background-color: "
		"transparent; border: none; color: " UI_HEX_FG_DIM "; }\n"
		"headerbar button:hover { background-color: " UI_HEX_BG_HOVER
		"; color: " UI_HEX_FG "; }\n"
		"button { background-image: none; background-color: "
		UI_HEX_BG_CARD "; color: " UI_HEX_FG "; border: 1px solid "
		UI_HEX_LINE "; border-radius: " UI_STR(UI_RADIUS) "px;"
		"  padding: " UI_STR(UI_SP_1) "px " UI_STR(UI_SP_3) "px;"
		"  box-shadow: none; text-shadow: none; }\n"
		"button:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		"entry { background-color: " UI_HEX_BG_CARD "; color: "
		UI_HEX_FG "; border-radius: " UI_STR(UI_RADIUS) "px;"
		"  border: 1px solid " UI_HEX_LINE "; padding: "
		UI_STR(UI_SP_1) "px " UI_STR(UI_SP_2) "px; }\n"
		"entry:focus { border-color: " UI_HEX_ACCENT "; }\n"
		"label.dim { color: " UI_HEX_FG_DIM "; font-size: "
		UI_STR(UI_FS_META) "px; }\n"
		"label.weak { color: " UI_HEX_FG_WEAK "; font-size: "
		UI_STR(UI_FS_META) "px; }\n"
		"label.accent { color: " UI_HEX_ACCENT "; font-size: "
		UI_STR(UI_FS_LABEL) "px; }\n"
		"label.page-title { font-size: 24px; font-weight: bold; }\n"
		"label.section { font-size: " UI_STR(UI_FS_TITLE) ";"
		"  font-weight: bold; }\n"
		"label.ap-ssid { font-size: " UI_STR(UI_FS_BODY) ";"
		"  font-weight: bold; }\n"
		".nav { background-color: " UI_HEX_BG_WINDOW ";"
		"  border-right: 1px solid " UI_HEX_LINE "; padding: "
		UI_STR(UI_SP_3) "px " UI_STR(UI_SP_2) "px; }\n"
		".nav row { border-radius: " UI_STR(UI_RADIUS) "px;"
		"  padding: " UI_STR(UI_SP_2) "px " UI_STR(UI_SP_3) "px; }\n"
		".nav row:hover { background-color: " UI_HEX_BG_HOVER "; }\n"
		".nav row:selected { background-color: " UI_HEX_ACCENT ";"
		"  color: " UI_HEX_ACCENT_ON "; }\n"
		".nav row:selected label { color: " UI_HEX_ACCENT_ON "; }\n"
		".card { background-color: " UI_HEX_BG_CARD ";"
		"  border: 1px solid " UI_HEX_LINE "; border-radius: "
		UI_STR(UI_RADIUS_CARD) "px; padding: " UI_STR(UI_SP_4) "px; }\n"
		".netlist { background-color: " UI_HEX_BG_WINDOW ";"
		"  border: 1px solid " UI_HEX_LINE "; border-radius: "
		UI_STR(UI_RADIUS_CARD) "px; }\n"
		".netlist row { border-bottom: 1px solid " UI_HEX_LINE
		"; background-color: transparent; }\n"
		".netlist row:last-child { border-bottom: none; }\n"
		".netlist row:hover { background-color: " UI_HEX_BG_HOVER
		"; }\n"
		".netlist row:selected { background-color: " UI_HEX_BG_HOVER
		"; }\n"
		"scrolledwindow { background-color: transparent; }\n"
		"scale trough { min-height: 6px; border-radius: 3px;"
		"  background-color: " UI_HEX_BG_WINDOW "; }\n"
		"scale highlight { background-color: " UI_HEX_ACCENT ";"
		"  border-radius: 3px; }\n"
		"scale slider { background-color: " UI_HEX_ACCENT_HI ";"
		"  border: 1px solid " UI_HEX_LINE "; min-width: 16px;"
		"  min-height: 16px; border-radius: 8px; }\n";

	GtkCssProvider *prov = gtk_css_provider_new();
	gtk_css_provider_load_from_data(prov, css, -1, NULL);
	gtk_style_context_add_provider_for_screen(
		gdk_screen_get_default(), GTK_STYLE_PROVIDER(prov),
		GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
	g_object_unref(prov);
}

static GtkWidget *
make_status_row(const gchar *title, GtkLabel **value)
{
	GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_3);
	GtkWidget *t = gtk_label_new(title);
	GtkWidget *v = gtk_label_new("读取中…");

	gtk_label_set_xalign(GTK_LABEL(t), 0);
	gtk_label_set_xalign(GTK_LABEL(v), 1);
	gtk_widget_set_hexpand(v, TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(t), "dim");
	gtk_box_pack_start(GTK_BOX(row), t, FALSE, FALSE, 0);
	gtk_box_pack_end(GTK_BOX(row), v, TRUE, TRUE, 0);
	*value = GTK_LABEL(v);
	return row;
}

static GtkWidget *
make_network_page(void)
{
	GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_4);
	GtkWidget *title = gtk_label_new("网络");
	GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_3);
	GtkWidget *wifi_head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL,
					   UI_SP_2);
	GtkWidget *wifi_title = gtk_label_new("无线网络");
	GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
	GtkWidget *hint = gtk_label_new(
		"点击网络连接；已连接的网络再次点击可断开。密码只保存在本机数据分区。");

	gtk_widget_set_margin_start(page, UI_SP_6);
	gtk_widget_set_margin_end(page, UI_SP_6);
	gtk_widget_set_margin_top(page, UI_SP_4);
	gtk_widget_set_margin_bottom(page, UI_SP_2);
	gtk_style_context_add_class(gtk_widget_get_style_context(title),
				    "page-title");
	gtk_label_set_xalign(GTK_LABEL(title), 0);
	gtk_box_pack_start(GTK_BOX(page), title, FALSE, FALSE, 0);

	gtk_style_context_add_class(gtk_widget_get_style_context(card), "card");
	gtk_box_pack_start(GTK_BOX(card),
			   make_status_row("有线网络", &g_wired_label),
			   FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(card),
			   make_status_row("无线网络", &g_wifi_label),
			   FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);

	gtk_label_set_xalign(GTK_LABEL(wifi_title), 0);
	gtk_style_context_add_class(gtk_widget_get_style_context(wifi_title),
				    "section");
	g_wifi_switch = gtk_switch_new();
	g_refresh_btn = gtk_button_new_with_label("重新扫描");
	gtk_box_pack_start(GTK_BOX(wifi_head), wifi_title, FALSE, FALSE, 0);
	gtk_box_pack_end(GTK_BOX(wifi_head), g_refresh_btn, FALSE, FALSE, 0);
	gtk_box_pack_end(GTK_BOX(wifi_head), g_wifi_switch, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), wifi_head, FALSE, FALSE, 0);

	g_list = gtk_list_box_new();
	gtk_list_box_set_selection_mode(GTK_LIST_BOX(g_list),
					GTK_SELECTION_NONE);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_list),
				    "netlist");
	gtk_container_add(GTK_CONTAINER(scroll), g_list);
	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
				       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	gtk_widget_set_vexpand(scroll, TRUE);
	gtk_box_pack_start(GTK_BOX(page), scroll, TRUE, TRUE, 0);

	gtk_label_set_xalign(GTK_LABEL(hint), 0);
	gtk_label_set_line_wrap(GTK_LABEL(hint), TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(hint), "weak");
	gtk_box_pack_start(GTK_BOX(page), hint, FALSE, FALSE, 0);
	return page;
}

/* ---------------------------------------------------------------- 声音 */

static gboolean
wpctl_get_volume(gint *pct, gboolean *muted)
{
	const gchar *argv[] = { WPCTL, "get-volume", SINK, NULL };
	gchar *out = NULL, *err = NULL;
	gint code = -1;
	gboolean ok = run_cmd(argv, &out, &err, &code);
	gboolean ret = FALSE;

	if (ok && code == 0 && out) {
		const gchar *colon = strchr(out, ':');
		if (colon) {
			gdouble v = g_strtod(colon + 1, NULL);
			if (v < 0.0)
				v = 0.0;
			if (v > 1.0)
				v = 1.0;
			*pct = (gint)(v * 100.0 + 0.5);
			*muted = strstr(out, "MUTED") != NULL;
			ret = TRUE;
		}
	}
	g_free(out);
	g_free(err);
	return ret;
}

/* 从 wpctl inspect 的一行里取引号内的值（node.description = "..."） */
static gchar *
quoted_value(const gchar *line, const gchar *key)
{
	if (!line || !strstr(line, key))
		return NULL;
	const gchar *q = strchr(line, '"');
	if (!q)
		return NULL;
	const gchar *end = strrchr(q + 1, '"');
	if (!end || end <= q + 1)
		return NULL;
	return g_strndup(q + 1, (gsize)(end - q - 1));
}

static gchar *
wpctl_sink_description(void)
{
	const gchar *argv[] = { WPCTL, "inspect", SINK, NULL };
	gchar *out = NULL, *err = NULL;
	gint code = -1;
	gchar *desc = NULL, *nick = NULL, *name = NULL;

	if (!run_cmd(argv, &out, &err, &code) || code != 0 || !out) {
		g_free(out);
		g_free(err);
		return NULL;
	}
	gchar **lines = g_strsplit(out, "\n", -1);
	for (int i = 0; lines[i]; i++) {
		gchar *v;
		if ((v = quoted_value(lines[i], "node.description"))) {
			g_free(desc);
			desc = v;
		} else if ((v = quoted_value(lines[i], "node.nick"))) {
			g_free(nick);
			nick = v;
		} else if ((v = quoted_value(lines[i], "node.name"))) {
			g_free(name);
			name = v;
		}
	}
	g_strfreev(lines);
	g_free(out);
	g_free(err);

	gchar *ret = desc && *desc ? desc : (nick && *nick ? nick : name);
	if (ret != desc)
		g_free(desc);
	if (ret != nick)
		g_free(nick);
	if (ret != name)
		g_free(name);
	return ret;
}

static void
sound_set_sensitive(gboolean on)
{
	gtk_widget_set_sensitive(GTK_WIDGET(g_vol_scale), on);
	gtk_widget_set_sensitive(GTK_WIDGET(g_mute_switch), on);
}

static void
sound_refresh(void)
{
	if (!g_sound_page)
		return;

	gint pct = 0;
	gboolean muted = FALSE;
	if (!wpctl_get_volume(&pct, &muted)) {
		gtk_label_set_text(GTK_LABEL(g_audio_label), "未运行");
		gtk_label_set_text(GTK_LABEL(g_sink_label), "没有默认输出设备");
		gtk_label_set_text(GTK_LABEL(g_vol_label), "—");
		sound_set_sensitive(FALSE);
		return;
	}
	sound_set_sensitive(TRUE);

	gchar *desc = wpctl_sink_description();
	gtk_label_set_text(GTK_LABEL(g_sink_label),
			   desc ? desc : "默认输出设备");
	g_free(desc);

	g_sound_updating = TRUE;
	gtk_range_set_value(g_vol_scale, pct);
	gtk_switch_set_active(g_mute_switch, muted);
	g_sound_updating = FALSE;

	gchar *txt = muted ? g_strdup_printf("%d%% · 已静音", pct)
			   : g_strdup_printf("%d%%", pct);
	gtk_label_set_text(GTK_LABEL(g_vol_label), txt);
	g_free(txt);
	gtk_label_set_text(GTK_LABEL(g_audio_label), "运行中");
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

static gboolean
sound_apply_volume(gpointer data)
{
	(void)data;
	g_vol_apply_timer = 0;
	gchar vol[16];
	g_snprintf(vol, sizeof vol, "%d%%", g_pending_volume);
	const gchar *argv[] = { WPCTL, "set-volume", SINK, vol, NULL };
	gchar *out = NULL, *err = NULL;
	gint code = -1;

	run_cmd(argv, &out, &err, &code);
	g_free(out);
	g_free(err);
	if (code != 0)
		gtk_label_set_text(GTK_LABEL(g_audio_label), "音量设置失败");
	else
		audio_state_save(g_pending_volume,
				 gtk_switch_get_active(g_mute_switch));
	return G_SOURCE_REMOVE;
}

static void
on_volume_changed(GtkRange *range, gpointer data)
{
	(void)data;
	if (g_sound_updating)
		return;
	g_pending_volume = (gint)(gtk_range_get_value(range) + 0.5);
	gchar *txt = g_strdup_printf("%d%%", g_pending_volume);
	gtk_label_set_text(GTK_LABEL(g_vol_label), txt);
	g_free(txt);
	gtk_label_set_text(GTK_LABEL(g_audio_label), "运行中");
	if (g_vol_apply_timer)
		g_source_remove(g_vol_apply_timer);
	g_vol_apply_timer = g_timeout_add(120, sound_apply_volume, NULL);
}

static void
on_mute_changed(GObject *obj, GParamSpec *pspec, gpointer data)
{
	(void)pspec;
	(void)data;
	if (g_sound_updating)
		return;
	gboolean muted = gtk_switch_get_active(GTK_SWITCH(obj));
	const gchar *argv[] = { WPCTL, "set-mute", SINK,
			       muted ? "1" : "0", NULL };
	gchar *out = NULL, *err = NULL;
	gint code = -1;

	run_cmd(argv, &out, &err, &code);
	g_free(out);
	g_free(err);
	if (code != 0) {
		gtk_label_set_text(GTK_LABEL(g_audio_label), "静音设置失败");
		return;
	}
	gint pct = (gint)(gtk_range_get_value(g_vol_scale) + 0.5);
	gchar *txt = muted ? g_strdup_printf("%d%% · 已静音", pct)
			   : g_strdup_printf("%d%%", pct);
	gtk_label_set_text(GTK_LABEL(g_vol_label), txt);
	g_free(txt);
	audio_state_save(pct, muted);
}

static void
on_test_sound(GtkButton *btn, gpointer data)
{
	(void)btn;
	(void)data;
	/* speaker-test 走 ALSA default → /etc/asound.conf → PipeWire，
	   同时验证 ALSA 兼容层和实际出声。
	   在 PipeWire 后端下 speaker-test -l 1 播完后会卡在 poll 不退出
	   （实测遗留进程和 sink-input），所以由 sh 计时 9 秒强制收尾。 */
	const gchar *argv[] = {
		"/bin/sh", "-c",
		"/usr/bin/speaker-test -D default -c 2 -t sine -f 440 -l 1 "
		">/dev/null 2>&1 & p=$!; sleep 9; kill $p 2>/dev/null",
		NULL
	};
	GError *err = NULL;
	if (!g_spawn_async(NULL, (gchar **)argv, NULL,
			   G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, &err)) {
		gtk_label_set_text(GTK_LABEL(g_sound_note), "无法启动测试音");
		g_clear_error(&err);
		return;
	}
	gtk_label_set_text(GTK_LABEL(g_sound_note),
			   "正在播放测试音（约 6 秒）…");
}

static gboolean
sound_tick(gpointer data)
{
	(void)data;
	if (g_sound_page && g_stack &&
	    gtk_stack_get_visible_child(GTK_STACK(g_stack)) == g_sound_page)
		sound_refresh();
	return G_SOURCE_CONTINUE;
}

static GtkWidget *
make_sound_page(void)
{
	GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_4);
	GtkWidget *title = gtk_label_new("声音");
	GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_3);
	GtkWidget *volcard = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_3);
	GtkWidget *voltitle = gtk_label_new("音量");
	GtkWidget *volrow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_3);
	GtkWidget *muterow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_3);
	GtkWidget *mute_label = gtk_label_new("静音");
	GtkWidget *test = gtk_button_new_with_label("播放测试音");
	GtkWidget *hint = gtk_label_new(
		"拖动滑杆调节音量；设置保存在数据分区，重启后恢复。");
	GtkWidget *note = gtk_label_new(
		"音量和静音由 WirePlumber（wpctl）管理，ALSA 程序经 PipeWire 混音。");

	g_sound_page = page;
	gtk_widget_set_margin_start(page, UI_SP_6);
	gtk_widget_set_margin_end(page, UI_SP_6);
	gtk_widget_set_margin_top(page, UI_SP_4);
	gtk_widget_set_margin_bottom(page, UI_SP_2);
	gtk_style_context_add_class(gtk_widget_get_style_context(title),
				    "page-title");
	gtk_label_set_xalign(GTK_LABEL(title), 0);
	gtk_box_pack_start(GTK_BOX(page), title, FALSE, FALSE, 0);

	gtk_style_context_add_class(gtk_widget_get_style_context(card), "card");
	gtk_box_pack_start(GTK_BOX(card),
			   make_status_row("输出设备", &g_sink_label),
			   FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(card),
			   make_status_row("音频服务", &g_audio_label),
			   FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);

	gtk_style_context_add_class(gtk_widget_get_style_context(volcard),
				    "card");
	gtk_label_set_xalign(GTK_LABEL(voltitle), 0);
	gtk_style_context_add_class(gtk_widget_get_style_context(voltitle),
				    "section");
	gtk_box_pack_start(GTK_BOX(volcard), voltitle, FALSE, FALSE, 0);

	g_vol_scale = GTK_RANGE(gtk_scale_new_with_range(
		GTK_ORIENTATION_HORIZONTAL, 0, 100, 1));
	gtk_scale_set_draw_value(GTK_SCALE(g_vol_scale), FALSE);
	gtk_widget_set_hexpand(GTK_WIDGET(g_vol_scale), TRUE);
	g_vol_label = gtk_label_new("—");
	gtk_label_set_width_chars(GTK_LABEL(g_vol_label), 9);
	gtk_widget_set_halign(g_vol_label, GTK_ALIGN_END);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_vol_label),
				    "accent");
	gtk_box_pack_start(GTK_BOX(volrow), GTK_WIDGET(g_vol_scale), TRUE,
			   TRUE, 0);
	gtk_box_pack_start(GTK_BOX(volrow), g_vol_label, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(volcard), volrow, FALSE, FALSE, 0);

	gtk_label_set_xalign(GTK_LABEL(mute_label), 0);
	gtk_widget_set_hexpand(mute_label, TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(mute_label),
				    "dim");
	g_mute_switch = GTK_SWITCH(gtk_switch_new());
	gtk_box_pack_start(GTK_BOX(muterow), mute_label, TRUE, TRUE, 0);
	gtk_box_pack_end(GTK_BOX(muterow), GTK_WIDGET(g_mute_switch), FALSE,
			 FALSE, 0);
	gtk_box_pack_start(GTK_BOX(volcard), muterow, FALSE, FALSE, 0);

	gtk_widget_set_halign(test, GTK_ALIGN_START);
	gtk_box_pack_start(GTK_BOX(volcard), test, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), volcard, FALSE, FALSE, 0);

	g_sound_note = note;
	gtk_label_set_xalign(GTK_LABEL(note), 0);
	gtk_label_set_line_wrap(GTK_LABEL(note), TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(note), "dim");
	gtk_box_pack_start(GTK_BOX(page), note, FALSE, FALSE, 0);

	gtk_label_set_xalign(GTK_LABEL(hint), 0);
	gtk_label_set_line_wrap(GTK_LABEL(hint), TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(hint), "weak");
	gtk_box_pack_start(GTK_BOX(page), hint, FALSE, FALSE, 0);

	g_signal_connect(g_vol_scale, "value-changed",
			 G_CALLBACK(on_volume_changed), NULL);
	g_signal_connect(g_mute_switch, "notify::active",
			 G_CALLBACK(on_mute_changed), NULL);
	g_signal_connect(test, "clicked", G_CALLBACK(on_test_sound), NULL);
	return page;
}

/* ---------------------------------------------------------------- AI */

static const AiPreset *
ai_find_preset(const gchar *id)
{
	if (!id)
		return NULL;
	for (guint i = 0; i < G_N_ELEMENTS(ai_presets); i++)
		if (strcmp(ai_presets[i].id, id) == 0)
			return &ai_presets[i];
	return NULL;
}

/* shui-ctl 的稳定输出是 key=value 行，这里拆成哈希表取字段。 */
static GHashTable *
parse_kv(const gchar *text)
{
	GHashTable *h = g_hash_table_new_full(g_str_hash, g_str_equal,
					      g_free, g_free);
	if (!text)
		return h;
	gchar **lines = g_strsplit(text, "\n", -1);
	for (int i = 0; lines[i]; i++) {
		gchar *line = g_strstrip(lines[i]);
		gchar *eq = strchr(line, '=');
		if (!eq)
			continue;
		*eq = 0;
		g_hash_table_replace(h, g_strdup(line), g_strdup(eq + 1));
	}
	g_strfreev(lines);
	return h;
}

static const gchar *
kv(GHashTable *h, const gchar *key)
{
	const gchar *v = g_hash_table_lookup(h, key);
	return v ? v : "";
}

static gboolean
kv_is_true(GHashTable *h, const gchar *key)
{
	return strcmp(kv(h, key), "1") == 0;
}

static void
ai_set_busy(gboolean busy)
{
	g_ai_busy = busy;
	gtk_widget_set_sensitive(GTK_WIDGET(g_ai_provider), !busy);
	gtk_widget_set_sensitive(GTK_WIDGET(g_ai_endpoint), !busy);
	gtk_widget_set_sensitive(GTK_WIDGET(g_ai_model), !busy);
	gtk_widget_set_sensitive(GTK_WIDGET(g_ai_key), !busy);
	gtk_widget_set_sensitive(g_ai_save, !busy && g_ai_daemon_ok);
	gtk_widget_set_sensitive(g_ai_test, !busy && g_ai_daemon_ok);
	gtk_widget_set_sensitive(g_ai_clear,
				 !busy && g_ai_daemon_ok && g_ai_key_set);
}

static void
ai_status_refresh(void)
{
	if (!g_ai_page || !g_ai_state_label || g_ai_busy)
		return;

	const gchar *argv[] = { SHUI_CTL, "ai", "status", NULL };
	gchar *out = NULL, *err = NULL;
	gint code = 0;
	gboolean ran = run_cmd(argv, &out, &err, &code);
	GHashTable *h = parse_kv(out);
	g_ai_daemon_ok = ran && code == 0 && *kv(h, "provider");

	if (!g_ai_daemon_ok) {
		g_ai_key_set = FALSE;
		gtk_label_set_text(g_ai_state_label, "shuiosd 未运行");
		gtk_label_set_text(g_ai_key_label, "未知");
		ai_set_busy(FALSE);
		g_free(out);
		g_free(err);
		g_hash_table_destroy(h);
		return;
	}

	const gchar *provider = kv(h, "provider");
	const gchar *name = kv(h, "provider_name");
	gboolean ready = kv_is_true(h, "ready");
	gboolean local = kv_is_true(h, "local");
	gboolean key_set = kv_is_true(h, "key_set");
	const gchar *hint = kv(h, "key_hint");
	const gchar *label = *name ? name : "AI";

	g_ai_key_set = key_set;
	g_ai_updating = TRUE;
	if (!gtk_combo_box_set_active_id(GTK_COMBO_BOX(g_ai_provider),
					 provider))
		gtk_combo_box_set_active_id(GTK_COMBO_BOX(g_ai_provider),
					    "custom");
	gtk_entry_set_text(g_ai_endpoint, kv(h, "endpoint"));
	gtk_entry_set_text(g_ai_model, kv(h, "model"));
	gtk_entry_set_text(g_ai_key, "");
	g_ai_updating = FALSE;

	gchar *state;
	if (ready)
		state = g_strdup_printf("%s · 就绪", label);
	else if (!local && !key_set)
		state = g_strdup_printf("%s · 需要 API 密钥", label);
	else
		state = g_strdup_printf("%s · 未就绪", label);
	gtk_label_set_text(g_ai_state_label, state);
	g_free(state);

	gchar *keytext;
	if (key_set && *hint)
		keytext = g_strdup_printf("已设置（%s）", hint);
	else if (key_set)
		keytext = g_strdup("已设置");
	else
		keytext = g_strdup("未设置");
	gtk_label_set_text(g_ai_key_label, keytext);
	g_free(keytext);

	gtk_entry_set_placeholder_text(
		g_ai_key, key_set ? "留空则保留已保存的密钥" : "粘贴 API 密钥");
	ai_set_busy(FALSE);

	g_free(out);
	g_free(err);
	g_hash_table_destroy(h);
}

static void
on_ai_provider_changed(GtkComboBox *combo, gpointer data)
{
	(void)data;
	if (g_ai_updating)
		return;
	const AiPreset *p = ai_find_preset(gtk_combo_box_get_active_id(combo));
	if (!p || strcmp(p->id, "custom") == 0)
		return;
	gtk_entry_set_text(g_ai_endpoint, p->endpoint);
	gtk_entry_set_text(g_ai_model, p->model);
}

static void
ai_show_error(const gchar *prefix, const gchar *out, const gchar *err)
{
	gchar *line = last_line(err);
	if (!*line) {
		g_free(line);
		line = last_line(out);
	}
	gchar *msg = g_strdup_printf("%s：%s", prefix,
				     *line ? line : "未知错误");
	gtk_label_set_text(g_ai_result_label, msg);
	g_free(msg);
	g_free(line);
}

static void
on_ai_save(GtkButton *b, gpointer data)
{
	(void)b;
	(void)data;
	if (g_ai_busy || !g_ai_daemon_ok)
		return;

	const gchar *id = gtk_combo_box_get_active_id(GTK_COMBO_BOX(g_ai_provider));
	if (!id)
		id = "custom";
	gchar *endpoint = g_strdup(gtk_entry_get_text(g_ai_endpoint));
	gchar *model = g_strdup(gtk_entry_get_text(g_ai_model));
	gchar *key = g_strdup(gtk_entry_get_text(g_ai_key));
	g_strstrip(endpoint);
	g_strstrip(model);
	g_strstrip(key);

	if (!*endpoint || !*model) {
		gtk_label_set_text(g_ai_result_label, "端点和模型不能为空。");
		goto out;
	}

	gchar *key_path = NULL;
	GPtrArray *argv = g_ptr_array_new();
	g_ptr_array_add(argv, (gpointer)SHUI_CTL);
	g_ptr_array_add(argv, (gpointer)"ai");
	g_ptr_array_add(argv, (gpointer)"set");
	g_ptr_array_add(argv, (gpointer)"--provider");
	g_ptr_array_add(argv, (gpointer)id);
	g_ptr_array_add(argv, (gpointer)"--endpoint");
	g_ptr_array_add(argv, endpoint);
	g_ptr_array_add(argv, (gpointer)"--model");
	g_ptr_array_add(argv, model);
	/* 密钥走 0600 临时文件，绝不出现在命令行（进程参数列表可见）。 */
	if (*key) {
		key_path = g_strdup_printf("/tmp/.shui-ai-key-%d-%u",
					   (int)getpid(), g_random_int());
		if (!write_private(key_path, key)) {
			gtk_label_set_text(g_ai_result_label,
					   "无法写入临时密钥文件。");
			g_free(key_path);
			g_ptr_array_free(argv, TRUE);
			goto out;
		}
		g_ptr_array_add(argv, (gpointer)"--key-file");
		g_ptr_array_add(argv, key_path);
	}
	g_ptr_array_add(argv, NULL);

	gchar *out = NULL, *err = NULL;
	gint code = 0;
	run_cmd((const gchar *const *)argv->pdata, &out, &err, &code);
	if (code == 0) {
		gtk_entry_set_text(g_ai_key, "");
		gtk_label_set_text(g_ai_result_label,
				   "已保存。点「测试连接」验证密钥。");
		ai_status_refresh();
	} else {
		ai_show_error("保存失败", out, err);
	}
	g_free(out);
	g_free(err);
	if (key_path) {
		g_unlink(key_path);
		g_free(key_path);
	}
	g_ptr_array_free(argv, TRUE);
out:
	g_free(endpoint);
	g_free(model);
	g_free(key);
}

static void
on_ai_clear(GtkButton *b, gpointer data)
{
	(void)b;
	(void)data;
	if (g_ai_busy || !g_ai_daemon_ok)
		return;
	const gchar *argv[] = { SHUI_CTL, "ai", "clear-key", NULL };
	gchar *out = NULL, *err = NULL;
	gint code = 0;
	run_cmd(argv, &out, &err, &code);
	if (code == 0) {
		gtk_entry_set_text(g_ai_key, "");
		gtk_label_set_text(g_ai_result_label, "已删除保存的 API 密钥。");
		ai_status_refresh();
	} else {
		ai_show_error("删除失败", out, err);
	}
	g_free(out);
	g_free(err);
}

typedef struct {
	gboolean ok;
	gchar *reply;
	gchar *error;
	gchar *model;
	guint latency;
} AiTestRes;

static gboolean ai_test_done(gpointer data);

static gpointer
ai_test_thread(gpointer data)
{
	(void)data;
	AiTestRes *r = g_new0(AiTestRes, 1);
	const gchar *argv[] = { SHUI_CTL, "ai", "test", NULL };
	gchar *out = NULL, *err = NULL;
	gint code = 0;
	gboolean ran = run_cmd(argv, &out, &err, &code);
	GHashTable *h = parse_kv(out);

	r->ok = ran && code == 0 && kv_is_true(h, "ok");
	if (r->ok) {
		r->reply = g_strdup(kv(h, "reply"));
		r->model = g_strdup(kv(h, "model"));
		r->latency = (guint)g_ascii_strtoull(kv(h, "latency_ms"),
						    NULL, 10);
	} else {
		gchar *line = last_line(err);
		const gchar *e = kv(h, "error");
		if (*e)
			r->error = g_strdup(e);
		else if (*line)
			r->error = g_strdup(line);
		else
			r->error = g_strdup(ran ? "测试失败" : "无法运行 shui-ctl");
		g_free(line);
	}
	g_free(out);
	g_free(err);
	g_hash_table_destroy(h);
	g_idle_add((GSourceFunc)ai_test_done, r);
	return NULL;
}

static gboolean
ai_test_done(gpointer data)
{
	AiTestRes *r = data;
	if (r->ok) {
		gchar *msg = g_strdup_printf(
			"连接成功 · %s · %u ms\n%s",
			*r->model ? r->model : "模型", r->latency,
			*r->reply ? r->reply : "（空回复）");
		gtk_label_set_text(g_ai_result_label, msg);
		g_free(msg);
	} else {
		gchar *msg = g_strdup_printf("测试失败：%s",
					     r->error ? r->error : "未知错误");
		gtk_label_set_text(g_ai_result_label, msg);
		g_free(msg);
	}
	g_free(r->reply);
	g_free(r->error);
	g_free(r->model);
	g_free(r);
	ai_set_busy(FALSE);
	ai_status_refresh();
	return G_SOURCE_REMOVE;
}

static void
on_ai_test(GtkButton *b, gpointer data)
{
	(void)b;
	(void)data;
	if (g_ai_busy || !g_ai_daemon_ok)
		return;
	ai_set_busy(TRUE);
	gtk_label_set_text(g_ai_result_label, "正在连接推理服务…");
	g_thread_new("settings-ai-test", ai_test_thread, NULL);
}

static GtkWidget *
make_ai_page(void)
{
	GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
	GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_4);
	GtkWidget *title = gtk_label_new("AI 助手");
	GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_3);
	GtkWidget *form = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_3);
	GtkWidget *formtitle = gtk_label_new("推理服务");
	GtkWidget *grid = gtk_grid_new();
	GtkWidget *provider_label = gtk_label_new("提供商");
	GtkWidget *endpoint_label = gtk_label_new("端点");
	GtkWidget *model_label = gtk_label_new("模型");
	GtkWidget *key_label = gtk_label_new("API 密钥");
	GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	GtkWidget *note = gtk_label_new(
		"本地模型不需要密钥；远程端点必须以 https:// 开头。密钥只保存在本机 "
		"/var/lib/shuios/state/ai.json（权限 0600），由 shuiosd 保管并代发"
		"请求，不会出现在命令行、日志或设置界面的回读中。");

	g_ai_page = page;
	gtk_widget_set_margin_start(page, UI_SP_6);
	gtk_widget_set_margin_end(page, UI_SP_6);
	gtk_widget_set_margin_top(page, UI_SP_4);
	gtk_widget_set_margin_bottom(page, UI_SP_2);
	gtk_style_context_add_class(gtk_widget_get_style_context(title),
				    "page-title");
	gtk_label_set_xalign(GTK_LABEL(title), 0);
	gtk_box_pack_start(GTK_BOX(page), title, FALSE, FALSE, 0);

	gtk_style_context_add_class(gtk_widget_get_style_context(card), "card");
	gtk_box_pack_start(GTK_BOX(card),
			   make_status_row("状态", &g_ai_state_label),
			   FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(card),
			   make_status_row("API 密钥", &g_ai_key_label),
			   FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);

	gtk_style_context_add_class(gtk_widget_get_style_context(form), "card");
	gtk_label_set_xalign(GTK_LABEL(formtitle), 0);
	gtk_style_context_add_class(gtk_widget_get_style_context(formtitle),
				    "section");
	gtk_box_pack_start(GTK_BOX(form), formtitle, FALSE, FALSE, 0);

	gtk_grid_set_row_spacing(GTK_GRID(grid), UI_SP_2);
	gtk_grid_set_column_spacing(GTK_GRID(grid), UI_SP_3);

	g_ai_provider = GTK_COMBO_BOX_TEXT(gtk_combo_box_text_new());
	for (guint i = 0; i < G_N_ELEMENTS(ai_presets); i++)
		gtk_combo_box_text_append(g_ai_provider, ai_presets[i].id,
					  ai_presets[i].name);
	gtk_combo_box_set_active_id(GTK_COMBO_BOX(g_ai_provider), "local");
	gtk_widget_set_hexpand(GTK_WIDGET(g_ai_provider), TRUE);

	g_ai_endpoint = GTK_ENTRY(gtk_entry_new());
	gtk_entry_set_placeholder_text(g_ai_endpoint,
				       "https://api.example.com/v1");
	gtk_widget_set_hexpand(GTK_WIDGET(g_ai_endpoint), TRUE);

	g_ai_model = GTK_ENTRY(gtk_entry_new());
	gtk_entry_set_placeholder_text(g_ai_model, "模型名，例如 deepseek-chat");
	gtk_widget_set_hexpand(GTK_WIDGET(g_ai_model), TRUE);

	g_ai_key = GTK_ENTRY(gtk_entry_new());
	gtk_entry_set_visibility(g_ai_key, FALSE);
	gtk_entry_set_input_purpose(g_ai_key, GTK_INPUT_PURPOSE_PASSWORD);
	gtk_entry_set_placeholder_text(g_ai_key, "粘贴 API 密钥");
	gtk_widget_set_hexpand(GTK_WIDGET(g_ai_key), TRUE);

	gtk_label_set_xalign(GTK_LABEL(provider_label), 0);
	gtk_label_set_xalign(GTK_LABEL(endpoint_label), 0);
	gtk_label_set_xalign(GTK_LABEL(model_label), 0);
	gtk_label_set_xalign(GTK_LABEL(key_label), 0);
	gtk_style_context_add_class(gtk_widget_get_style_context(provider_label),
				    "dim");
	gtk_style_context_add_class(gtk_widget_get_style_context(endpoint_label),
				    "dim");
	gtk_style_context_add_class(gtk_widget_get_style_context(model_label),
				    "dim");
	gtk_style_context_add_class(gtk_widget_get_style_context(key_label),
				    "dim");
	gtk_grid_attach(GTK_GRID(grid), provider_label, 0, 0, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), GTK_WIDGET(g_ai_provider), 1, 0, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), endpoint_label, 0, 1, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), GTK_WIDGET(g_ai_endpoint), 1, 1, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), model_label, 0, 2, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), GTK_WIDGET(g_ai_model), 1, 2, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), key_label, 0, 3, 1, 1);
	gtk_grid_attach(GTK_GRID(grid), GTK_WIDGET(g_ai_key), 1, 3, 1, 1);
	gtk_box_pack_start(GTK_BOX(form), grid, FALSE, FALSE, 0);

	g_ai_save = gtk_button_new_with_label("保存");
	g_ai_test = gtk_button_new_with_label("测试连接");
	g_ai_clear = gtk_button_new_with_label("清除密钥");
	gtk_box_pack_start(GTK_BOX(buttons), g_ai_save, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(buttons), g_ai_test, FALSE, FALSE, 0);
	gtk_box_pack_end(GTK_BOX(buttons), g_ai_clear, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(form), buttons, FALSE, FALSE, 0);

	g_ai_result_label = GTK_LABEL(gtk_label_new("尚未测试。"));
	gtk_label_set_xalign(g_ai_result_label, 0);
	gtk_label_set_line_wrap(g_ai_result_label, TRUE);
	gtk_label_set_selectable(g_ai_result_label, TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(
					    GTK_WIDGET(g_ai_result_label)),
				    "dim");
	gtk_box_pack_start(GTK_BOX(form), GTK_WIDGET(g_ai_result_label), FALSE,
			   FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), form, FALSE, FALSE, 0);

	gtk_label_set_xalign(GTK_LABEL(note), 0);
	gtk_label_set_line_wrap(GTK_LABEL(note), TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(note), "weak");
	gtk_box_pack_start(GTK_BOX(page), note, FALSE, FALSE, 0);

	g_signal_connect(g_ai_provider, "changed",
			 G_CALLBACK(on_ai_provider_changed), NULL);
	g_signal_connect(g_ai_save, "clicked", G_CALLBACK(on_ai_save), NULL);
	g_signal_connect(g_ai_test, "clicked", G_CALLBACK(on_ai_test), NULL);
	g_signal_connect(g_ai_clear, "clicked", G_CALLBACK(on_ai_clear), NULL);
	ai_set_busy(FALSE);

	gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll),
				       GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
	gtk_container_add(GTK_CONTAINER(scroll), page);
	return scroll;
}

static gchar *
os_pretty_name(void)
{
	gchar *data = NULL;
	if (!g_file_get_contents("/etc/os-release", &data, NULL, NULL))
		return g_strdup("shuios");
	gchar **lines = g_strsplit(data, "\n", -1);
	gchar *ret = NULL;
	for (int i = 0; lines[i]; i++) {
		if (g_str_has_prefix(lines[i], "PRETTY_NAME=")) {
			gchar *v = lines[i] + strlen("PRETTY_NAME=");
			gchar *end = NULL;
			if (*v == '"') {
				v++;
				end = strrchr(v, '"');
				if (end)
					*end = 0;
			}
			ret = g_strdup(v);
			break;
		}
	}
	g_strfreev(lines);
	g_free(data);
	return ret ? ret : g_strdup("shuios");
}

static gchar *
mem_total(void)
{
	gchar *data = NULL;
	if (!g_file_get_contents("/proc/meminfo", &data, NULL, NULL))
		return g_strdup("未知");
	gchar **lines = g_strsplit(data, "\n", -1);
	gchar *ret = g_strdup("未知");
	for (int i = 0; lines[i]; i++) {
		if (g_str_has_prefix(lines[i], "MemTotal:")) {
			gint kb = atoi(lines[i] + strlen("MemTotal:"));
			g_free(ret);
			ret = g_strdup_printf("%.1f GB", kb / 1024.0 / 1024.0);
			break;
		}
	}
	g_strfreev(lines);
	g_free(data);
	return ret;
}

static gchar *
uptime_text(void)
{
	gchar *data = NULL;
	if (!g_file_get_contents("/proc/uptime", &data, NULL, NULL))
		return g_strdup("未知");
	gint sec = (gint)g_ascii_strtoll(data, NULL, 10);
	g_free(data);
	gint h = sec / 3600, m = (sec % 3600) / 60;
	return g_strdup_printf("%d 小时 %d 分钟", h, m);
}

static GtkWidget *
make_about_page(void)
{
	GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_4);
	GtkWidget *title = gtk_label_new("关于");
	GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, UI_SP_3);
	GtkWidget *grid = gtk_grid_new();
	struct utsname u;
	gchar *pretty = os_pretty_name();
	gchar *host = g_strdup(g_get_host_name());
	gchar *mem = mem_total();
	gchar *up = uptime_text();

	gtk_widget_set_margin_start(page, UI_SP_6);
	gtk_widget_set_margin_end(page, UI_SP_6);
	gtk_widget_set_margin_top(page, UI_SP_4);
	gtk_widget_set_margin_bottom(page, UI_SP_2);
	gtk_style_context_add_class(gtk_widget_get_style_context(title),
				    "page-title");
	gtk_label_set_xalign(GTK_LABEL(title), 0);
	gtk_box_pack_start(GTK_BOX(page), title, FALSE, FALSE, 0);

	gtk_style_context_add_class(gtk_widget_get_style_context(card), "card");
	gtk_grid_set_row_spacing(GTK_GRID(grid), UI_SP_2);
	gtk_grid_set_column_spacing(GTK_GRID(grid), UI_SP_6);

	const gchar *keys[] = { "系统", "内核", "主机名", "内存", "运行时间",
				"桌面", "网络" };
	gchar *vals[7];
	vals[0] = pretty;
	vals[1] = uname(&u) == 0 ? g_strdup(u.release) : g_strdup("未知");
	vals[2] = host;
	vals[3] = mem;
	vals[4] = up;
	vals[5] = g_strdup("swayfx + shui-panel（底部任务栏）");
	vals[6] = g_strdup("NetworkManager + wpa_supplicant");
	for (int i = 0; i < 7; i++) {
		GtkWidget *k = gtk_label_new(keys[i]);
		GtkWidget *v = gtk_label_new(vals[i]);
		gtk_label_set_xalign(GTK_LABEL(k), 0);
		gtk_label_set_xalign(GTK_LABEL(v), 0);
		gtk_label_set_selectable(GTK_LABEL(v), i == 1 || i == 2);
		gtk_style_context_add_class(gtk_widget_get_style_context(k),
					    "dim");
		gtk_grid_attach(GTK_GRID(grid), k, 0, i, 1, 1);
		gtk_grid_attach(GTK_GRID(grid), v, 1, i, 1, 1);
		g_free(vals[i]);
	}
	gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);

	GtkWidget *note = gtk_label_new(
		"设置中心：网络、声音、AI 助手与系统信息。显示等页面在后续迭代补齐。");
	gtk_label_set_xalign(GTK_LABEL(note), 0);
	gtk_label_set_line_wrap(GTK_LABEL(note), TRUE);
	gtk_style_context_add_class(gtk_widget_get_style_context(note), "weak");
	gtk_box_pack_start(GTK_BOX(page), note, FALSE, FALSE, 0);
	return page;
}

static void
on_nav_row(GtkListBox *nav, GtkListBoxRow *row, gpointer data)
{
	GtkStack *stack = data;
	int idx = gtk_list_box_row_get_index(row);
	const char *name = idx == 1   ? "sound"
			   : idx == 2 ? "ai"
			   : idx == 3 ? "about"
				      : "network";
	gtk_stack_set_visible_child_name(stack, name);
	/* 声音页的数值只在可见时轮询，切过去先立刻刷一次，避免短暂显示旧值 */
	if (strcmp(name, "sound") == 0)
		sound_refresh();
	if (strcmp(name, "ai") == 0)
		ai_status_refresh();
	(void)nav;
}

static void
on_refresh(GtkButton *b, gpointer data)
{
	(void)b;
	(void)data;
	if (g_scanning)
		return;
	g_scanning = TRUE;
	gtk_widget_set_sensitive(g_refresh_btn, FALSE);
	gtk_label_set_text(GTK_LABEL(g_status), "正在扫描 Wi-Fi…");
	g_thread_new("settings-scan", scan_thread, NULL);
}

static void
on_wifi_switch(GObject *obj, GParamSpec *pspec, gpointer data)
{
	(void)pspec;
	(void)data;
	if (g_updating_switch)
		return;
	gboolean on = gtk_switch_get_active(GTK_SWITCH(obj));
	const gchar *argv[] = { NMCLI, "radio", "wifi", on ? "on" : "off",
				NULL };
	gchar *o = NULL, *e = NULL;
	gint code = 0;
	run_cmd(argv, &o, &e, &code);
	g_free(o);
	g_free(e);
	gtk_label_set_text(GTK_LABEL(g_status),
			   on ? "Wi-Fi 已开启" : "Wi-Fi 已关闭");
	g_thread_new("settings-status", status_thread, NULL);
	if (on) {
		g_scanning = TRUE;
		g_thread_new("settings-scan", scan_thread, NULL);
	} else {
		GList *rows = gtk_container_get_children(GTK_CONTAINER(g_list));
		for (GList *it = rows; it; it = it->next)
			gtk_widget_destroy(GTK_WIDGET(it->data));
		g_list_free(rows);
		gtk_widget_show_all(g_list);
	}
}

static gboolean
on_key(GtkWidget *w, GdkEventKey *ev, gpointer data)
{
	(void)w;
	(void)data;
	if (ev->keyval == GDK_KEY_F5) {
		on_refresh(NULL, NULL);
		return TRUE;
	}
	if (ev->keyval == GDK_KEY_Escape) {
		gtk_widget_destroy(g_window);
		return TRUE;
	}
	return FALSE;
}

int
main(int argc, char **argv)
{
	GtkWidget *header, *outer, *nav, *stack, *bottom;
	GtkWidget *row_net, *row_sound, *row_ai, *row_about;
	gboolean want_sound = FALSE;
	gboolean want_ai = FALSE;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--sound") == 0)
			want_sound = TRUE;
		if (strcmp(argv[i], "--ai") == 0)
			want_ai = TRUE;
	}

	setenv("GTK_THEME", "Adwaita:dark", 0);
	gtk_init(&argc, &argv);
	install_css();

	/* 先同步探测无线接口名，扫描/连接都靠它；nmcli 很快，启动时阻塞可接受。 */
	const gchar *dev_argv[] = { NMCLI, "-t", "-f", "DEVICE,TYPE",
				    "device", "status", NULL };
	gchar *dev_out = NULL, *dev_err = NULL;
	gint code = 0;
	if (run_cmd(dev_argv, &dev_out, &dev_err, &code) && code == 0) {
		gchar **lines = g_strsplit(dev_out, "\n", -1);
		for (int i = 0; lines[i]; i++) {
			GPtrArray *f = split_terse(g_strstrip(lines[i]));
			if (f->len >= 2 &&
			    strcmp(g_ptr_array_index(f, 1), "wifi") == 0) {
				g_ifname = g_strdup(g_ptr_array_index(f, 0));
				g_ptr_array_free(f, TRUE);
				break;
			}
			g_ptr_array_free(f, TRUE);
		}
		g_strfreev(lines);
	}
	g_free(dev_out);
	g_free(dev_err);

	g_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
	gtk_window_set_default_size(GTK_WINDOW(g_window), 900, 620);
	gtk_window_set_title(GTK_WINDOW(g_window), "设置");
	gtk_window_set_icon_name(GTK_WINDOW(g_window), "preferences-system");

	header = gtk_header_bar_new();
	gtk_header_bar_set_title(GTK_HEADER_BAR(header), "设置");
	gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
	gtk_window_set_titlebar(GTK_WINDOW(g_window), header);

	outer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	nav = gtk_list_box_new();
	gtk_list_box_set_selection_mode(GTK_LIST_BOX(nav),
					GTK_SELECTION_SINGLE);
	gtk_style_context_add_class(gtk_widget_get_style_context(nav), "nav");
	gtk_widget_set_size_request(nav, 180, -1);

	row_net = gtk_list_box_row_new();
	GtkWidget *net_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	GtkWidget *net_icon = gtk_image_new_from_icon_name(
		"network-wireless", GTK_ICON_SIZE_MENU);
	GtkWidget *net_label = gtk_label_new("网络");
	gtk_box_pack_start(GTK_BOX(net_box), net_icon, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(net_box), net_label, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(row_net), net_box);

	row_sound = gtk_list_box_row_new();
	GtkWidget *sound_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	GtkWidget *sound_icon = gtk_image_new_from_icon_name(
		"audio-volume-high", GTK_ICON_SIZE_MENU);
	GtkWidget *sound_label = gtk_label_new("声音");
	gtk_box_pack_start(GTK_BOX(sound_box), sound_icon, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(sound_box), sound_label, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(row_sound), sound_box);

	row_ai = gtk_list_box_row_new();
	GtkWidget *ai_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	GtkWidget *ai_icon = gtk_image_new_from_icon_name(
		"applications-system", GTK_ICON_SIZE_MENU);
	GtkWidget *ai_label = gtk_label_new("AI 助手");
	gtk_box_pack_start(GTK_BOX(ai_box), ai_icon, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(ai_box), ai_label, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(row_ai), ai_box);

	row_about = gtk_list_box_row_new();
	GtkWidget *about_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, UI_SP_2);
	GtkWidget *about_icon = gtk_image_new_from_icon_name(
		"help-about", GTK_ICON_SIZE_MENU);
	GtkWidget *about_label = gtk_label_new("关于");
	gtk_box_pack_start(GTK_BOX(about_box), about_icon, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(about_box), about_label, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(row_about), about_box);

	gtk_list_box_insert(GTK_LIST_BOX(nav), row_net, -1);
	gtk_list_box_insert(GTK_LIST_BOX(nav), row_sound, -1);
	gtk_list_box_insert(GTK_LIST_BOX(nav), row_ai, -1);
	gtk_list_box_insert(GTK_LIST_BOX(nav), row_about, -1);
	gtk_widget_set_vexpand(nav, TRUE);

	stack = gtk_stack_new();
	g_stack = stack;
	gtk_stack_set_transition_type(GTK_STACK(stack),
				      GTK_STACK_TRANSITION_TYPE_CROSSFADE);
	gtk_stack_set_transition_duration(GTK_STACK(stack), 120);
	gtk_stack_add_named(GTK_STACK(stack), make_network_page(), "network");
	gtk_stack_add_named(GTK_STACK(stack), make_sound_page(), "sound");
	gtk_stack_add_named(GTK_STACK(stack), make_ai_page(), "ai");
	gtk_stack_add_named(GTK_STACK(stack), make_about_page(), "about");

	gtk_box_pack_start(GTK_BOX(outer), nav, FALSE, FALSE, 0);
	gtk_box_pack_start(GTK_BOX(outer), stack, TRUE, TRUE, 0);

	bottom = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
	g_status = gtk_label_new("就绪");
	gtk_label_set_xalign(GTK_LABEL(g_status), 0);
	gtk_widget_set_margin_start(g_status, UI_SP_6);
	gtk_widget_set_margin_end(g_status, UI_SP_6);
	gtk_widget_set_margin_top(g_status, UI_SP_1);
	gtk_widget_set_margin_bottom(g_status, UI_SP_1);
	gtk_style_context_add_class(gtk_widget_get_style_context(g_status),
				    "weak");
	gtk_box_pack_start(GTK_BOX(bottom), g_status, TRUE, TRUE, 0);

	GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
	gtk_box_pack_start(GTK_BOX(root), outer, TRUE, TRUE, 0);
	gtk_box_pack_start(GTK_BOX(root), bottom, FALSE, FALSE, 0);
	gtk_container_add(GTK_CONTAINER(g_window), root);

	/* 切页挂在 row-activated（单击或回车）。若用 row-selected，键盘 Tab
	   经过导航行也会触发切页，焦点被锁在侧栏、进不了右侧表单。
	   页面的初始选择放在 show_all 之后——窗口映射前设置 stack 的
	   visible child，交叉淡入不会启动，会停在首页（实测 --sound 只选中
	   导航行、右侧仍是网络页）。 */
	g_signal_connect(nav, "row-activated", G_CALLBACK(on_nav_row), stack);
	g_signal_connect(g_list, "row-activated",
			 G_CALLBACK(on_row_activated), NULL);
	g_signal_connect(g_refresh_btn, "clicked", G_CALLBACK(on_refresh), NULL);
	g_signal_connect(g_wifi_switch, "notify::active",
			 G_CALLBACK(on_wifi_switch), NULL);
	g_signal_connect(g_window, "key-press-event", G_CALLBACK(on_key), NULL);
	g_signal_connect(g_window, "destroy", G_CALLBACK(gtk_main_quit), NULL);

	gtk_widget_show_all(g_window);
	if (want_ai) {
		gtk_list_box_select_row(GTK_LIST_BOX(nav),
					GTK_LIST_BOX_ROW(row_ai));
		gtk_stack_set_visible_child_name(GTK_STACK(stack), "ai");
	} else if (want_sound) {
		gtk_list_box_select_row(GTK_LIST_BOX(nav),
					GTK_LIST_BOX_ROW(row_sound));
		gtk_stack_set_visible_child_name(GTK_STACK(stack), "sound");
	} else {
		gtk_list_box_select_row(GTK_LIST_BOX(nav),
					GTK_LIST_BOX_ROW(row_net));
		gtk_stack_set_visible_child_name(GTK_STACK(stack), "network");
	}
	sound_refresh();
	ai_status_refresh();
	g_timeout_add_seconds(3, sound_tick, NULL);

	gtk_label_set_text(GTK_LABEL(g_status), "正在扫描 Wi-Fi…");
	g_thread_new("settings-status", status_thread, NULL);
	g_scanning = TRUE;
	gtk_widget_set_sensitive(g_refresh_btn, FALSE);
	g_thread_new("settings-scan", scan_thread, NULL);

	gtk_main();
	return 0;
}
