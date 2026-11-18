/*
 * bootreport — where did boot time go? (run as root after logging in)
 *
 *   CPU reset -> PID 1   TSC recorded by init / TSC frequency. The TSC counts
 *                        from CPU reset, so this includes firmware time.
 *                        Meaningless under a hypervisor (reported as n/a).
 *   kernel -> PID 1      CLOCK_BOOTTIME when init started
 *   PID 1 -> rc done     /etc/rc (remount, fstab, hostname, sysctl)
 *   -> login prompt      when svd started getty on tty1 (/run/sv/getty-tty1)
 *   largest gaps         between consecutive kernel log messages: the line
 *                        after a gap is usually what was being waited for
 *
 * Successor of the Phase 1 boot probe (tests/bootprobe.c, now retired).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <x86intrin.h>

#define MAXREC 8192
static struct { long long us; char msg[100]; } rec[MAXREC];
static int nrec;

static double clk(clockid_t c)
{
	struct timespec t;
	clock_gettime(c, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static double boot_time(const char *tag)
{
	char k[64];
	double v;
	FILE *f = fopen("/run/boot-times", "re");
	if (!f) return -1;
	while (fscanf(f, "%63s %lf", k, &v) == 2)
		if (strcmp(k, tag) == 0) { fclose(f); return v; }
	fclose(f);
	return -1;
}

static double svc_since(const char *name)
{
	char p[128], st[16];
	int pid;
	double since = -1;
	snprintf(p, sizeof p, "/run/sv/%s", name);
	FILE *f = fopen(p, "re");
	if (f) { if (fscanf(f, "%15s %d %lf", st, &pid, &since) != 3) since = -1; fclose(f); }
	return since;
}

static void read_kernel_log(void)
{
	char buf[1024];
	int fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) { fprintf(stderr, "bootreport: /dev/kmsg: %s (run as root)\n", strerror(errno)); return; }
	while (nrec < MAXREC) {
		ssize_t n = read(fd, buf, sizeof buf - 1);
		if (n < 0) { if (errno == EPIPE) continue; break; }
		buf[n] = 0;
		long long us;
		char *semi = strchr(buf, ';');
		if (!semi || sscanf(buf, "%*d,%*d,%lld", &us) != 1) continue;
		char *msg = semi + 1;
		msg[strcspn(msg, "\n")] = 0;
		rec[nrec].us = us;
		snprintf(rec[nrec].msg, sizeof rec[nrec].msg, "%s", msg);
		nrec++;
	}
	close(fd);
}

int main(int argc, char **argv)
{
	int top = argc > 1 ? atoi(argv[1]) : 10;
	double init = boot_time("init_start"), rc = boot_time("rc_done");
	double tsc = boot_time("init_tsc"), getty = svc_since("getty-tty1");

	/* TSC frequency against the kernel's raw monotonic clock */
	double m0 = clk(CLOCK_MONOTONIC_RAW);
	uint64_t t0 = __rdtsc();
	struct timespec nap = { 0, 100 * 1000 * 1000 };
	nanosleep(&nap, NULL);
	double hz = (__rdtsc() - t0) / (clk(CLOCK_MONOTONIC_RAW) - m0);

	char flags[8192] = "";
	FILE *f = fopen("/proc/cpuinfo", "re");
	if (f) {
		char l[8192];
		while (fgets(l, sizeof l, f)) if (strncmp(l, "flags", 5) == 0) { snprintf(flags, sizeof flags, "%s", l); break; }
		fclose(f);
	}
	int vm = strstr(flags, " hypervisor") != NULL;

	printf("boot timeline (seconds)\n");
	if (vm || tsc <= 0) printf("  CPU reset -> PID 1      n/a (%s)\n", vm ? "under a hypervisor" : "no init_tsc");
	else printf("  CPU reset -> PID 1      %7.3f   (firmware ~%.3f)\n", tsc / hz, tsc / hz - init);
	printf("  kernel    -> PID 1      %7.3f\n", init);
	if (rc > 0) printf("  PID 1     -> rc done    %7.3f   (at %.3f)\n", rc - init, rc);
	if (getty > 0) printf("  rc done   -> getty tty1 %7.3f   (login prompt at %.3f)\n", getty - rc, getty);

	read_kernel_log();
	printf("\nlargest gaps between kernel log messages (of %d):\n", nrec);
	static char used[MAXREC];
	for (int k = 0; k < top; k++) {
		int best = -1;
		long long bg = 0;
		for (int i = 1; i < nrec; i++) {
			long long g = rec[i].us - rec[i - 1].us;
			if (!used[i] && g > bg) { bg = g; best = i; }
		}
		if (best < 0 || bg < 20000) break;
		used[best] = 1;
		printf("  %6.3f s before [%8.3f] %.80s\n", bg / 1e6, rec[best].us / 1e6, rec[best].msg);
	}
	return 0;
}
