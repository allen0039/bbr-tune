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
result_better_than "$pass_score" "$RESULT_SCORE" || fail "passing result score"
result_low_speed_low_retrans || fail "single-flow QoS detection"
assert_eq "$(next_stream_count 1)" "8" "stream progression 1 to 8"
assert_eq "$(next_stream_count 8)" "16" "stream progression 8 to 16"
assert_eq "$(next_stream_count 16)" "16" "stream ceiling"

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

if grep -qi 'prompt' "${ROOT}/bbr-tune.sh"; then fail "script must not expose prompt wording"; fi
# Simulate a complete multi-round search: 1/8/16-flow baseline, three memory
# candidates, and a final confirmation of the best candidate.
(
  sim="$(mktemp -d)"
  trap 'rm -rf "$sim"' EXIT
  STATE_DIR="$sim/state"; SESSION_ROOT="${STATE_DIR}/sessions"; BACKUP_ROOT="${STATE_DIR}/backups"
  LATEST_BACKUP="${STATE_DIR}/latest"; PENDING_DIR="${STATE_DIR}/pending"; PENDING_LATEST="${STATE_DIR}/pending-latest"
  HISTORY_FILE="${STATE_DIR}/history.tsv"
  TARGET_MBPS="1000"; START_STREAMS="1"; TEST_STREAMS="1"
  TARGET_UTILIZATION="90"; MAX_RETRANS_PERCENT="1"; AUTO_ROLLBACK_SECONDS="0"
  SERVER_ADDRESS="speed.example.com"; IFACE="auto"; PERSIST_FINAL="0"; FORCE="0"
  require_linux() { :; }; require_root() { :; }; have() { return 0; }; pending_guard() { :; }
  install_iperf3_if_needed() { :; }; ensure_bbr() { :; }; schedule_rollback() { :; }
  resolve_iface() { echo eth0; }; guess_server_address() { echo speed.example.com; }; choose_random_port() { echo 34567; }
  ip() { return 0; }; root_qdisc_kind() { echo fq_codel; }; apply_candidate() { :; }
  detect_memory_limits() { MEM_TOTAL_MIB=8192; MEM_AVAILABLE_MIB=4096; MEM_EFFECTIVE_MIB=8192; MEM_BUFFER_CAP_MIB=128; }
  current_buffer_max() { echo 16777216; }
  sysctl_get() {
    case "$1" in
      net.ipv4.tcp_available_congestion_control) echo 'reno cubic bbr' ;;
      net.ipv4.tcp_congestion_control) echo bbr ;;
      net.core.default_qdisc) echo fq ;;
      net.core.rmem_max|net.core.wmem_max) echo 16777216 ;;
      net.ipv4.tcp_rmem) echo '4096 131072 16777216' ;;
      net.ipv4.tcp_wmem) echo '4096 16384 16777216' ;;
      *) echo 1 ;;
    esac
  }
  init_session() {
    SESSION_ID="simulated"; SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"; mkdir -p "$SESSION_DIR"
    RUN_LOG="${SESSION_DIR}/run.log"; REPORT_FILE="${SESSION_DIR}/results.tsv"; COMPARISON_FILE="${SESSION_DIR}/comparison.txt"
    : >"$RUN_LOG"
    printf 'stage\tround\tconfig\tstreams\tbuffer_mib\tbdp_ratio\trtt_ms\tmbps\tretrans\tretrans_percent\tscore\tpassed\n' >"$REPORT_FILE"
  }
  capture_state() { printf 'state\n' >"$2"; }
  create_backup() { local d="${BACKUP_ROOT}/${SESSION_ID}"; mkdir -p "$d"; echo "$d"; }
  cancel_rollback_for_backup() { :; }; restore_backup() { :; }
  call=0
  run_reverse_test() {
    call=$((call+1))
    RESULT_RTT_MS=180; RESULT_RTT_SOURCE="simulated TCP RTT"
    case "$call" in
      1) RESULT_MBPS=187.23; RESULT_RETRANS=18; RESULT_RETRANS_PERCENT=0.0073 ;;
      2) RESULT_MBPS=700; RESULT_RETRANS=20; RESULT_RETRANS_PERCENT=0.005 ;;
      3) RESULT_MBPS=920; RESULT_RETRANS=25; RESULT_RETRANS_PERCENT=0.004 ;;
      4) RESULT_MBPS=930; RESULT_RETRANS=20; RESULT_RETRANS_PERCENT=0.003 ;;
      5) RESULT_MBPS=950; RESULT_RETRANS=18; RESULT_RETRANS_PERCENT=0.002 ;;
      6) RESULT_MBPS=940; RESULT_RETRANS=17; RESULT_RETRANS_PERCENT=0.002 ;;
      7) RESULT_MBPS=930; RESULT_RETRANS=18; RESULT_RETRANS_PERCENT=0.002 ;;
      8) RESULT_MBPS=940; RESULT_RETRANS=18; RESULT_RETRANS_PERCENT=0.002 ;;
      9) RESULT_MBPS=960; RESULT_RETRANS=16; RESULT_RETRANS_PERCENT=0.002 ;;
      10) RESULT_MBPS=940; RESULT_RETRANS=18; RESULT_RETRANS_PERCENT=0.002 ;;
      11) RESULT_MBPS=950; RESULT_RETRANS=18; RESULT_RETRANS_PERCENT=0.002 ;;
      12) RESULT_MBPS=958; RESULT_RETRANS=17; RESULT_RETRANS_PERCENT=0.002 ;;
      13) RESULT_MBPS=959; RESULT_RETRANS=17; RESULT_RETRANS_PERCENT=0.002 ;;
      *) fail "unexpected simulated test call $call" ;;
    esac
    RESULT_BYTES=1000000000
    calculate_result_quality
  }
  autotune
  assert_eq "$call" "13" "growth, overshoot, backtrack and confirmation count"
  assert_eq "$BEST_KIND" "candidate-6" "best candidate selection"
  assert_eq "$BEST_BUFFER_MIB" "72" "best buffer selection"
  assert_eq "$FINAL_MBPS" "959" "final confirmation throughput"
  assert_eq "$OUTCOME" "optimized-runtime" "search outcome"
  assert_eq "$QOS_DETECTED" "1" "single-flow QoS classification"
  assert_eq "$OVERSHOOT_DETECTED" "1" "overshoot detection"
  assert_eq "$SEARCH_ROUNDS" "9" "unlimited adaptive search rounds"
  [[ -s "$REPORT_FILE" ]] || fail "simulated results log"
  [[ -s "$COMPARISON_FILE" ]] || fail "simulated comparison log"
  [[ -s "$HISTORY_FILE" ]] || fail "simulated history log"
)

printf 'All autotune logic tests passed.\n'
