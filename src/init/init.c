/*
 * init — mbaos PID 1.
 *
 * Deliberately small: anything that can fail in complicated ways lives
 * elsewhere, because if PID 1 exits or crashes the kernel panics.
 *
 *   1. mount the API filesystems (/proc, /sys, /dev/pts, /dev/shm, /run)
 *   2. run /etc/rc once (plain shell: remount root rw, fstab, hostname, sysctl)
 *   3. start the service supervisor /usr/sbin/svd, and restart it if it dies
 *   4. reap every zombie: orphans of all processes are re-parented to PID 1
 *   5. on a signal, shut down:
 *        SIGTERM, SIGINT (Ctrl-Alt-Del) -> reboot     SIGUSR2 -> power off
 *        SIGUSR1                        -> halt
 *      (the conventions BusyBox's reboot/poweroff/halt applets use)
 *
 * Shutdown: SIGTERM svd (it stops its services, 3 s grace each) -> SIGTERM
 * every remaining process -> 2 s -> SIGKILL -> sync -> remount / read-only ->
 * sync -> reboot(2).
 *
 * Boot timestamps (TSC and CLOCK_BOOTTIME at PID 1 start, rc done, svd start)
 * go to /run/boot-times for `bootreport`.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <x86intrin.h>

#define SVD "/usr/sbin/svd"
#define RC "/etc/rc"

static int kmsg = -1;
static pid_t svd_pid;

static void say(const char *fmt, ...)
{
	char buf[256];
	int n = snprintf(buf, sizeof buf, "<5>init: ");   /* notice: shown on the console */
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof buf - n, fmt, ap);
	va_end(ap);
	if (n >= (int)sizeof buf) n = sizeof buf - 1;
	if (kmsg < 0 || write(kmsg, buf, n) < 0) { write(2, buf + 3, n - 3); write(2, "\n", 1); }
}

