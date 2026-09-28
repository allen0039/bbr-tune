#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

# Missing iperf3 is installed on the server through the detected package manager.
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

parse_iperf_server_json "${ROOT}/tests/fixtures/iperf3-reverse.json"
assert_eq "$TEST_RESULT_MBPS" "800.00" "JSON throughput parser"
assert_eq "$TEST_RESULT_BYTES" "125000000" "JSON byte parser"
assert_eq "$TEST_RESULT_RETRANS" "1000" "JSON retrans parser"
assert_eq "$TEST_RESULT_RETRANS_PERCENT" "1.1584" "JSON retrans percentage"

# Exercise the no-Python fallback parser used on minimal Linux installations.
(
  have() { [[ "$1" != "python3" ]] && command -v "$1" >/dev/null 2>&1; }
  parse_iperf_server_json "${ROOT}/tests/fixtures/iperf3-reverse.json"
  assert_eq "$TEST_RESULT_MBPS" "800.00" "awk fallback throughput parser"
  assert_eq "$TEST_RESULT_RETRANS" "1000" "awk fallback retrans parser"
)

BANDWIDTH_MBPS="1000"
TARGET_UTILIZATION="90"
MAX_RETRANS_PERCENT="1"
TEST_RESULT_MBPS="920"
TEST_RESULT_RETRANS_PERCENT="0.5"
test_result_meets_target || fail "pass criteria"
TEST_RESULT_MBPS="890"
if test_result_meets_target; then fail "low throughput must fail"; fi
TEST_RESULT_MBPS="920"
TEST_RESULT_RETRANS_PERCENT="1.1"
if test_result_meets_target; then fail "high retrans must fail"; fi

PROFILE="auto"
SYMPTOM="normal"
CAP_MBPS=""
HEADROOM_PERCENT="90"
prepare_initial_autotune_candidate
assert_eq "$PROFILE" "hard-cap" "high retrans initial profile"
assert_eq "$CAP_MBPS" "1000" "hard-cap default cap"
assert_eq "$HEADROOM_PERCENT" "92" "headroom safety floor"

RESOLVED_PROFILE="hard-cap"
HEADROOM_PERCENT="95"
if ! adjust_autotune_candidate; then fail "hard-cap retrans adjustment"; fi
assert_eq "$HEADROOM_PERCENT" "92" "hard-cap headroom reduction"
if adjust_autotune_candidate; then fail "headroom must not fall below throughput-safe floor"; fi

TEST_RESULT_MBPS="850"
TEST_RESULT_RETRANS_PERCENT="0.2"
BUFFER_FACTOR="1.35"
RTT_MS="180"
calculate_plan
if ! adjust_autotune_candidate; then fail "buffer factor adjustment"; fi
assert_eq "$BUFFER_FACTOR" "2.0" "buffer factor progression"
assert_eq "$(next_buffer_factor 2.0)" "3.0" "buffer factor 2 to 3"
assert_eq "$(next_buffer_factor 3.0)" "4.0" "buffer factor 3 to 4"
assert_eq "$(next_buffer_factor 4.0)" "4.0" "buffer factor ceiling"

# Listener detection works with IPv4, IPv6 and wildcard addresses from ss.
(
  ss() {
    cat <<'SS_OUTPUT'
LISTEN 0 4096 0.0.0.0:22000 0.0.0.0:*
LISTEN 0 4096 [::]:23000 [::]:*
SS_OUTPUT
  }
  if port_is_free 22000; then fail "IPv4 occupied port detection"; fi
  if port_is_free 23000; then fail "IPv6 occupied port detection"; fi
  port_is_free 24000 || fail "free port detection"
)

# Random-port selection must stay in range and skip ports reported as occupied.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '0\n' >"${tmp}/checks"
port_is_free() {
  local count
  count="$(cat "${tmp}/checks")"
  count=$((count + 1))
  printf '%s\n' "$count" >"${tmp}/checks"
  (( count >= 3 ))
}
port="$(choose_random_free_port)"
[[ "$port" =~ ^[0-9]+$ ]] || fail "random port is numeric"
(( port >= 20000 && port <= 59999 )) || fail "random port range"
assert_eq "$(cat "${tmp}/checks")" "3" "occupied ports skipped"

printf 'All autotune logic tests passed.\n'
