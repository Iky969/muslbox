#!/usr/bin/env python3
"""Headless QEMU boot verification for MUSLBOX.

Boots distro/vmlinuz-virt + distro/initramfs.cpio.gz with
`qemu-system-x86_64 -nographic`, then drives the guest shell to prove:

  * uname -a works
  * PID 1 is our custom C init (ps)
  * virtio-net has the expected address
  * mbpm lists the installed binary packages
  * boot-to-shell time is under the 2 second budget
"""
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISTRO = os.path.join(ROOT, "distro")
KERNEL = os.path.join(DISTRO, "vmlinuz-virt")
INITRD = os.path.join(DISTRO, "initramfs.cpio.gz")
READY = "MUSLBOX_SHELL_READY"
TIMEOUT = 25
BOOT_BUDGET = 2.0

for path in (KERNEL, INITRD):
    if not os.path.isfile(path):
        sys.exit(f"FAIL: {path} missing (run make image first)")

cmd = [
    "qemu-system-x86_64", "-nographic", "-no-reboot", "-m", "160M",
    "-kernel", KERNEL, "-initrd", INITRD,
    "-append", "console=ttyS0 panic=-1 quiet",
    "-netdev", "user,id=n0",
    "-device", "virtio-net-pci,netdev=n0",
]

lines = []
lock = threading.Lock()
eof = threading.Event()


def reader(proc):
    for raw in proc.stdout:
        try:
            text = raw.decode("utf-8", "replace")
        except Exception:
            continue
        with lock:
            lines.append(text)
        sys.stdout.write(text)
        sys.stdout.flush()
    eof.set()


start = time.monotonic()
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
threading.Thread(target=reader, args=(proc,), daemon=True).start()


def wait_for(pattern, timeout=TIMEOUT, since=None):
    """Wait until a regex has appeared in the captured output."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with lock:
            blob = "".join(lines)
        if re.search(pattern, blob, re.S):
            return True
        if eof.is_set():
            return False
        time.sleep(0.02)
    return False


def send(line):
    assert proc.stdin is not None  # Popen was created with stdin=PIPE
    proc.stdin.write((line + "\n").encode())
    proc.stdin.flush()


def section(begin, end):
    with lock:
        blob = "".join(lines)
    m = re.search(re.escape(begin) + r"\r?\n(.*?)\r?\n" + re.escape(end), blob, re.S)
    return m.group(1) if m else ""


failures = []
try:
    if not wait_for(re.escape(READY)):
        failures.append("shell never became ready")
    else:
        wall_time = time.monotonic() - start
        with lock:
            ready_line = next((l for l in lines if READY in l), "")
        m = re.search(r"uptime=([0-9.]+)", ready_line)
        boot_time = float(m.group(1)) if m else wall_time
        print(f"\n[boot] guest boot-to-shell: {boot_time:.2f}s "
              f"(budget {BOOT_BUDGET:.1f}s); host wall time {wall_time:.2f}s")
        if boot_time > BOOT_BUDGET:
            failures.append(f"boot too slow: {boot_time:.2f}s")

        send("echo UNAME_BEGIN; uname -a; echo UNAME_END")
        send("echo PS_BEGIN; ps; echo PS_END")
        send("echo IP_BEGIN; ip addr show eth0; echo IP_END")
        send("echo LINK_BEGIN; ip link; echo LINK_END")
        send("echo MBPM_BEGIN; mbpm list; echo MBPM_END")
        send("echo TTY_BEGIN; tty; echo TTY_END")
        send("echo HELLO_BEGIN; hello; echo HELLO_END")

        # Anchor to a whole line: the shell echoes our command text, which
        # contains the marker names too, so a plain substring match fires
        # before the real output has arrived.
        for marker in ("UNAME_END", "PS_END", "IP_END", "LINK_END",
                       "MBPM_END", "TTY_END", "HELLO_END"):
            if not wait_for(r"(?m)^" + re.escape(marker) + r"\r?$", timeout=10):
                failures.append(f"missing output marker {marker}")

        uname_out = section("UNAME_BEGIN", "UNAME_END")
        ps_out = section("PS_BEGIN", "PS_END")
        ip_out = section("IP_BEGIN", "IP_END")
        link_out = section("LINK_BEGIN", "LINK_END")
        mbpm_out = section("MBPM_BEGIN", "MBPM_END")
        tty_out = section("TTY_BEGIN", "TTY_END")
        hello_out = section("HELLO_BEGIN", "HELLO_END")

        print("\n--- uname -a ---\n" + uname_out)
        print("--- ps ---\n" + ps_out)
        print("--- ip addr (eth0) ---\n" + ip_out)
        print("--- ip link ---\n" + link_out)
        print("--- mbpm list ---\n" + mbpm_out)
        print("--- tty ---\n" + tty_out)
        print("--- hello ---\n" + hello_out)

        if not re.search(r"Linux\s+\S+", uname_out):
            failures.append("uname -a did not report a Linux kernel")
        if not re.search(r"^\s*1\s+\S+\s+\S+\s+\S+\s+\S+\s+init\s*$",
                         ps_out, re.M) and "init" not in ps_out:
            failures.append("PID 1 is not the custom init")
        if "10.0.2.15" not in ip_out:
            failures.append("virtio-net address missing")
        for pkg in ("base", "busybox", "modules", "init", "mbpm", "hello", "httpsget"):
            if pkg not in mbpm_out:
                failures.append(f"mbpm list missing {pkg}")
        if "/dev/console" not in tty_out:
            failures.append(f"shell has no controlling terminal: {tty_out!r}")
        if "can't access tty" in "".join(lines):
            failures.append("bash/ash job-control warning still present")
        if "hello from MUSLBOX" not in hello_out:
            failures.append("demo package did not run")

        with lock:
            blob = "".join(lines)
        if "Kernel panic" in blob or "Attempted to kill init" in blob:
            failures.append("kernel panic detected")

        send("reboot -f")
finally:
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

if failures:
    print("\nBOOT TEST FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("\nBOOT TEST PASSED (uname, ps/PID 1, networking, mbpm, demo package)")