static double boottime(void)
{
	struct timespec t;
	clock_gettime(CLOCK_BOOTTIME, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static void mnt(const char *src, const char *dst, const char *type, unsigned long fl, const char *opt)
{
	mkdir(dst, 0755);
	if (mount(src, dst, type, fl, opt) < 0 && errno != EBUSY)
		say("mount %s on %s failed: %s", type, dst, strerror(errno));
}

static sigset_t all;

/* fork + exec with default signal state; returns pid or -1 */
static pid_t spawn(char *const argv[])
{
	pid_t pid = fork();
	if (pid == 0) {
		sigprocmask(SIG_UNBLOCK, &all, NULL);
		setsid();
		execv(argv[0], argv);
		_exit(127);
	}
	if (pid < 0) say("fork failed: %s", strerror(errno));
	return pid;
}

/* Reap every exited child. Returns 1 if `watch` was among them. */
static int reap(pid_t watch, int *status)
{
	int found = 0, st;
	pid_t p;
	while ((p = waitpid(-1, &st, WNOHANG)) > 0)
		if (p == watch) { found = 1; if (status) *status = st; }
	return found;
}

/* Wait (reaping everything) until `pid` exits or `secs` pass. 1 = it exited. */
static int wait_for(pid_t pid, double secs)
{
	double end = boottime() + secs;
	for (;;) {
		if (reap(pid, NULL)) return 1;
		if (pid <= 0 && waitpid(-1, NULL, WNOHANG) < 0 && errno == ECHILD) return 1;
		double left = end - boottime();
		if (left <= 0) return 0;
		if (left > 0.1) left = 0.1;   /* re-check at least every 100 ms */
		struct timespec ts = { 0, (long)(left * 1e9) };
		siginfo_t si;
		sigset_t chld;
		sigemptyset(&chld);
		sigaddset(&chld, SIGCHLD);
		sigtimedwait(&chld, &si, &ts);
	}
}

/* No children left at all? */
static int no_children(void)
{
	reap(0, NULL);
	return waitpid(-1, NULL, WNOHANG) < 0 && errno == ECHILD;
}

__attribute__((noreturn)) static void shutdown_system(int how, const char *what)
{
	say("%s: stopping services", what);
	if (svd_pid > 0) {
		kill(svd_pid, SIGTERM);
		if (!wait_for(svd_pid, 10)) { say("svd did not stop in 10 s, killing it"); kill(svd_pid, SIGKILL); }
	}
	say("%s: terminating remaining processes", what);
	kill(-1, SIGTERM);
	double end = boottime() + 2;
	while (!no_children() && boottime() < end) wait_for(-1, 0.1);
	if (!no_children()) { say("%s: killing remaining processes", what); kill(-1, SIGKILL); wait_for(-1, 1); }

	sync();
	if (mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL) < 0)
		say("%s: remount / read-only FAILED: %s (data is synced)", what, strerror(errno));
	else
		say("%s: root filesystem remounted read-only", what);
	sync();
	say("%s: now", what);
	reboot(how);
	/* reboot(2) only returns on error; never leave PID 1 */
	say("reboot(2) failed: %s", strerror(errno));
	for (;;) pause();
}

static void record_times(const char *tag, double t)
{
	FILE *f = fopen("/run/boot-times", "ae");
	if (f) { fprintf(f, "%s %.6f\n", tag, t); fclose(f); }
}

int main(void)
{
	uint64_t tsc0 = __rdtsc();
	double t0 = boottime();

	if (getpid() != 1) { fprintf(stderr, "init: must run as PID 1\n"); return 1; }

	/* Every signal is handled synchronously in the main loop. */
	sigfillset(&all);
	sigprocmask(SIG_BLOCK, &all, NULL);
	reboot(RB_DISABLE_CAD);   /* Ctrl-Alt-Del now sends SIGINT to us */
	umask(022);
	setsid();

	mnt("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mnt("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mnt("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");  /* normally already there */
	mnt("devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC, "gid=5,mode=0620,ptmxmode=0666");
	mnt("tmpfs", "/dev/shm", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
	mnt("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755,size=20%");
	kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);

	/* TSC at PID 1 start: counts from CPU reset, so it includes firmware time */
	FILE *f = fopen("/run/boot-times", "we");
	if (f) { fprintf(f, "init_tsc %llu\ninit_start %.6f\n", (unsigned long long)tsc0, t0); fclose(f); }
	say("started at %.3f s", t0);

	/* Stage 1: /etc/rc, once. A failure is logged; boot continues. */
	char *rc[] = { "/bin/sh", RC, NULL };
	pid_t rcp = spawn(rc);
	int st = 0;
	while (rcp > 0) {
		siginfo_t si;
		sigwaitinfo(&all, &si);
		if (si.si_signo == SIGCHLD && reap(rcp, &st)) break;
	}
	if (rcp < 0 || !WIFEXITED(st) || WEXITSTATUS(st) != 0)
		say("%s failed (status %d), continuing", RC, st);
	record_times("rc_done", boottime());

	/* Stage 2: the supervisor. Respawned if it dies: after 1 s if it died
	 * within 10 s of starting; after 5 such deaths in a row, a rescue shell on
	 * the console first. Shutdown signals are honoured at all times. */
	char *svd[] = { SVD, NULL };
	double last_start = boottime(), next_start = 0;
	int fast_deaths = 0;
	svd_pid = spawn(svd);
	record_times("svd_start", last_start);

	for (;;) {
		siginfo_t si;
		struct timespec one = { 1, 0 };
		int sig = sigtimedwait(&all, &si, svd_pid > 0 ? NULL : &one);
		switch (sig) {
		case SIGCHLD:
			if (svd_pid > 0 && reap(svd_pid, &st)) {
				int fast = boottime() - last_start < 10;
				fast_deaths = fast ? fast_deaths + 1 : 0;
				say("svd exited (status %d)%s", st, fast ? ", restarting in 1 s" : ", restarting");
				svd_pid = 0;
				next_start = boottime() + (fast ? 1 : 0);
			} else {
				reap(0, NULL);
			}
			break;
		case SIGTERM:
		case SIGINT:  shutdown_system(RB_AUTOBOOT, "reboot");
		case SIGUSR2: shutdown_system(RB_POWER_OFF, "power off");
		case SIGUSR1: shutdown_system(RB_HALT_SYSTEM, "halt");
		default: break;
		}
		if (svd_pid == 0 && boottime() >= next_start) {
			if (fast_deaths >= 5) {
				say("svd keeps dying; rescue shell on /dev/console (exit it to retry svd)");
				char *sh[] = { "/bin/sh", NULL };
				pid_t p = spawn(sh);
				while (p > 0) {
					sig = sigwaitinfo(&all, &si);
					if (sig == SIGCHLD && reap(p, NULL)) break;
					if (sig == SIGTERM || sig == SIGINT) shutdown_system(RB_AUTOBOOT, "reboot");
					if (sig == SIGUSR2) shutdown_system(RB_POWER_OFF, "power off");
					if (sig == SIGUSR1) shutdown_system(RB_HALT_SYSTEM, "halt");
				}
				fast_deaths = 0;
			}
			svd_pid = spawn(svd);
			last_start = boottime();
		}
	}
}
