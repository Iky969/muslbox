#!/usr/bin/env bash
# scripts/test-package.sh -- host-side smoke test of the mbpm binary.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
BUILD="$ROOT/build"
DISTRO="$ROOT/distro"
[ -x "$BUILD/mbpm" ] || { echo "FAIL: run make tools first" >&2; exit 1; }

T=$(mktemp -d /tmp/mbpm-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
MBPM="$BUILD/mbpm"

printf '==> mbpm init\n'
"$MBPM" -r "$T" init

for pkg in base busybox modules init mbpm hello; do
	a=$(find "$DISTRO/packages" -maxdepth 1 -name "$pkg-*.mbp" -print -quit)
	[ -n "$a" ] || { echo "FAIL: missing $pkg package" >&2; exit 1; }
	"$MBPM" -r "$T" install "$a"
done

printf '==> mbpm list\n'
"$MBPM" -r "$T" list > "$T/list.out"
cat "$T/list.out"
for pkg in base busybox modules init mbpm hello; do
	grep -qx "$pkg" "$T/list.out" || { echo "FAIL: $pkg not listed" >&2; cat "$T/list.out"; exit 1; }
done

printf '==> mbpm verify hello\n'
"$MBPM" -r "$T" verify hello

printf '==> mbpm info hello\n'
"$MBPM" -r "$T" info hello > "$T/info.out"
grep -q '^NAME=hello' "$T/info.out"

printf '==> mbpm query /usr/bin/hello\n'
"$MBPM" -r "$T" query usr/bin/hello > "$T/query.out"
grep -q hello "$T/query.out"

printf '==> mbpm remove hello\n'
"$MBPM" -r "$T" remove hello
[ ! -e "$T/usr/bin/hello" ] || { echo "FAIL: file not removed" >&2; exit 1; }
"$MBPM" -r "$T" list | grep -qx hello && { echo "FAIL: DB entry not removed" >&2; exit 1; } || true

printf 'PASS: mbpm install/list/info/verify/query/remove\n'
