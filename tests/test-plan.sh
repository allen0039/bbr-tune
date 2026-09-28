#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
assert_true() { "$@" || fail "assertion failed: $*"; }

# The aggregate TCP memory high-water mark uses two thirds of effective total
# memory. MemAvailable does not participate in this calculation.
calculate_memory_buffer_cap 1024
assert_eq "$MEM_TCP_BUDGET_MIB" "682" "1 GiB aggregate TCP budget"
assert_eq "$MEM_BUFFER_CAP_MIB" "682" "1 GiB per-socket search cap"
low_1g="$TCP_MEM_LOW_PAGES"; pressure_1g="$TCP_MEM_PRESSURE_PAGES"; high_1g="$TCP_MEM_HIGH_PAGES"
(( low_1g < pressure_1g && pressure_1g < high_1g )) || fail "tcp_mem thresholds must be strictly increasing"
expected_high=$(( 1024 * 1048576 / PAGE_SIZE_BYTES * 2 / 3 ))
assert_eq "$high_1g" "$expected_high" "1 GiB tcp_mem high-water mark"

calculate_memory_buffer_cap 8192
assert_eq "$MEM_TCP_BUDGET_MIB" "5461" "8 GiB aggregate TCP budget"
assert_eq "$MEM_BUFFER_CAP_MIB" "2047" "8 GiB signed-sysctl per-socket ceiling"

calculate_memory_buffer_cap 65536
assert_eq "$MEM_TCP_BUDGET_MIB" "43690" "64 GiB aggregate TCP budget"
assert_eq "$MEM_BUFFER_CAP_MIB" "2047" "large-memory per-socket ceiling"

calculate_memory_buffer_cap 256
assert_eq "$MEM_TCP_BUDGET_MIB" "170" "256 MiB aggregate TCP budget"
assert_eq "$MEM_BUFFER_CAP_MIB" "170" "256 MiB per-socket search cap"

TARGET_MBPS="1000"
RTT_MS="180"
MEM_BUFFER_CAP_MIB="128"
calculate_bdp
assert_eq "$BDP_BYTES" "22500000" "BDP bytes"
assert_eq "$BDP_MIB" "21.46" "BDP MiB"
generate_candidates
assert_eq "${CANDIDATE_MIBS[*]}" "32 64 128" "unbounded growth candidates to memory cap"
assert_eq "${CANDIDATE_FACTORS[*]}" "1.49 2.98 5.97" "actual candidate BDP ratios"

# A non-power-of-two technical limit must still be tested as the final
# candidate instead of stopping at the previous power of two.
MEM_BUFFER_CAP_MIB="682"
generate_candidates
assert_eq "${CANDIDATE_MIBS[*]}" "32 64 128 256 512 682" "non-power-of-two final candidate"

TARGET_MBPS="200"
RTT_MS="30"
MEM_BUFFER_CAP_MIB="170"
calculate_bdp
assert_eq "$BDP_BYTES" "750000" "short-link BDP"
generate_candidates
assert_eq "${CANDIDATE_MIBS[*]}" "4 8 16 32 64 128 170" "growth continues to the calculated cap"

printf 'All memory-plan tests passed.\n'
