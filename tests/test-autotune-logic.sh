#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

# Missing iperf3 is installed only on the remote server.
(
  fake_bin="$(mktemp -d)"
  export FAKE_BIN="$fake_bin"
  export INSTALL_LOG="${fake_bin}/install.log"
  trap 'rm -rf "$fake_bin"' EXIT
  cat >"${fake_bin}/apt-get" <<'FAKE_APT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INSTALL_LOG"
if [[ " $* " == *" install "* ]]; then
  cat >"${FAKE_BIN}/iperf3" <<'FAKE_IPERF'
#!/usr/bin/env bash
printf 'iperf 3.test\n'
FAKE_IPERF
  chmod +x "${FAKE_BIN}/iperf3"
fi
FAKE_APT
  chmod +x "${fake_bin}/apt-get"
  PATH="${fake_bin}:/usr/bin:/bin"
  require_root() { :; }
  install_iperf3_if_needed
  [[ -x "${fake_bin}/iperf3" ]] || fail "iperf3 automatic installation"
  grep -qx 'update' "$INSTALL_LOG" || fail "apt update invocation"
  grep -qx 'install -y iperf3' "$INSTALL_LOG" || fail "apt install invocation"
)

parse_iperf_json "${ROOT}/tests/fixtures/iperf3-reverse.json"
assert_eq "$RESULT_MBPS" "800.00" "JSON throughput parser"
assert_eq "$RESULT_BYTES" "125000000" "JSON byte parser"
assert_eq "$RESULT_RETRANS" "1000" "JSON retrans parser"
assert_eq "$RESULT_RETRANS_PERCENT" "1.1584" "JSON retrans percentage"
assert_eq "$RESULT_RTT_MS" "180.00" "JSON TCP RTT parser"
assert_eq "$RESULT_CLIENT_ADDRESS" "198.51.100.8" "JSON client address parser"

# Exercise the minimal-server parser without Python.
(
  have() { [[ "$1" != "python3" ]] && command -v "$1" >/dev/null 2>&1; }
  parse_iperf_json "${ROOT}/tests/fixtures/iperf3-reverse.json"
  assert_eq "$RESULT_MBPS" "800.00" "awk fallback throughput"
  assert_eq "$RESULT_RETRANS" "1000" "awk fallback retrans"
  assert_eq "$RESULT_RTT_MS" "180.00" "awk fallback TCP RTT"
  assert_eq "$RESULT_CLIENT_ADDRESS" "198.51.100.8" "awk fallback client address"
)

TARGET_MBPS="1000"
TARGET_UTILIZATION="90"
MAX_RETRANS_PERCENT="1"
RESULT_MBPS="920"
RESULT_RETRANS_PERCENT="0.5"
calculate_result_quality
assert_eq "$RESULT_PASS" "yes" "passing result"
pass_score="$RESULT_SCORE"
RESULT_MBPS="850"
RESULT_RETRANS_PERCENT="0.2"
calculate_result_quality
assert_eq "$RESULT_PASS" "no" "low-throughput result"
awk -v passing="$pass_score" -v failing="$RESULT_SCORE" 'BEGIN {exit !(passing>failing)}' || fail "passing result score"

# Balanced evaluation protects both single-connection and multi-connection
# throughput relative to their independent baselines.
BASELINE_SINGLE_MBPS="200"
BASELINE_MULTI_MBPS="900"
BALANCE_MIN_RETENTION_PERCENT="95"
PAIR_SINGLE_RETRANS_PERCENT="0.1"
PAIR_MULTI_RETRANS_PERCENT="0.1"
PAIR_SINGLE_MBPS="189"
PAIR_MULTI_MBPS="1000"
calculate_pair_quality yes
assert_eq "$PAIR_ELIGIBLE" "no" "single-connection baseline protection"
PAIR_SINGLE_MBPS="220"
PAIR_MULTI_MBPS="854"
calculate_pair_quality yes
assert_eq "$PAIR_ELIGIBLE" "no" "multi-connection baseline protection"
PAIR_SINGLE_MBPS="220"
PAIR_MULTI_MBPS="900"
calculate_pair_quality yes
assert_eq "$PAIR_ELIGIBLE" "yes" "balanced candidate eligibility"

