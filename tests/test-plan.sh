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
assert_eq "$VM_MIN_FREE_KBYTES" "83886" "8 GiB adaptive min_free_kbytes"

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


# The generated profile includes the requested dedicated-proxy kernel, VM,
# queue, TCP, PMTU, neighbour and ARP settings while keeping socket limits
# tied to the measured candidate.
TUNING_QDISC="cake"
MEM_EFFECTIVE_MIB="8192"; MEM_TCP_BUDGET_MIB="5461"; MEM_BUFFER_CAP_MIB="2047"
VM_MIN_FREE_KBYTES="83886"; TCP_MEM_LOW_PAGES="699050"; TCP_MEM_PRESSURE_PAGES="1048576"; TCP_MEM_HIGH_PAGES="1398101"
TARGET_MBPS="1000"; RTT_MS="180"; BDP_MIB="21.46"
profile="$(build_sysctl_content 67108864)"
for expected in \
  'kernel.pid_max = 65535' \
  'kernel.panic = 1' \
  'vm.min_free_kbytes = 83886' \
  'net.core.default_qdisc = cake' \
  'net.core.rmem_max = 67108864' \
  'net.ipv4.tcp_rmem = 8192 87380 67108864' \
  'net.ipv4.tcp_wmem = 8192 65536 67108864' \
  'net.ipv4.tcp_congestion_control = bbr' \
  'net.ipv4.ip_local_port_range = 1024 65535' \
  'net.ipv4.neigh.default.gc_thresh3 = 8192' \
  'net.ipv4.conf.all.arp_ignore = 1'; do
  grep -Fq "$expected" <<<"$profile" || fail "generated profile missing: $expected"
done
qdisc_safe cake || fail "CAKE must be recognised as a restorable queue discipline"
for key in "${TUNING_SYSCTL_KEYS[@]}"; do
  grep -Eq "^${key//./\.}[[:space:]]*=" <<<"$profile" || fail "managed key missing from generated profile: $key"
done

# Unsupported kernel knobs are commented instead of aborting the profile.
(
  input="$(mktemp)"; output="$(mktemp)"
  printf 'net.core.rmem_max = 1048576\nnet.test.unsupported = 1\n' >"$input"
  sysctl_exists() { [[ "$1" == "net.core.rmem_max" ]]; }
  UNSUPPORTED_SYSCTL_KEYS_SEEN="|"
  filter_supported_sysctl_file "$input" "$output"
  grep -Fqx 'net.core.rmem_max = 1048576' "$output" || fail "supported sysctl filtering"
  grep -Fqx '# unsupported: net.test.unsupported = 1' "$output" || fail "unsupported sysctl filtering"
)

printf 'All memory-plan tests passed.\n'
