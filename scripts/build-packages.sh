#!/usr/bin/env bash
# scripts/build-packages.sh -- assemble payload trees and build all .mbp files.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BUILD="$ROOT/build"
DISTRO="$ROOT/distro"
PKGROOT="$ROOT/packages"
SRC="$BUILD/packagesrc"
OUT="$DISTRO/packages"
mkdir -p "$SRC" "$OUT"

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$BUILD/busybox-1.36.1/busybox" ] || die "run make busybox first"
[ -x "$BUILD/mbpm" ] || die "run make tools first"
[ -x "$BUILD/init" ] || die "run make tools first"

# base: /etc skeleton
rm -rf "$SRC/base" "$SRC/busybox" "$SRC/init" "$SRC/mbpm" "$SRC/hello" "$SRC/modules"
mkdir -p "$SRC/base" "$SRC/busybox" "$SRC/init" "$SRC/mbpm" "$SRC/hello" "$SRC/modules"
cp -a "$PKGROOT/base/x/." "$SRC/base/"
cp -a "$BUILD/busybox-install/." "$SRC/busybox/"

# kernel modules needed for virtio-net under QEMU (extracted from Alpine modloop)
command -v unsquashfs >/dev/null || die "unsquashfs missing (apt install squashfs-tools)"
MODROOT="$BUILD/modloop-extract"
rm -rf "$MODROOT"
mkdir -p "$MODROOT" "$SRC/modules/lib/modules"
unsquashfs -f -d "$MODROOT" "$ROOT/cache/modloop-virt" \
	modules/6.6.134-0-virt/kernel/net/core/failover.ko \
	modules/6.6.134-0-virt/kernel/drivers/net/net_failover.ko \
	modules/6.6.134-0-virt/kernel/drivers/net/virtio_net.ko >/dev/null
find "$MODROOT" -name '*.ko' -exec cp {} "$SRC/modules/lib/modules/" \;

# init: /sbin/init plus the /init symlink the kernel executes in an initramfs
mkdir -p "$SRC/init/sbin"
cp "$BUILD/init" "$SRC/init/sbin/init"
chmod 0755 "$SRC/init/sbin/init"
ln -s /sbin/init "$SRC/init/init"

# mbpm binary
mkdir -p "$SRC/mbpm/usr/bin"
cp "$BUILD/mbpm" "$SRC/mbpm/usr/bin/mbpm"
chmod 0755 "$SRC/mbpm/usr/bin/mbpm"

# demo package
cp -a "$PKGROOT/hello/x/." "$SRC/hello/"

log "building binary packages"
bash "$ROOT/scripts/make-package.sh" "$SRC/base"     base     0.1 "$OUT"
bash "$ROOT/scripts/make-package.sh" "$SRC/busybox"  busybox  1.36.1 "$OUT"
bash "$ROOT/scripts/make-package.sh" "$SRC/modules"  modules  0.1 "$OUT"
bash "$ROOT/scripts/make-package.sh" "$SRC/init"     init     0.1 "$OUT" "busybox"
bash "$ROOT/scripts/make-package.sh" "$SRC/mbpm"     mbpm     0.1 "$OUT" "busybox"
bash "$ROOT/scripts/make-package.sh" "$SRC/hello"    hello    0.1 "$OUT" "busybox"

ls -lh "$OUT"/*.mbp