PAIR_SINGLE_MBPS="600"; PAIR_MULTI_MBPS="600"
calculate_pair_quality no
balanced_score="$PAIR_SCORE"
PAIR_SINGLE_MBPS="1000"; PAIR_MULTI_MBPS="200"
calculate_pair_quality no
biased_score="$PAIR_SCORE"
awk -v balanced="$balanced_score" -v biased="$biased_score" 'BEGIN {exit !(balanced>biased)}' || fail "harmonic score must penalize one-sided performance"
PAIR_ELIGIBLE="yes"
pair_better_than 61 60 || fail "balanced score improvement"
if pair_better_than 60.1 60; then fail "minor score noise must not replace the best candidate"; fi
PAIR_ELIGIBLE="no"
if pair_better_than 70 60; then fail "ineligible candidate must not become best"; fi
pair_regressed 70 60 || fail "ineligible candidate is outside the safe boundary"
PAIR_ELIGIBLE="yes"
pair_regressed 59 60 || fail "material balanced-score regression"
if pair_regressed 59.5 60; then fail "minor balanced-score noise must not trigger rollback"; fi

# Listener detection works with IPv4, IPv6 and wildcard addresses.
(
  ss() {
    cat <<'SS_OUTPUT'
LISTEN 0 4096 0.0.0.0:22000 0.0.0.0:*
LISTEN 0 4096 [::]:23000 [::]:*
SS_OUTPUT
  }
  if port_is_free 22000; then fail "IPv4 occupied port"; fi
  if port_is_free 23000; then fail "IPv6 occupied port"; fi
  port_is_free 24000 || fail "free port"
)

# Random port retries occupied candidates.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '0\n' >"${tmp}/checks"
port_is_free() {
  local count
  count="$(cat "${tmp}/checks")"
  count=$((count+1))
  printf '%s\n' "$count" >"${tmp}/checks"
  (( count >= 3 ))
}
port="$(choose_random_port)"
(( port >= 20000 && port <= 59999 )) || fail "random port range"
assert_eq "$(cat "${tmp}/checks")" "3" "occupied ports skipped"

forbidden='pro''mpt'
if grep -qi "$forbidden" "${ROOT}/bbr-tune.sh"; then fail "script contains prohibited development wording"; fi

