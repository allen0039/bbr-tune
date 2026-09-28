#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }

SERVER_ADDRESS=""
SSH_CONNECTION="198.51.100.8 50123 203.0.113.20 22"
assert_eq "$(guess_server_address)" "203.0.113.20" "SSH server address"
SERVER_ADDRESS="speed.example.com"
assert_eq "$(guess_server_address)" "speed.example.com" "explicit server address"

# Rollback timers are cancellable and leave no stale pending marker.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
STATE_DIR="$tmp"
PENDING_DIR="${tmp}/pending"
PENDING_LATEST="${tmp}/pending-latest"
AUTO_ROLLBACK_SECONDS="30"
SCRIPT_PATH="${ROOT}/bbr-tune.sh"
backup="${tmp}/backups/test-backup"
mkdir -p "$backup"
schedule_rollback "$backup"
pending="$(pending_path "$backup")"
[[ -f "${pending}/armed" ]] || fail "rollback armed marker"
[[ -L "$PENDING_LATEST" ]] || fail "rollback latest link"
pending_guard
[[ ! -e "$pending" ]] || fail "new autotune cancels previous pending rollback"
[[ ! -e "$PENDING_LATEST" ]] || fail "new autotune removes previous pending link"

# A broken latest symlink is stale state and must never block a new run.
ln -sfn "${tmp}/missing-pending" "$PENDING_LATEST"
pending_guard
[[ ! -L "$PENDING_LATEST" ]] || fail "broken pending symlink cleanup"

# Explicit cancellation remains idempotent.
mkdir -p "$backup"
schedule_rollback "$backup"
cancel_rollback_for_backup "$backup"
[[ ! -e "$(pending_path "$backup")" ]] || fail "rollback cancellation"

# Detailed before/after comparison is retained for later time-period analysis.
SESSION_ID="test-session"
SESSION_DIR="$tmp/session"
mkdir -p "$SESSION_DIR"
RUN_LOG="${SESSION_DIR}/run.log"
REPORT_FILE="${SESSION_DIR}/results.tsv"
COMPARISON_FILE="${SESSION_DIR}/comparison.txt"
printf 'stage\tround\tconfig\tstreams\tbuffer_mib\tbdp_ratio\trtt_ms\tmbps\tretrans\tretrans_percent\tscore\tpassed\nfinal\t4\tbbr-fq\t8\t64\t2.98\t180\t920\t10\t0.005\t1102\tyes\n' >"$REPORT_FILE"
SERVER_ADDRESS="speed.example.com"
TARGET_MBPS="1000"; TARGET_UTILIZATION="90"; RTT_MS="180"; BASELINE_STREAMS="8"
MEM_TOTAL_MIB="8192"; MEM_AVAILABLE_MIB="4096"; MEM_EFFECTIVE_MIB="8192"; MEM_BUFFER_CAP_MIB="64"; BDP_MIB="21.46"; RTT_SOURCE="simulated TCP RTT"
BEFORE_CC="cubic"; BEFORE_QDISC="fq_codel"; BEFORE_RMEM="4096 131072 6291456"; BEFORE_WMEM="4096 16384 4194304"; BEFORE_BUFFER_BYTES="6291456"
BASELINE_MBPS="600"; BASELINE_RETRANS="20"; BASELINE_RETRANS_PERCENT="0.01"; BASELINE_PASS="no"
FINAL_MBPS="920"; FINAL_RETRANS="10"; FINAL_RETRANS_PERCENT="0.005"; FINAL_PASS="yes"
OUTCOME="optimized-runtime"; BEST_KIND="candidate-2"; BEST_BUFFER_MIB="64"; BEST_FACTOR="2.98"; QOS_DETECTED="1"; SEARCH_ROUNDS="4"; OVERSHOOT_DETECTED="1"; OVERSHOOT_MIB="128"
sysctl_get() { case "$1" in net.ipv4.tcp_congestion_control) echo bbr ;; net.ipv4.tcp_rmem) echo '4096 131072 67108864' ;; net.ipv4.tcp_wmem) echo '4096 16384 67108864' ;; esac; }
root_qdisc_kind() { echo fq; }
write_comparison eth0 67108864 >/dev/null
grep -q '下载速度提高 53.33%' "$COMPARISON_FILE" || fail "plain-language throughput delta"
grep -q '单流 QoS 特征：是' "$COMPARISON_FILE" || fail "comparison QoS flag"
grep -q '已在 128 MiB 检测到性能回落' "$COMPARISON_FILE" || fail "plain-language overshoot summary"

printf 'All remote-role tests passed.\n'
