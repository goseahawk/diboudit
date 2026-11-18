/*
 * bootprobe — Phase 1 stand-in for PID 1. NOT the real init (that is Phase 2).
 *
 * Runs as /sbin/init, reports what the kernel found and how long boot took,
 * then waits (on the Mac, so you can read the screen) or powers off (in QEMU,
 * so tests finish). Output goes to /dev/kmsg, so it appears in the kernel log
 * on every console: the screen on the Mac, the serial port in QEMU.
 *
 * Timing:
 *   kernel  = CLOCK_BOOTTIME when this process starts (kernel start -> init)
 *   reset   = TSC / TSC frequency. The TSC counts from 0 at CPU reset, so this
 *             is "CPU power-on -> init" including firmware time. Only meaningful
 *             on real hardware; firmware ~= reset - kernel.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <x86intrin.h>

static int kmsg = -1;

static void say(const char *fmt, ...)
{
	char buf[512];
	int n = snprintf(buf, sizeof buf, "<5>bootprobe: ");
	va_list ap;
	va_start(ap, fmt);
	n += vsnprintf(buf + n, sizeof buf - n, fmt, ap);
	va_end(ap);
	if (n >= (int)sizeof buf) n = sizeof buf - 1;
	if (kmsg >= 0) write(kmsg, buf, n);
	else { write(1, buf + 3, n - 3); write(1, "\n", 1); }
}

/* first line of a file, newline stripped; "" if unreadable */
static const char *line(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "re");
	buf[0] = 0;
	if (f) {
		if (fgets(buf, len, f)) buf[strcspn(buf, "\n")] = 0;
		fclose(f);
	}
	return buf;
}

/* value of "key:" in a /proc file like meminfo or cpuinfo */
static long field(const char *path, const char *key, char *str, size_t len)
{
	char l[512];
	long v = -1;
	size_t k = strlen(key);
	FILE *f = fopen(path, "re");
	if (!f) return -1;
	while (fgets(l, sizeof l, f)) {
		if (strncmp(l, key, k) == 0 && (l[k] == ':' || l[k] == ' ' || l[k] == '\t')) {
			char *p = strchr(l, ':');
			if (!p) continue;
			p++;
			while (*p == ' ' || *p == '\t') p++;
			p[strcspn(p, "\n")] = 0;
			if (str) snprintf(str, len, "%s", p);
			sscanf(p, "%ld", &v);
			break;
		}
	}
	fclose(f);
	return v;
}

static double now(clockid_t c)
{
	struct timespec t;
	clock_gettime(c, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(void)
{
	/* take the timestamps before doing anything else */
	uint64_t tsc0 = __rdtsc();
	double kernel = now(CLOCK_BOOTTIME);
	char a[256], b[256], c[256];

	mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mount("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mount("securityfs", "/sys/kernel/security", "securityfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	kmsg = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);

	/* TSC frequency, measured against the kernel's monotonic raw clock */
	double m0 = now(CLOCK_MONOTONIC_RAW);
	uint64_t t0 = __rdtsc();
	struct timespec nap = { 0, 100 * 1000 * 1000 };
	nanosleep(&nap, NULL);
	double hz = (__rdtsc() - t0) / (now(CLOCK_MONOTONIC_RAW) - m0);
	double reset = tsc0 / hz;

	struct utsname u;
	uname(&u);
	say("==== mbaos Phase 1 boot probe (stand-in init, not the real one) ====");
	say("kernel   %s %s", u.release, u.version);
	say("machine  %s %s (firmware %s)", line("/sys/class/dmi/id/sys_vendor", a, sizeof a),
	    line("/sys/class/dmi/id/product_name", b, sizeof b), line("/sys/class/dmi/id/bios_version", c, sizeof c));
	field("/proc/cpuinfo", "model name", a, sizeof a);
	say("cpu      %s, %ld logical CPUs online, TSC %.0f MHz", a, sysconf(_SC_NPROCESSORS_ONLN), hz / 1e6);
	say("cmdline  %s", line("/proc/cmdline", a, sizeof a));

	long total = field("/proc/meminfo", "MemTotal", NULL, 0);
	long avail = field("/proc/meminfo", "MemAvailable", NULL, 0);
	say("memory   %ld MiB total, %ld MiB used", total / 1024, (total - avail) / 1024);

	DIR *d = opendir("/sys/block");
	struct dirent *e;
	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.') continue;
		snprintf(a, sizeof a, "/sys/block/%s/size", e->d_name);
		snprintf(c, sizeof c, "/sys/block/%s/device/model", e->d_name);
		long sectors = 0;
		sscanf(line(a, b, sizeof b), "%ld", &sectors);
		say("disk     %s %ld MiB %s", e->d_name, sectors / 2048, line(c, b, sizeof b));
	}
	if (d) closedir(d);

	d = opendir("/sys/class/drm");
	int shown = 0;
	while (d && (e = readdir(d))) {
		if (strncmp(e->d_name, "card", 4) != 0 || !strchr(e->d_name, '-')) continue;
		snprintf(a, sizeof a, "/sys/class/drm/%s/status", e->d_name);
		snprintf(c, sizeof c, "/sys/class/drm/%s/modes", e->d_name);
		char st[64];
		say("display  %s %s %s", e->d_name, line(a, st, sizeof st), line(c, b, sizeof b));
		shown = 1;
	}
	if (d) closedir(d);
	if (!shown) say("display  none (no DRM connector)");
	say("lockdown %s", line("/sys/kernel/security/lockdown", a, sizeof a));

	d = opendir("/sys/devices/system/cpu/vulnerabilities");
	while (d && (e = readdir(d))) {
		if (e->d_name[0] == '.') continue;
		snprintf(a, sizeof a, "/sys/devices/system/cpu/vulnerabilities/%s", e->d_name);
		say("vuln     %-28s %s", e->d_name, line(a, b, sizeof b));
	}
	if (d) closedir(d);

	say("TIME kernel->init %.3f s", kernel);
	char flags[4096];
	field("/proc/cpuinfo", "flags", flags, sizeof flags);
	int vm = strstr(flags, " hypervisor") != NULL;
	if (vm)
		say("TIME cpu-reset->init n/a (running under a hypervisor)");
	else if (reset > kernel)
		say("TIME cpu-reset->init %.3f s (firmware ~%.3f s; meaningful on real hardware only)", reset, reset - kernel);
	else
		say("TIME cpu-reset->init n/a (TSC was not reset at power-on, e.g. a VM)");
	say("done");

	if (strcmp(line("/sys/class/dmi/id/sys_vendor", a, sizeof a), "QEMU") == 0) {
		sync();
		reboot(RB_POWER_OFF);
	}
	say("waiting forever; hold the power button to turn off");
	for (;;) pause();
}
