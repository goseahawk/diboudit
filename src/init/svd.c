/*
 * svd — mbaos service supervisor (started and restarted by init).
 *
 * A service is a directory /etc/sv/NAME containing an executable `run`.
 *   - All services start at once (parallel boot). A service that needs another
 *     waits for it itself; there is no dependency graph to get wrong.
 *   - `run` must stay in the foreground (exec the daemon, no forking).
 *   - stdout/stderr go to the kernel log as "NAME: line" (read with dmesg).
 *   - If `run` exits it is restarted: at once if it ran 10 s or more, otherwise
 *     after a back-off of 1, 2, 4 ... 60 s, so a crashing service cannot spin.
 *   - Exit status 100 means "done, do not restart" (one-shot jobs, or a service
 *     that finds its hardware absent).
 *   - A file /etc/sv/NAME/down keeps the service stopped.
 *   - SIGHUP: rescan /etc/sv (start new / un-downed, stop removed / downed).
 *   - SIGTERM: stop everything (SIGTERM + SIGHUP to each service's process
 *     group, 3 s grace, then SIGKILL) and exit. init sends this at shutdown.
 * State for `sv status` is written to /run/sv/NAME:
 *     STATE PID SINCE RESTARTS LAST_EXIT
 * with SINCE in seconds since boot (CLOCK_BOOTTIME).
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define SVDIR "/etc/sv"
#define RUNDIR "/run/sv"
#define MAXSVC 64
#define DONE_CODE 100

struct svc {
	char name[64];
	pid_t pid;
	double since, next;
	int restarts, last, backoff;
	int present, down, done;
	int logfd;
	char buf[512];
	size_t blen;
};

static struct svc svcs[MAXSVC];
static int nsvc, kmsg = -1;
static sigset_t mask;

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_BOOTTIME, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void klog(const char *who, const char *fmt, ...)
{
	char buf[600];
	int n = snprintf(buf, sizeof buf, "<6>%s: ", who);
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof buf - n, fmt, ap);
	va_end(ap);
	if (n >= (int)sizeof buf) n = sizeof buf - 1;
	if (kmsg < 0 || write(kmsg, buf, n) < 0) { write(2, buf + 3, n - 3); write(2, "\n", 1); }
}

static const char *state(const struct svc *s)
{
	if (s->pid > 0) return "run";
	if (s->done) return "done";
	if (s->down || !s->present) return "down";
	return "wait";
}

static void write_status(const struct svc *s)
{
	char path[128], tmp[136];
	snprintf(path, sizeof path, RUNDIR "/%.63s", s->name);
	snprintf(tmp, sizeof tmp, "%s.tmp", path);
	FILE *f = fopen(tmp, "we");
	if (!f) return;
	fprintf(f, "%s %d %.3f %d %d\n", state(s), (int)s->pid, s->since, s->restarts, s->last);
	fclose(f);
	rename(tmp, path);
}

static int exists(const char *name, const char *file)
{
	char p[160];
	snprintf(p, sizeof p, SVDIR "/%.63s/%.31s", name, file);
	return access(p, F_OK) == 0;
}

static void start(struct svc *s)
{
	int pfd[2];
	if (pipe2(pfd, O_CLOEXEC) < 0) { klog("svd", "pipe: %s", strerror(errno)); return; }
	pid_t pid = fork();
	if (pid < 0) { klog("svd", "fork: %s", strerror(errno)); close(pfd[0]); close(pfd[1]); return; }
	if (pid == 0) {
		char dir[128];
		sigprocmask(SIG_UNBLOCK, &mask, NULL);
		setsid();
		snprintf(dir, sizeof dir, SVDIR "/%.63s", s->name);
		if (chdir(dir) < 0) _exit(111);
		int null = open("/dev/null", O_RDONLY);
		dup2(null, 0);
		dup2(pfd[1], 1);
		dup2(pfd[1], 2);
		execl("./run", "run", (char *)NULL);
		_exit(111);
	}
	close(pfd[1]);
	if (s->logfd >= 0) close(s->logfd);
	s->logfd = pfd[0];
	fcntl(s->logfd, F_SETFL, O_NONBLOCK);
	s->blen = 0;
	s->pid = pid;
	s->since = now();
	s->done = 0;
	write_status(s);
}

static void stop(struct svc *s)
{
	if (s->pid > 0) { kill(-s->pid, SIGTERM); kill(-s->pid, SIGCONT); }
}

static struct svc *find(const char *name)
{
	for (int i = 0; i < nsvc; i++)
		if (strcmp(svcs[i].name, name) == 0) return &svcs[i];
	return NULL;
}

static void scan(void)
{
	for (int i = 0; i < nsvc; i++) svcs[i].present = 0;
	DIR *d = opendir(SVDIR);
	struct dirent *e;
	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.' || strlen(e->d_name) >= sizeof svcs[0].name) continue;
		char run[160];
		snprintf(run, sizeof run, SVDIR "/%.63s/run", e->d_name);
		if (access(run, X_OK) != 0) continue;
		struct svc *s = find(e->d_name);
		if (!s) {
			if (nsvc == MAXSVC) { klog("svd", "too many services, ignoring %s", e->d_name); continue; }
			s = &svcs[nsvc++];
			memset(s, 0, sizeof *s);
			snprintf(s->name, sizeof s->name, "%s", e->d_name);
			s->logfd = -1;
		}
		s->present = 1;
		int was_down = s->down;
		s->down = exists(s->name, "down");
		if (was_down && !s->down) { s->done = 0; s->backoff = 0; s->next = 0; }
	}
	if (d) closedir(d);
	for (int i = 0; i < nsvc; i++) {
		struct svc *s = &svcs[i];
		if ((s->down || !s->present) && s->pid > 0) stop(s);
		write_status(s);
	}
}

static void drain_log(struct svc *s, int final)
{
	for (;;) {
		ssize_t n = read(s->logfd, s->buf + s->blen, sizeof s->buf - 1 - s->blen);
		if (n <= 0) break;
		s->blen += n;
		char *nl;
		while ((nl = memchr(s->buf, '\n', s->blen)) || s->blen == sizeof s->buf - 1) {
			size_t len = nl ? (size_t)(nl - s->buf) : s->blen;
			s->buf[len] = 0;
			if (len) klog(s->name, "%s", s->buf);
			size_t used = nl ? len + 1 : len;
			memmove(s->buf, s->buf + used, s->blen - used);
			s->blen -= used;
		}
	}
	if (final && s->blen) { s->buf[s->blen] = 0; klog(s->name, "%s", s->buf); s->blen = 0; }
}

static void reaped(pid_t pid, int st)
{
	for (int i = 0; i < nsvc; i++) {
		struct svc *s = &svcs[i];
		if (s->pid != pid) continue;
		if (s->logfd >= 0) { drain_log(s, 1); close(s->logfd); s->logfd = -1; }
		double ran = now() - s->since;
		s->pid = 0;
		s->last = WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
		if (WIFEXITED(st) && WEXITSTATUS(st) == DONE_CODE) {
			s->done = 1;
		} else if (s->present && !s->down) {
			s->backoff = ran >= 10 ? 0 : (s->backoff ? (s->backoff * 2 > 60 ? 60 : s->backoff * 2) : 1);
			s->next = now() + s->backoff;
			s->restarts++;
			klog("svd", "%s exited (%d) after %.1f s; restart in %d s", s->name, s->last, ran, s->backoff);
		}
		write_status(s);
		return;
	}
}

static void reap_all(void)
{
	int st;
	pid_t p;
	while ((p = waitpid(-1, &st, WNOHANG)) > 0) reaped(p, st);
}

static void stop_all_and_exit(void)
{
	int running = 0;
	/* At shutdown also send SIGHUP: an interactive shell (a getty service
	 * after login) ignores SIGTERM but ends on hangup. Without it every
	 * shutdown with someone logged in waited the full 3 s grace period. */
	for (int i = 0; i < nsvc; i++)
		if (svcs[i].pid > 0) { stop(&svcs[i]); kill(-svcs[i].pid, SIGHUP); running++; }
	klog("svd", "stopping %d services", running);
	double end = now() + 3;
	for (;;) {
		reap_all();
		running = 0;
		for (int i = 0; i < nsvc; i++) running += svcs[i].pid > 0;
		if (!running || now() >= end) break;
		struct timespec ts = { 0, 50 * 1000 * 1000 };
		nanosleep(&ts, NULL);
	}
	for (int i = 0; i < nsvc; i++)
		if (svcs[i].pid > 0) { klog("svd", "%s did not stop in 3 s, killing", svcs[i].name); kill(-svcs[i].pid, SIGKILL); }
	reap_all();
	exit(0);
}

