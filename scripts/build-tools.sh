#!/usr/bin/env bash
# scripts/build-tools.sh -- compile MUSLBOX's own C programs, statically.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BUILD="$ROOT/build"
SRC="$ROOT/src"
mkdir -p "$BUILD"

command -v musl-gcc >/dev/null || { echo "FAIL: musl-gcc missing" >&2; exit 1; }

CFLAGS="-O2 -Wall -Wextra -static -D_GNU_SOURCE"

printf '==> compiling init (musl static)\n'
musl-gcc $CFLAGS "$SRC/init.c" -o "$BUILD/init"

printf '==> compiling mbpm (musl static)\n'
musl-gcc $CFLAGS "$SRC/mbpm.c" -o "$BUILD/mbpm"

for f in init mbpm; do
	if readelf -lW "$BUILD/$f" 2>/dev/null | grep -q INTERP; then
		echo "FAIL: $f is not static" >&2
		exit 1
	fi
	printf '    %-6s %s\n' "$f" "$(du -h "$BUILD/$f" | cut -f1)"
done
