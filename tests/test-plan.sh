#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/bbr-tune.sh"

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || { printf 'ASSERT FAILED: missing %s\n' "$needle" >&2; exit 1; }
}

out="$($SCRIPT plan --profile hard-cap --cap-mbps 200 --bandwidth-mbps 200 --rtt-ms 30 --runtime-only)"
assert_contains "$out" "resolved_profile=hard-cap"
assert_contains "$out" "BDP：750000 bytes"
assert_contains "$out" "推荐缓冲上限：2 MiB"
assert_contains "$out" "整形速率：190 Mbps"
assert_contains "$out" "TBF burst：32768 bytes"

out="$($SCRIPT plan --profile lfn --bandwidth-mbps 1000 --rtt-ms 180 --runtime-only)"
assert_contains "$out" "resolved_profile=lfn"
assert_contains "$out" "BDP：22500000 bytes"
assert_contains "$out" "推荐缓冲上限：32 MiB"

out="$($SCRIPT plan --profile auto --bandwidth-mbps 500 --rtt-ms 180 --runtime-only)"
assert_contains "$out" "resolved_profile=lfn"

out="$($SCRIPT plan --profile auto --bandwidth-mbps 500 --rtt-ms 30 --loss-percent 3 --runtime-only)"
assert_contains "$out" "resolved_profile=lossy"

printf 'All plan tests passed.\n'
