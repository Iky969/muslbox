#!/usr/bin/env python3
"""Prove outbound HTTPS from inside MUSLBOX under QEMU.

Boots the normal image and runs the statically linked `httpsget` against two
independent endpoints.  Both TLS connections must complete with a verified
certificate and an HTTP 200 response.
"""
import os
import re
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISTRO = os.path.join(ROOT, "distro")
cmd = [
    "qemu-system-x86_64", "-nographic", "-no-reboot", "-m", "192M",
    "-kernel", os.path.join(DISTRO, "vmlinuz-virt"),
    "-initrd", os.path.join(DISTRO, "initramfs.cpio.gz"),
    "-append", "console=ttyS0 panic=-1 quiet",
    "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
]
lines, lock, eof = [], threading.Lock(), threading.Event()
proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT)


def reader():
    assert proc.stdout is not None
    for raw in proc.stdout:
        text = raw.decode("utf-8", "replace")
        with lock:
            lines.append(text)
        sys.stdout.write(text)
        sys.stdout.flush()
    eof.set()


threading.Thread(target=reader, daemon=True).start()


def wait(pattern, timeout=40):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        with lock:
            blob = "".join(lines)
        if re.search(pattern, blob, re.S):
            return True
        if eof.is_set():
            return False
        time.sleep(0.05)
    return False


def send(line):
    assert proc.stdin is not None
    proc.stdin.write((line + "\n").encode())
    proc.stdin.flush()


def section(begin, end):
    with lock:
        blob = "".join(lines)
    m = re.search(re.escape(begin) + r"\r?\n(.*?)\r?\n" + re.escape(end), blob, re.S)
    return m.group(1) if m else ""


failures = []
try:
    if not wait(r"MUSLBOX_SHELL_READY"):
        failures.append("guest shell never became ready")
    else:
        time.sleep(1.0)  # give virtio-net/link a moment after boot
        # The zen body has no trailing newline, so emit one before each end
        # marker; otherwise the marker would share a line with the body and
        # the whole-line marker regex would never match.
        send("echo HTTPS_GITHUB_BEGIN; httpsget https://api.github.com/zen; echo; echo HTTPS_GITHUB_END")
        send("echo HTTPS_EXAMPLE_BEGIN; httpsget https://example.com/; echo; echo HTTPS_EXAMPLE_END")
        for marker in ("HTTPS_GITHUB_END", "HTTPS_EXAMPLE_END"):
            if not wait(r"(?m)^" + re.escape(marker) + r"\r?$", timeout=60):
                failures.append(f"missing marker {marker}")

        github = section("HTTPS_GITHUB_BEGIN", "HTTPS_GITHUB_END")
        example = section("HTTPS_EXAMPLE_BEGIN", "HTTPS_EXAMPLE_END")
        print("\n--- https://api.github.com/zen ---\n" + github)
        print("--- https://example.com/ ---\n" + example[:800])

        blob = "".join(lines)
        if "HTTP/1.1 200" not in github:
            failures.append("github API did not return HTTP 200")
        if len(github.strip()) < 40:
            failures.append("github response body missing")
        if "HTTP/1.1 200" not in example or "Example Domain" not in example:
            failures.append("example.com response missing/incorrect")
        for bad in ("certificate verification failed", "ssl_handshake",
                    "net_connect", "cannot parse CA bundle", "not found"):
            if bad in blob:
                failures.append(f"TLS/HTTPS error seen: {bad}")
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
    print("\nHTTPS TEST FAILED:")
    for f in failures:
        print("  -", f)
    sys.exit(1)
print("\nHTTPS TEST PASSED (verified TLS to api.github.com and example.com from guest)")
