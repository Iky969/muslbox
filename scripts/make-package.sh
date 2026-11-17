#!/usr/bin/env bash
# scripts/make-package.sh -- build a .mbp binary package from a payload dir.
#
# Usage: make-package.sh <srcdir> <name> <version> <outdir> [depends]
# The .mbp is a gzip tarball: manifest + payload/ tree.  Every regular file
# in the payload is recorded with its SHA256 so mbpm can verify on install.
set -euo pipefail

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ $# -ge 4 ] || die "usage: $0 <srcdir> <name> <version> <outdir> [depends]"
SRC=$1 NAME=$2 VERSION=$3 OUTDIR=$4 DEPENDS=${5:-}
[ -d "$SRC" ] || die "source dir not found: $SRC"
mkdir -p "$OUTDIR"

WORK=$(mktemp -d /tmp/mbpmake.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/payload"
cp -a "$SRC"/. "$WORK/payload"/

MANIFEST="$WORK/manifest"
{
	printf 'NAME=%s\n' "$NAME"
	printf 'VERSION=%s\n' "$VERSION"
	printf 'ARCH=x86_64\n'
	printf 'DEPENDS=%s\n' "$DEPENDS"
	( cd "$WORK/payload" && find . -type f -print | LC_ALL=C sort ) | while read -r f; do
		rel=${f#./}
		sum=$(sha256sum "$WORK/payload/$rel" | cut -d' ' -f1)
		printf 'SHA256=%s:%s\n' "$rel" "$sum"
	done
} > "$MANIFEST"

OUT="$OUTDIR/$NAME-$VERSION.mbp"
tar -czf "$OUT" -C "$WORK" manifest payload
log "built $(basename "$OUT") ($(du -h "$OUT" | cut -f1), $(grep -c '^SHA256=' "$MANIFEST") files)"
