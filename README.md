# MUSLBOX

Minimal, musl-based Linux distro built entirely from source with a custom
C `PID 1`, a binary/tarball package manager, and a reproducible QEMU boot test.

This is an **independent implementation**. The S.A.N.E repo was read only as
an architectural reference (init design, package-manager shape, pinned
kernel/bootloader downloads, headless QEMU verification); no source code was
copied from it.

## Target

| Item | Target |
|---|---|
| libc | musl (static binaries only) |
| Init | custom C binary at `/sbin/init`, PID 1 |
| Package manager | `mbpm` — binary `.mbp` tarball packages |
| Image | < 50 MB (initramfs + kernel) |
| Boot to shell | < 2 s under `qemu-system-x86_64 -nographic` |
| Networking | virtio-net, DHCP via busybox `udhcpc`, `ip`, `ping`, `wget` |
| Build | single `make`, `JOBS=$(nproc)` (EC2: 2 vCPU, 7.6 GiB RAM) |

## Blueprint direktori

```
muslbox/
├── Makefile                  # orchestrator: deps -> init -> mbpm -> busybox -> rootfs -> image -> test
├── README.md                 # blueprint + arsitektur + cara pakai
├── .gitignore                # cache/, build/, distro/ tidak masuk git
├── src/
│   ├── init.c                # PID 1: mount, network, getty/shell, SIGCHLD reap, poweroff
│   └── mbpm.c                # binary package manager (C, static musl)
├── scripts/
│   ├── fetch-deps.sh         # download kernel + busybox tarball, verify sha256
│   ├── build-busybox.sh      # busybox 1.36.1, CONFIG_STATIC=y, CC=musl-gcc
│   ├── build-tools.sh        # compile init.c + mbpm.c with musl-gcc
│   ├── make-package.sh       # build a .mbp tarball package from a source dir
│   ├── build-rootfs.sh       # assemble rootfs/ from installed packages
│   ├── build-image.sh        # cpio.gz initramfs
│   ├── check-size.sh         # enforce the <50 MB budget
│   ├── test-boot.py          # headless QEMU test: uname -a, ps, ip, timing
│   └── test-package.sh       # mbpm install/remove/list/verify smoke test
├── packages/
│   ├── base/                 # /etc skeleton, hostname, hosts, resolv.conf
│   ├── busybox/              # manifest + x/ payload tree
│   ├── mbpm/                 # manifest + x/usr/bin/mbpm
│   └── hello/                # demo package: /usr/bin/hello
├── cache/                    # (ignored) pinned upstream tarballs + kernel
├── build/                    # (ignored) extracted sources, intermediate objects
└── distro/                   # (ignored) rootfs/, initramfs.cpio.gz, muslbox.img
```

## Build pipeline

```
make deps        -> cache/vmlinuz-virt, cache/busybox-1.36.1.tar.bz2  (+sha256)
make tools       -> build/init, build/mbpm          (musl-gcc -static -O2)
make busybox     -> build/busybox-install/...       (musl static)
make packages    -> distro/packages/*.mbp           (make-package.sh)
make rootfs      -> distro/rootfs/                  (mbpm install into target root)
make image       -> distro/initramfs.cpio.gz        (cpio -o -H newc | gzip -9)
make test        -> QEMU -nographic boot, assert uname/ps, measure boot time
make all         -> everything above, in order
make clean       -> remove build/ and distro/ (keep cache/ for speed)
```

`JOBS` defaults to `$(nproc)` (2 on this EC2). All upstream artifacts are
pinned by URL + SHA256 so a rebuild is byte-for-byte reproducible.

## Kenapa initramfs, bukan GPT+Limine?

S.A.N.E memakai GPT + Limine + `switch_root`. MUSLBOX sengaja memakai
**direct kernel boot dengan initramfs saja**: tidak ada partisi, tidak ada
bootloader stage, sehingga image tetap ~12 MB dan waktu boot ke shell
terukur 1.73 s (clock guest). Jalur GPT/Limine sengaja tidak dipakai di fase
ini; desain itu tetap tercatat sebagai perbandingan arsitektur.

## Format paket `.mbp`

Sebuah `.mbp` adalah `gzip`-compressed `tar` dengan struktur:

```
manifest        # NAME=, VERSION=, ARCH=, DEPENDS=, SHA256=<path>:<hash>
payload/...     # pohon file yang diinstal ke target root
```

`mbpm install` melakukan: ekstrak ke staging → verifikasi sha256 tiap file →
atomic rename ke root → tulis DB di `/var/lib/mbpm/installed/<name>`.
`mbpm remove` menghapus file dari DB dan membersihkan direktori kosong.
Tidak ada kompilasi di dalam target (binary package), berlawanan dengan
varian GLIBC self-hosting.

## Hasil verifikasi (EC2 ini: 2 vCPU, 7.6 GiB RAM)

```
kernel   : 10863616 bytes (10.4 MiB)
initramfs:  1389814 bytes ( 1.3 MiB)
TOTAL    : 12253430 bytes (11.7 MiB)   <- jauh di bawah 50 MB
[boot] guest boot-to-shell: 1.73s (budget 2.0s)

Linux muslbox 6.6.134-0-virt #1-Alpine SMP PREEMPT_DYNAMIC ... x86_64 GNU/Linux
PID   USER     TIME  COMMAND
    1 0         0:00 /init
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ... inet 10.0.2.15/24
base  busybox  hello  init  mbpm  modules
hello from MUSLBOX: Linux 6.6.134-0-virt on muslbox
```

`make test` menjalankan `qemu-system-x86_64 -nographic` secara headless dan
meng-assert semua marker di atas, termasuk waktu boot dari `/proc/uptime`
guest (bukan waktu launcher QEMU di host).