int main(void)
{
	kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	mkdir(RUNDIR, 0755);
	FILE *pf = fopen(RUNDIR "/.svd.pid", "we");
	if (pf) { fprintf(pf, "%d\n", (int)getpid()); fclose(pf); }

	sigemptyset(&mask);
	sigaddset(&mask, SIGCHLD);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGHUP);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	int sfd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);

	scan();
	for (;;) {
		/* start everything that is due */
		double t = now(), wake = -1;
		for (int i = 0; i < nsvc; i++) {
			struct svc *s = &svcs[i];
			if (s->pid || s->done || s->down || !s->present) continue;
			if (s->next <= t) start(s);
			else if (wake < 0 || s->next < wake) wake = s->next;
		}

		struct pollfd fds[MAXSVC + 1];
		struct svc *who[MAXSVC + 1];
		int n = 0;
		fds[n] = (struct pollfd){ sfd, POLLIN, 0 }; who[n++] = NULL;
		for (int i = 0; i < nsvc; i++)
			if (svcs[i].logfd >= 0) { fds[n] = (struct pollfd){ svcs[i].logfd, POLLIN, 0 }; who[n++] = &svcs[i]; }
		int timeout = wake < 0 ? -1 : (int)((wake - now()) * 1000) + 1;
		if (timeout < -1) timeout = 0;
		if (poll(fds, n, timeout) < 0 && errno != EINTR) continue;

		for (int i = 1; i < n; i++)
			if (fds[i].revents) drain_log(who[i], 0);
		if (fds[0].revents) {
			struct signalfd_siginfo si;
			while (read(sfd, &si, sizeof si) == sizeof si) {
				if (si.ssi_signo == SIGTERM) stop_all_and_exit();
				if (si.ssi_signo == SIGHUP) scan();
			}
			reap_all();
		}
	}
}
