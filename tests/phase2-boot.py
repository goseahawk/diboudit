#!/usr/bin/env python3
"""Phase 2 acceptance test, driven over the serial console like a person would.

Boot 1 (fresh copy of build/mbaos.img):
  first-boot setup (root password + user "alice") -> login prompt -> log in ->
  check PID 1, services, ownership, mounts, zombie reaping, service restart,
  crash back-off, logging, bootreport -> poweroff (clean: root remounted ro)
Boot 2 (same disk):
  no first-boot prompt, filesystem was clean (no journal recovery), idle
  metrics collected without touching the keyboard, login with the password set
  in boot 1, /home/alice exists -> reboot (firmware starts again)

Idle metrics from boot 2 are appended to metrics/history.csv and compared with
the previous run in the same environment; regressions are flagged.
"""
import csv
import datetime
import os
import re
import select
import shutil
import subprocess
import sys
import time

TOP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.environ.get("BUILD", os.path.join(TOP, "build"))
OUT = os.path.join(BUILD, "phase2")
PW = "mbaos-test-pw"
KVM = os.access("/dev/kvm", os.W_OK)
SLOW = 1 if KVM else 4          # TCG emulation is several times slower


class Fail(Exception):
    pass


class VM:
    def __init__(self, image, log):
        self.p = subprocess.Popen(
            ["bash", os.path.join(TOP, "scripts", "qemu.sh"), "--disk", image, "--raw"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.buf = ""
        self.pos = 0          # matches are searched after the previous match
        self.t0 = time.monotonic()
        self.log = open(log, "w")
        self.n = 0

    def _read(self, timeout):
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return False
        data = os.read(self.p.stdout.fileno(), 65536)
        if not data:
            raise Fail("QEMU exited unexpectedly")
        text = data.decode("utf-8", "replace").replace("\r", "")
        self.buf += text
        self.log.write(text)
        self.log.flush()
        return True

    def expect(self, pattern, timeout, what=None):
        rx = re.compile(pattern)
        end = time.monotonic() + timeout * SLOW
        while True:
            m = rx.search(self.buf, self.pos)
            if m:
                self.pos = m.end()
                return m
            left = end - time.monotonic()
            if left <= 0:
                tail = self.buf[-1500:]
                raise Fail(f"timed out waiting for {what or pattern!r}; last output:\n{tail}")
            self._read(min(left, 1.0))

    def send(self, text):
        self.p.stdin.write(text.encode())
        self.p.stdin.flush()

    def run(self, cmd, timeout=60):
        """Run a shell command, return (exit status, output)."""
        self.n += 1
        tag = f"@@{self.n}@@"
        # The marker is split in the command so the shell's echo cannot match it.
        self.send(f"{cmd}; echo \"@@{self.n}\"'@@'$?\n")
        start = self.pos
        m = self.expect(re.escape(tag) + r"(\d+)", timeout, f"end of: {cmd}")
        out = self.buf[start:m.start()]
        return int(m.group(1)), out

    def wait_exit(self, timeout):
        end = time.monotonic() + timeout * SLOW
        while self.p.poll() is None and time.monotonic() < end:
            try:
                self._read(0.5)
            except Fail:        # end of output: QEMU is exiting; give it time to be reaped
                try:
                    self.p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass
                break
        if self.p.poll() is None:
            self.p.kill()
            raise Fail("QEMU did not exit")

    def kill(self):
        if self.p.poll() is None:
            self.p.kill()
            self.p.wait()
        self.log.close()


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {name}" + (f"   [{detail}]" if detail and not ok else ""))
    sys.stdout.flush()


def login(vm, user, pw):
    vm.expect(r"login: $|login: ", 120, "login prompt")
    vm.send(user + "\n")
    vm.expect(r"Password: ", 30, "password prompt")
    vm.send(pw + "\n")
    vm.expect(rf"{user}@mba:[^\n]*[#$] ", 60, "shell prompt")


def boot1(img):
    print("Boot 1: first-boot setup, login, init/supervisor behaviour, power off")
    vm = VM(img, os.path.join(OUT, "boot1.log"))
    try:
        vm.expect(r"Press Enter to set up", 300, "first-boot prompt")
        check("first-boot setup offered on the console", True)
        vm.send("\n")
        for _ in range(2):  # root password, twice
            vm.expect(r"New password: ", 60)
            vm.send(PW + "\n")
            vm.expect(r"Retype password: ", 30)
            vm.send(PW + "\n")
            if _ == 0:
                vm.expect(r"press Enter to skip: ", 60, "user prompt")
                vm.send("alice\n")
        vm.expect(r"Setup complete", 60)
        check("root password set, user alice created", True)

        login(vm, "root", PW)
        check("root can log in with the new password", True)

        st, out = vm.run("cat /proc/1/comm")
        check("PID 1 is our init", "init" in out, out)
        st, out = vm.run("sv status")
        check("svd runs getty-tty1 and getty-ttyS0", re.search(r"getty-tty1 +run", out) and re.search(r"getty-ttyS0 +run", out), out)
        st, out = vm.run("id alice")
        check("user alice exists", st == 0 and "uid=1000(alice)" in out, out)
        st, out = vm.run("grep ' / ' /proc/mounts")
        check("root mounted read-write, noatime", "rw,noatime" in out, out)
        st, out = vm.run("stat -c '%a %u %g' /etc/shadow /usr/bin/busybox /usr/sbin/init")
        check("files owned by root; /etc/shadow mode 600", out.split()[-9:] == ["600", "0", "0", "755", "0", "0", "755", "0", "0"], out)
        st, out = vm.run("dmesg | grep -c 'init: /etc/rc failed'")
        check("/etc/rc succeeded", out.strip().endswith("0"), out)

        # Zombie reaping: an orphan is re-parented to PID 1 and reaped when it exits.
        st, out = vm.run("sh -c 'sleep 4 & echo ORPHAN=$!'")   # sh exits; its child is orphaned
        m = re.search(r"ORPHAN=(\d+)", out)
        pid = m.group(1) if m else "0"
        st, out = vm.run(f"awk '/^PPid/{{print \"PPID=\"$2}}' /proc/{pid}/status")
        check("orphaned process re-parented to PID 1", "PPID=1" in out, out)
        st, out = vm.run(f"sleep 5; [ -e /proc/{pid} ] && echo STILL || echo GONE; grep -l '^State:.*Z' /proc/[0-9]*/status 2>/dev/null | wc -l")
        check("orphan reaped, no zombies on the system", "GONE" in out and out.strip().endswith("0"), out)

        # Supervisor: restart on request.
        st, out = vm.run("cat /run/sv/getty-tty1")
        before = out.split()
        vm.run("sv restart getty-tty1; sleep 2")
        st, out = vm.run("cat /run/sv/getty-tty1")
        after = out.split()
        check("sv restart: new process, still running",
              len(before) > 2 and len(after) > 2 and after[-5] == "run" and after[-4] != before[-4], f"{before} -> {after}")

        # Supervisor: a crashing service is restarted with back-off, not in a loop.
        vm.run("mkdir -p /etc/sv/crashy && printf '#!/bin/sh\\necho crashing\\nexit 1\\n' > /etc/sv/crashy/run && chmod +x /etc/sv/crashy/run && sv start crashy")
        vm.run("sleep 9", timeout=60)
        st, out = vm.run("cut -d' ' -f4 /run/sv/crashy; dmesg | grep -c 'crashy: crashing'")
        nums = [int(x) for x in re.findall(r"^(\d+)$", out, re.M)]
        restarts = nums[0] if nums else -1
        check("crashing service restarted with back-off (1,2,4 s...)", 2 <= restarts <= 5, f"restarts={restarts} out={out!r}")
        check("service output reaches the kernel log", len(nums) > 1 and nums[1] >= 2, out)
        vm.run("sv stop crashy; rm -rf /etc/sv/crashy")

        st, out = vm.run("bootreport 5")
        check("bootreport works", "kernel    -> PID 1" in out, out)

        vm.send("poweroff\n")
        vm.expect(r"init: power off: root filesystem remounted read-only", 60, "clean unmount message")
        check("poweroff: services stopped, root remounted read-only", True)
        vm.wait_exit(60)
        check("poweroff: machine turned off", True)
    finally:
        vm.kill()


def boot2(img):
    print("Boot 2: persistence, clean filesystem, idle metrics, reboot")
    vm = VM(img, os.path.join(OUT, "boot2.log"))
    metrics = {}
    try:
        vm.expect(r"login: ", 300, "login prompt")
        check("no first-boot prompt the second time", "Press Enter to set up" not in vm.buf)
        check("filesystem was clean (no journal recovery)", "recovery complete" not in vm.buf)
        # Do not type anything until the idle measurement is done.
        m = vm.expect(r"mbaos-metrics ([^\n]*)\n", 180, "idle metrics")
        metrics = dict(kv.split("=", 1) for kv in m.group(1).split())
        check("idle metrics collected", "idle_mem_used_mib" in metrics, m.group(0))
        vm.send("\n")      # the login prompt was printed before the metrics line
        login(vm, "root", PW)
        check("password from boot 1 persisted", True)
        st, out = vm.run("ls -d /home/alice && stat -c '%U' /home/alice")
        check("alice's home directory persisted, owned by alice", "alice" in out.split()[-1], out)
        st, out = vm.run("bootreport")
        with open(os.path.join(OUT, "bootreport.txt"), "w") as f:
            f.write(out)
        vm.send("reboot\n")
        vm.expect(r"init: reboot: now", 60, "reboot")
        vm.expect(r"BdsDxe: (loading|starting) Boot", 120, "firmware after reboot")
        check("reboot: clean shutdown, firmware starts again", True)
    finally:
        vm.kill()
    return metrics


def record(metrics):
    env = "qemu-kvm" if KVM else "qemu-tcg"
    path = os.path.join(TOP, "metrics", "history.csv")
    fields = ["date", "commit", "env", "boot_to_login_s", "idle_mem_used_mib", "irq_per_s", "timer_irq_per_s", "ctxt_per_s", "procs", "user_procs"]
    commit = subprocess.run(["git", "-C", TOP, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip() or "?"
    dirty = subprocess.run(["git", "-C", TOP, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip()
    row = {"date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M"),
           "commit": commit + ("+" if dirty else ""), "env": env}
    row.update({k: metrics.get(k, "") for k in fields[3:]})
    prev = None
    if os.path.exists(path):
        with open(path) as f:
            for r in csv.DictReader(f):
                if r["env"] == env:
                    prev = r
    print(f"\nIdle metrics ({env}): " + "  ".join(f"{k}={row[k]}" for k in fields[3:]))
    # Regression rules: worse by more than the slack is flagged.
    rules = {"boot_to_login_s": (0.20, 0.3), "idle_mem_used_mib": (0.10, 5), "irq_per_s": (0.50, 20),
             "ctxt_per_s": (0.50, 20), "user_procs": (0, 1)}
    flags = []
    if prev:
        for k, (rel, absolute) in rules.items():
            try:
                old, new = float(prev[k]), float(row[k])
            except (ValueError, KeyError):
                continue
            if new > old * (1 + rel) and new - old > absolute:
                flags.append(f"{k}: {old:g} -> {new:g}")
    if flags:
        print("REGRESSION FLAGGED vs previous " + env + " run (" + prev["commit"] + "): " + "; ".join(flags))
    elif prev:
        print(f"no regressions vs previous {env} run ({prev['commit']})")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    new_file = not os.path.exists(path)
    with open(path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        if new_file:
            w.writeheader()
        w.writerow(row)
    print(f"recorded in {os.path.relpath(path, TOP)}")


def main():
    src = os.path.join(BUILD, "mbaos.img")
    if not os.path.exists(src):
        sys.exit("no image; run ./build.sh image")
    os.makedirs(OUT, exist_ok=True)
    img = os.path.join(OUT, "test.img")
    shutil.copyfile(src, img)       # first boot modifies the disk; keep the release image pristine
    if not KVM:
        print("(no /dev/kvm: TCG emulation, timeouts x4, timing numbers not representative)")
    metrics = {}
    try:
        boot1(img)
        metrics = boot2(img)
    except Fail as e:
        check("test run", False, str(e))
    if metrics:
        record(metrics)
    failed = results.count(False)
    print(f"\n{len(results) - failed}/{len(results)} checks passed" + ("" if not failed else "  (logs: build/phase2/boot*.log)"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
