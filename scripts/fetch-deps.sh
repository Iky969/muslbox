#!/usr/bin/env bash
# scripts/fetch-deps.sh -- download + verify every upstream artifact.
# Pinned by URL and SHA256 so repeated builds are reproducible.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CACHE="$ROOT/cache"
DISTRO="$ROOT/distro"
mkdir -p "$CACHE" "$DISTRO"

KERNEL_URL=${KERNEL_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot-3.20.10/vmlinuz-virt}
KERNEL_SHA=be523954ad673a78c9cdfd3d473a8d39609f5901adfcc68402c67dc037a64c7e
BB_URL=${BB_URL:-https://busybox.net/downloads/busybox-1.36.1.tar.bz2}
BB_SHA=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
MODLOOP_URL=${MODLOOP_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot-3.20.10/modloop-virt}
MODLOOP_SHA=a6ed1699b1c8c863fe57543263480ee3835c083b8202251d3919d1817a3c5358
MBEDTLS_URL=${MBEDTLS_URL:-https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.8/mbedtls-3.6.8.tar.bz2}
MBEDTLS_SHA=bc54b818e87f49c0b3281dd85d24adaede0e63b4e822e3fbd49c005a38b9595b

log() { printf '==> %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fetch_verify() { # url sha dest
	local url=$1 sha=$2 dest=$3 actual
	if [ -s "$dest" ]; then
		actual=$(sha256sum "$dest" | cut -d' ' -f1)
		if [ "$actual" = "$sha" ]; then
			printf '    cached: %s\n' "$(basename "$dest")"
			return 0
		fi
		printf '    rejecting bad cached file %s\n' "$dest" >&2
		rm -f "$dest"
	fi
	log "downloading $(basename "$dest")"
	curl -fL --retry 3 --connect-timeout 15 -o "$dest.part" "$url" \
		|| die "download failed: $url"
	actual=$(sha256sum "$dest.part" | cut -d' ' -f1)
	[ "$actual" = "$sha" ] || die "checksum mismatch for $(basename "$dest")
  expected $sha
  got      $actual"
	mv "$dest.part" "$dest"
	printf '    verified sha256 %s\n' "${sha:0:12}..."
}

fetch_verify "$KERNEL_URL" "$KERNEL_SHA" "$CACHE/vmlinuz-virt"
fetch_verify "$BB_URL" "$BB_SHA" "$CACHE/busybox-1.36.1.tar.bz2"
fetch_verify "$MODLOOP_URL" "$MODLOOP_SHA" "$CACHE/modloop-virt"
fetch_verify "$MBEDTLS_URL" "$MBEDTLS_SHA" "$CACHE/mbedtls-3.6.8.tar.bz2"

cp "$CACHE/vmlinuz-virt" "$DISTRO/vmlinuz-virt"
log "deps ready ($(du -h "$DISTRO/vmlinuz-virt" | cut -f1) kernel)"
