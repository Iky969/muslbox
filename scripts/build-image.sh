#!/usr/bin/env bash
# scripts/build-image.sh -- pack distro/rootfs into a cpio.gz initramfs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DISTRO="$ROOT/distro"
ROOTFS="$DISTRO/rootfs"
IMAGE="$DISTRO/initramfs.cpio.gz"

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -d "$ROOTFS" ] || die "run make rootfs first"
command -v cpio >/dev/null || die "cpio missing"
command -v gzip >/dev/null || die "gzip missing"

log "packing initramfs"
(
	cd "$ROOTFS"
	find . -print0 | cpio --null -o -H newc --quiet | gzip -9 > "$IMAGE"
)
log "image: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
