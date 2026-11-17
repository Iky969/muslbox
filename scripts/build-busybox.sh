#!/usr/bin/env bash
# scripts/build-busybox.sh -- busybox 1.36.1 built statically against musl.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CACHE="$ROOT/cache"
BUILD="$ROOT/build"
BB_VERSION=1.36.1
SRC="$BUILD/busybox-$BB_VERSION"
PREFIX="$BUILD/busybox-install"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}

log() { printf '==> %s\n' "$1"; }

[ -s "$CACHE/busybox-$BB_VERSION.tar.bz2" ] || { echo "FAIL: run make deps first" >&2; exit 1; }

if [ ! -d "$SRC" ]; then
	log "extracting busybox $BB_VERSION"
	mkdir -p "$BUILD"
	tar -xjf "$CACHE/busybox-$BB_VERSION.tar.bz2" -C "$BUILD"
fi

if [ ! -f "$SRC/.config" ]; then
	log "make defconfig"
	( cd "$SRC" && make defconfig >/dev/null )
fi

# CONFIG_STATIC is off in defconfig; force it on every run so a stale tree
# cannot silently produce a dynamic binary.  CONFIG_TC is disabled because
# its CBQ definitions no longer exist in recent kernel headers and we do
# not need `tc` in this image.
set_opt() { # $1=CONFIG_X $2=y|n
	sed -i -e "/^$1=y\$/d" -e "/^# $1 is not set\$/d" "$SRC/.config"
	if [ "$2" = y ]; then printf '%s=y\n' "$1" >> "$SRC/.config";
	else printf '# %s is not set\n' "$1" >> "$SRC/.config"; fi
}
set_opt CONFIG_STATIC y
set_opt CONFIG_TC n
set_opt CONFIG_FEATURE_SH_STANDALONE y
( cd "$SRC" && make oldconfig </dev/null >/dev/null 2>&1 ) || true
grep -q '^CONFIG_STATIC=y' "$SRC/.config" || { echo "FAIL: CONFIG_STATIC not set" >&2; exit 1; }

# musl-gcc searches only the musl include dir, not /usr/include, so <linux/*.h>
# is invisible.  Expose the kernel UAPI headers through a private include dir
# instead of adding -I/usr/include (which would pull in glibc headers).
KHDR="$BUILD/kheaders"
mkdir -p "$KHDR"
for d in linux asm-generic scsi mtd; do
	[ -e "/usr/include/$d" ] && ln -sfn "/usr/include/$d" "$KHDR/$d"
done
# Debian keeps the arch-specific UAPI headers under a multiarch directory.
for d in /usr/include/*/asm; do
	[ -d "$d" ] && ln -sfn "$d" "$KHDR/asm" && break
done

log "compiling busybox with musl-gcc -j$JOBS"
( cd "$SRC" && make -j"$JOBS" CC="musl-gcc -I$KHDR" LDFLAGS=-static )

if readelf -lW "$SRC/busybox" 2>/dev/null | grep -q INTERP; then
	echo "FAIL: busybox is dynamically linked" >&2
	exit 1
fi

log "installing to $PREFIX"
rm -rf "$PREFIX"
( cd "$SRC" && make CONFIG_PREFIX="$PREFIX" install >/dev/null )

# Assert the applets MUSLBOX depends on actually exist.
for applet in sh ash ip udhcpc ping wget tar gzip sha256sum ps uname cp rm mkdir ls cat mount umount hostname dmesg; do
	grep -qx "$applet" <("$SRC/busybox" --list) \
		|| { echo "FAIL: busybox applet missing: $applet" >&2; exit 1; }
done
printf '    busybox %s musl-static, %s\n' "$BB_VERSION" "$(du -h "$SRC/busybox" | cut -f1)"
