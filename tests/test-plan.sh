#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

# The buffer budget is based only on total/effective memory, not currently
# available memory. The second argument is deliberately ignored for backward
# compatibility with older tests and callers.
calculate_memory_buffer_cap 1024 64
assert_eq "$MEM_BUFFER_CAP_MIB" "16" "1 GiB total-memory cap"
calculate_memory_buffer_cap 8192 64
assert_eq "$MEM_BUFFER_CAP_MIB" "128" "8 GiB total-memory cap ignores available memory"
calculate_memory_buffer_cap 65536 64
assert_eq "$MEM_BUFFER_CAP_MIB" "1024" "large-memory safety ceiling"
calculate_memory_buffer_cap 256 8
assert_eq "$MEM_BUFFER_CAP_MIB" "4" "small-memory floor"

TARGET_MBPS="1000"
RTT_MS="180"
MEM_BUFFER_CAP_MIB="128"
calculate_bdp
assert_eq "$BDP_BYTES" "22500000" "BDP bytes"
assert_eq "$BDP_MIB" "21.46" "BDP MiB"
generate_candidates
assert_eq "${CANDIDATE_MIBS[*]}" "32 64 128" "unbounded growth candidates to memory cap"
assert_eq "${CANDIDATE_FACTORS[*]}" "1.49 2.98 5.97" "actual candidate BDP ratios"

TARGET_MBPS="200"
RTT_MS="30"
MEM_BUFFER_CAP_MIB="16"
calculate_bdp
assert_eq "$BDP_BYTES" "750000" "short-link BDP"
generate_candidates
assert_eq "${CANDIDATE_MIBS[*]}" "4 8 16" "growth continues without a candidate count limit"

candidate_regressed 104.0 105.0 || fail "material score regression"
if candidate_regressed 104.7 105.0; then fail "minor score noise must not trigger rollback"; fi

printf 'All memory-plan tests passed.\n'
