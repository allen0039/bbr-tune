#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

calculate_memory_buffer_cap 1024 512
assert_eq "$MEM_BUFFER_CAP_MIB" "16" "1 GiB memory cap"
calculate_memory_buffer_cap 8192 4096
assert_eq "$MEM_BUFFER_CAP_MIB" "128" "8 GiB memory cap"
calculate_memory_buffer_cap 65536 32768
assert_eq "$MEM_BUFFER_CAP_MIB" "256" "large memory ceiling"
calculate_memory_buffer_cap 256 64
assert_eq "$MEM_BUFFER_CAP_MIB" "4" "small memory floor"

TARGET_MBPS="1000"
RTT_MS="180"
MEM_BUFFER_CAP_MIB="128"
MAX_CANDIDATES="4"
calculate_bdp
assert_eq "$BDP_BYTES" "22500000" "BDP bytes"
assert_eq "$BDP_MIB" "21.46" "BDP MiB"
generate_candidates
assert_eq "${CANDIDATE_MIBS[*]}" "32 64 128" "memory-aware candidate list"
assert_eq "${CANDIDATE_FACTORS[*]}" "1.0 1.5 3.0" "candidate factors"

TARGET_MBPS="200"
RTT_MS="30"
MEM_BUFFER_CAP_MIB="16"
calculate_bdp
assert_eq "$BDP_BYTES" "750000" "short-link BDP"
generate_candidates
assert_eq "${CANDIDATE_MIBS[0]}" "4" "minimum candidate"

printf 'All memory-plan tests passed.\n'
