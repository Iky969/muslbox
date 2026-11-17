#!/usr/bin/env bash
# scripts/build-rootfs.sh -- install .mbp packages into a clean target root
# using MUSLBOX's own package manager (a real dogfooding step).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BUILD="$ROOT/build"
DISTRO="$ROOT/distro"
ROOTFS="$DISTRO/rootfs"
PKGDIR="$DISTRO/packages"
MBPM="$BUILD/mbpm"

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$MBPM" ] || die "run make tools first"
[ -d "$PKGDIR" ] || die "run make packages first"

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

log "initialising mbpm database in $ROOTFS"
"$MBPM" -r "$ROOTFS" init

for pkg in base busybox modules init mbpm hello; do
	archive=$(find "$PKGDIR" -maxdepth 1 -name "$pkg-*.mbp" -print -quit)
	[ -n "$archive" ] || die "missing package: $pkg"
	log "installing $(basename "$archive")"
	"$MBPM" -r "$ROOTFS" install "$archive"
done

log "installed packages:"
"$MBPM" -r "$ROOTFS" list

# Device nodes for the serial console.  devtmpfs mounted by PID 1 will
# provide the rest at boot; these make the image bootable even without it.
mkdir -p "$ROOTFS/dev"
for spec in "console c 5 1" "null c 1 3" "zero c 1 5"; do
	set -- $spec
	[ -e "$ROOTFS/dev/$1" ] || sudo mknod -m 666 "$ROOTFS/dev/$1" "$2" "$3" 2>/dev/null || true
done

[ -x "$ROOTFS/sbin/init" ] || die "/sbin/init missing"
[ -x "$ROOTFS/bin/sh" ] || die "/bin/sh missing"
log "rootfs ready ($(du -sh "$ROOTFS" | cut -f1))"
