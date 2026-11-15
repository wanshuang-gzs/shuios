/*
 * shui-idle — 空闲自动锁屏
 *
 * 会话里没有 swayidle（Buildroot 没有这个包），这里直接用 evdev：
 * 打开 /dev/input/event*，任何按键/移动/触摸事件都重置计时器；
 * 超过 timeout 秒没有输入就拉起 shui-lock。
 *
 * 同时充当锁屏 watchdog：/run/shuios/lock.pid 里的进程如果已经死了
 * （锁屏被 kill -9、崩溃），把 sway 从 "shui-lock" binding mode 切回
 * default，避免快捷键一直失效。
 *
 * 配置：/etc/shuios/idle.conf 的 timeout=秒；命令行 --timeout 可覆盖
 * （验收时用短超时，生产默认 600 秒）。
 *
 * 单实例：flock(/run/shuios/idle.lock)。
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define IDLE_RUN_DIR "/run/shuios"
#define IDLE_LOCKFILE IDLE_RUN_DIR "/idle.lock"
#define LOCK_PIDFILE IDLE_RUN_DIR "/lock.pid"
#define IDLE_CONF "/etc/shuios/idle.conf"
#define LOCK_BIN "/usr/bin/shui-lock"
#define DEFAULT_TIMEOUT 600
#define MAX_DEV 32

static volatile sig_atomic_t g_stop;
static int g_verbose;

static int g_fds[MAX_DEV];
static int g_nfds;
static char g_paths[MAX_DEV][96];

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

static int load_timeout(void)
{
	FILE *f = fopen(IDLE_CONF, "r");
	if (!f)
		return DEFAULT_TIMEOUT;
	char line[256];
	int t = DEFAULT_TIMEOUT;
	while (fgets(line, sizeof line, f)) {
		if (line[0] == '#' || !strchr(line, '='))
			continue;
		long v = strtol(strchr(line, '=') + 1, NULL, 10);
		if (v >= 5 && v <= 86400)
			t = (int)v;
	}
	fclose(f);
	return t;
}

static void close_devices(void)
{
	for (int i = 0; i < g_nfds; i++)
		close(g_fds[i]);
	g_nfds = 0;
}

static int path_tracked(const char *path)
{
	for (int i = 0; i < g_nfds; i++)
		if (!strcmp(g_paths[i], path))
			return 1;
	return 0;
}

static void scan_devices(void)
{
	glob_t g;
	if (glob("/dev/input/event*", 0, NULL, &g) != 0)
		return;
	for (size_t i = 0; i < g.gl_pathc && g_nfds < MAX_DEV; i++) {
		const char *p = g.gl_pathv[i];
		if (path_tracked(p))
			continue;
		int fd = open(p, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		g_fds[g_nfds] = fd;
		snprintf(g_paths[g_nfds], sizeof g_paths[g_nfds], "%s", p);
		g_nfds++;
		if (g_verbose)
			fprintf(stderr, "shui-idle: 监听 %s\n", p);
	}
	globfree(&g);
}

/* 返回 1 表示读到“人操作了设备”的事件 */
static int drain_events(int fd)
{
	struct input_event ev;
	int active = 0;
	while (read(fd, &ev, sizeof ev) == (ssize_t)sizeof ev) {
		switch (ev.type) {
		case EV_KEY:
		case EV_REL:
		case EV_ABS:
		case EV_SW:
			active = 1;
			break;
		default:
			break;
		}
	}
	return active;
}

static int read_lock_pid(void)
{
	FILE *f = fopen(LOCK_PIDFILE, "r");
	if (!f)
		return -1;
	int pid = -1;
	if (fscanf(f, "%d", &pid) != 1)
		pid = -1;
	fclose(f);
	return pid;
}

static int pid_alive(int pid)
{
	if (pid <= 0)
		return 0;
	return kill(pid, 0) == 0 || errno == EPERM;
}