# Simulate a complete balanced search: baseline pair, three growth candidates,
# six backtracking candidates, and one final verification pair.
(
  sim="$(mktemp -d)"
  trap 'rm -rf "$sim"' EXIT
  STATE_DIR="$sim/state"; SESSION_ROOT="${STATE_DIR}/sessions"; BACKUP_ROOT="${STATE_DIR}/backups"
  LATEST_BACKUP="${STATE_DIR}/latest"; PENDING_DIR="${STATE_DIR}/pending"; PENDING_LATEST="${STATE_DIR}/pending-latest"
  HISTORY_FILE="${STATE_DIR}/history.tsv"
  TARGET_MBPS="1000"; START_STREAMS="8"; TEST_STREAMS="1"
  TARGET_UTILIZATION="90"; MAX_RETRANS_PERCENT="1"; AUTO_ROLLBACK_SECONDS="0"
  SERVER_ADDRESS="speed.example.com"; IFACE="auto"; PERSIST_FINAL="0"; FORCE="0"
  require_linux() { :; }; require_root() { :; }; have() { return 0; }; pending_guard() { :; }
  install_iperf3_if_needed() { :; }; ensure_bbr() { :; }; schedule_rollback() { :; }
  resolve_iface() { echo eth0; }; guess_server_address() { echo speed.example.com; }; choose_random_port() { echo 34567; }
  ip() { return 0; }; root_qdisc_kind() { echo fq_codel; }; apply_candidate() { :; }
  detect_memory_limits() {
    MEM_TOTAL_MIB=8192; MEM_AVAILABLE_MIB=4096; MEM_EFFECTIVE_MIB=8192
    MEM_TCP_BUDGET_MIB=5461; MEM_BUFFER_CAP_MIB=128; PAGE_SIZE_BYTES=4096
    TCP_MEM_LOW_PAGES=699050; TCP_MEM_PRESSURE_PAGES=1048576; TCP_MEM_HIGH_PAGES=1398101
  }
  current_buffer_max() { echo 16777216; }
  sysctl_get() {
    case "$1" in
      net.ipv4.tcp_available_congestion_control) echo 'reno cubic bbr' ;;
      net.ipv4.tcp_congestion_control) echo bbr ;;
      net.core.default_qdisc) echo fq ;;
      net.core.rmem_max|net.core.wmem_max) echo 16777216 ;;
      net.ipv4.tcp_rmem) echo '4096 131072 16777216' ;;
      net.ipv4.tcp_wmem) echo '4096 16384 16777216' ;;
      net.ipv4.tcp_mem) echo '699050 1048576 1398101' ;;
      *) echo 1 ;;
    esac
  }
  init_session() {
    SESSION_ID="simulated"; SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"; mkdir -p "$SESSION_DIR"
    RUN_LOG="${SESSION_DIR}/run.log"; REPORT_FILE="${SESSION_DIR}/results.tsv"; COMPARISON_FILE="${SESSION_DIR}/comparison.txt"
    : >"$RUN_LOG"
    printf 'stage\tround\tmode\tconfig\tstreams\tbuffer_mib\tbdp_ratio\trtt_ms\tmbps\tretrans\tretrans_percent\tmetric_score\tpassed\tbalance_score\teligible\n' >"$REPORT_FILE"
  }
  capture_state() { printf 'state\n' >"$2"; }
  create_backup() { local d="${BACKUP_ROOT}/${SESSION_ID}"; mkdir -p "$d"; echo "$d"; }
  cancel_rollback_for_backup() { :; }; restore_backup() { :; }
  call=0
  test_mbps=(200 900 250 920 300 950 250 960 270 955 310 960 290 965 305 962 312 963 280 964 315 958)
  run_reverse_test() {
    call=$((call+1))
    RESULT_RTT_MS=180; RESULT_RTT_SOURCE="simulated TCP RTT"
    RESULT_MBPS="${test_mbps[$((call-1))]:-}"
    [[ -n "$RESULT_MBPS" ]] || fail "unexpected simulated test call $call"
    RESULT_RETRANS=10; RESULT_RETRANS_PERCENT=0.002; RESULT_BYTES=1000000000
    calculate_result_quality
  }
  autotune
  assert_eq "$call" "22" "balanced growth, backtrack and verification test count"
  assert_eq "$BEST_KIND" "candidate-8" "best balanced candidate selection"
  assert_eq "$BEST_BUFFER_MIB" "86" "best balanced buffer selection"
  assert_eq "$FINAL_SINGLE_MBPS" "315" "final single-connection verification"
  assert_eq "$FINAL_MULTI_MBPS" "958" "final multi-connection verification"
  assert_eq "$OUTCOME" "optimized-runtime" "search outcome"
  assert_eq "$QOS_DETECTED" "1" "single-versus-multi difference classification"
  assert_eq "$OVERSHOOT_DETECTED" "1" "overshoot detection"
  assert_eq "$SEARCH_ROUNDS" "9" "adaptive search rounds"
  [[ -s "$REPORT_FILE" ]] || fail "simulated results log"
  [[ -s "$COMPARISON_FILE" ]] || fail "simulated comparison log"
  [[ -s "$HISTORY_FILE" ]] || fail "simulated history log"
  grep -q $'single\tbbr-fq\t1\t86' "$REPORT_FILE" || fail "single-connection candidate log"
  grep -q $'multi\tbbr-fq\t8\t86' "$REPORT_FILE" || fail "multi-connection candidate log"
)

printf 'All autotune logic tests passed.\n'
