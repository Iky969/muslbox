#!/usr/bin/env bash
# scripts/build-mbedtls.sh -- static mbedTLS + httpsget for MUSLBOX.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CACHE="$ROOT/cache"
BUILD="$ROOT/build"
VERSION=3.6.8
SRC="$BUILD/mbedtls-$VERSION"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -s "$CACHE/mbedtls-$VERSION.tar.bz2" ] || die "run make deps first"

if [ ! -d "$SRC" ]; then
	log "extracting mbedtls $VERSION"
	tar -xjf "$CACHE/mbedtls-$VERSION.tar.bz2" -C "$BUILD"
fi

if [ ! -f "$SRC/library/libmbedtls.a" ]; then
	log "building mbedTLS libraries with musl-gcc -j$JOBS"
	make -C "$SRC/library" -j"$JOBS" CC=musl-gcc \
		CFLAGS='-O2 -D_FILE_OFFSET_BITS=64' >/dev/null
fi
for lib in mbedtls mbedx509 mbedcrypto; do
	[ -f "$SRC/library/lib$lib.a" ] || die "lib$lib.a missing"
done

log "linking httpsget statically"
musl-gcc -O2 -Wall -Wextra -static -I"$SRC/include" \
	"$ROOT/src/httpsget.c" \
	"$SRC/library/libmbedtls.a" \
	"$SRC/library/libmbedx509.a" \
	"$SRC/library/libmbedcrypto.a" \
	-o "$BUILD/httpsget"

if readelf -lW "$BUILD/httpsget" | grep -q INTERP; then
	die "httpsget is dynamically linked"
fi
printf '    httpsget %s musl-static, %s\n' "$VERSION" "$(du -h "$BUILD/httpsget" | cut -f1)"
