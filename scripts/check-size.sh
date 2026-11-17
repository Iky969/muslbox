#!/usr/bin/env bash
# scripts/check-size.sh -- enforce the <50 MB image budget.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
DISTRO="$ROOT/distro"
KERNEL="$DISTRO/vmlinuz-virt"
IMAGE="$DISTRO/initramfs.cpio.gz"

for f in "$KERNEL" "$IMAGE"; do
	[ -s "$f" ] || { echo "FAIL: $f missing" >&2; exit 1; }
done

kbytes=$(stat -c %s "$KERNEL")
ibytes=$(stat -c %s "$IMAGE")
total=$((kbytes + ibytes))
limit=$((50 * 1024 * 1024))

mib() { awk -v n="$1" 'BEGIN { printf "%.1f", n/1048576 }'; }
printf 'kernel   : %8d bytes (%s MiB)\n' "$kbytes" "$(mib "$kbytes")"
printf 'initramfs: %8d bytes (%s MiB)\n' "$ibytes" "$(mib "$ibytes")"
printf 'TOTAL    : %8d bytes (%s MiB) / limit 50.0 MiB\n' "$total" "$(mib "$total")"

if [ "$total" -lt "$limit" ]; then
	printf 'PASS: image under 50 MB\n'
else
	echo "FAIL: image exceeds 50 MB" >&2
	exit 1
fi