static void restore_default_mode(void)
{
	pid_t p = fork();
	if (p == 0) {
		int devnull = open("/dev/null", O_WRONLY);
		if (devnull >= 0) {
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		execl("/usr/bin/swaymsg", "swaymsg", "mode", "default", NULL);
		_exit(127);
	}
	if (p > 0)
		waitpid(p, NULL, 0);
}

static pid_t spawn_lock(void)
{
	pid_t p = fork();
	if (p == 0) {
		execl(LOCK_BIN, "shui-lock", NULL);
		_exit(127);
	}
	return p;
}

static void usage(const char *argv0)
{
	printf("用法: %s [--timeout 秒] [--verbose]\n"
	       "  空闲超过 timeout 秒自动锁屏（默认读 %s，缺省 %d 秒）。\n",
	       argv0, IDLE_CONF, DEFAULT_TIMEOUT);
}

int main(int argc, char **argv)
{
	int timeout = -1;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--timeout") && i + 1 < argc) {
			timeout = atoi(argv[++i]);
			if (timeout < 5) {
				fprintf(stderr, "shui-idle: timeout 至少 5 秒\n");
				return 2;
			}
		} else if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v")) {
			g_verbose = 1;
		} else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
			usage(argv[0]);
			return 0;
		}
	}
	if (timeout < 0)
		timeout = load_timeout();

	int lock_fd = open(IDLE_LOCKFILE, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
	if (lock_fd >= 0 && flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
		if (g_verbose)
			fprintf(stderr, "shui-idle: 已有实例在运行，退出\n");
		return 0;
	}

	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGHUP, &sa, NULL);

	scan_devices();
	if (g_verbose)
		fprintf(stderr, "shui-idle: timeout=%d 秒，设备数=%d\n", timeout, g_nfds);

	long last = now_ms();
	long last_scan = last;
	long last_house = last;
	pid_t lock_child = -1;
	int was_locked = 0;

	while (!g_stop) {
		struct pollfd pfd[MAX_DEV];
		for (int i = 0; i < g_nfds; i++) {
			pfd[i].fd = g_fds[i];
			pfd[i].events = POLLIN;
			pfd[i].revents = 0;
		}
		int pr = poll(pfd, g_nfds, 200);
		if (pr > 0) {
			for (int i = 0; i < g_nfds; i++)
				if (pfd[i].revents & POLLIN)
					if (drain_events(g_fds[i]))
						last = now_ms();
		}

		long t = now_ms();

		if (t - last_scan >= 5000) {
			scan_devices();
			last_scan = t;
		}

		if (t - last_house < 500)
			continue;
		last_house = t;

		/* 回收自己拉起的锁屏 */
		if (lock_child > 0) {
			int st;
			if (waitpid(lock_child, &st, WNOHANG) == lock_child) {
				lock_child = -1;
				last = now_ms();
				if (g_verbose)
					fprintf(stderr, "shui-idle: 锁屏进程已退出，重新计时\n");
			}
		}

		int pid = read_lock_pid();

		/* watchdog：pid 文件还在但进程没了 → 恢复快捷键 */
		if (pid > 0 && !pid_alive(pid)) {
			unlink(LOCK_PIDFILE);
			restore_default_mode();
			last = now_ms();
			if (g_verbose)
				fprintf(stderr, "shui-idle: 锁屏进程 %d 异常消失，已恢复 default mode\n",
					pid);
			pid = -1;
		}

		int active = (pid > 0 && pid_alive(pid)) || lock_child > 0;
		if (was_locked && !active) {
			last = now_ms();
			if (g_verbose)
				fprintf(stderr, "shui-idle: 已解锁，重新计时\n");
		}
		was_locked = active;

		if (!active && t - last >= (long)timeout * 1000) {
			if (g_verbose)
				fprintf(stderr, "shui-idle: 空闲 %d 秒，锁定\n", timeout);
			pid_t p = spawn_lock();
			if (p > 0) {
				lock_child = p;
				was_locked = 1;
			} else {
				last = now_ms();
			}
		}
	}

	close_devices();
	if (lock_fd >= 0)
		close(lock_fd);
	return 0;
}
