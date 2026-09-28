#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/bbr-tune.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

SERVER_ADDRESS=""
SSH_CONNECTION="198.51.100.8 50123 203.0.113.20 22"
address="$(guess_server_address)"
[[ "$address" == "203.0.113.20" ]] || fail "SSH server address detection"

SERVER_ADDRESS="speed.example.com"
address="$(guess_server_address)"
[[ "$address" == "speed.example.com" ]] || fail "explicit server address"

out="$(print_client_iperf_commands "203.0.113.20" "5201")"
[[ "$out" == *"iperf3 -c 203.0.113.20 -p 5201 -R -t 20"* ]] || fail "single reverse command"
[[ "$out" == *"-R -P 8"* ]] || fail "8-stream reverse command"
[[ "$out" == *"-R -P 16"* ]] || fail "16-stream reverse command"
[[ "$out" == *"请在本地客户端执行"* ]] || fail "client-side direction warning"

[[ "$(pending_rollback_dir '/var/lib/bbr-tcp-tuning/backups/20260928-120000')" == "/var/lib/bbr-tcp-tuning/pending/20260928-120000" ]] || fail "pending directory mapping"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PENDING_DIR="${tmp}/pending"
PENDING_LATEST="${tmp}/pending-latest"
AUTO_ROLLBACK_SECONDS="30"
SCRIPT_PATH="${ROOT}/bbr-tune.sh"
backup="${tmp}/backups/test-backup"
mkdir -p "$backup"
schedule_remote_rollback "$backup"
pending="$(pending_rollback_dir "$backup")"
[[ -f "${pending}/armed" ]] || fail "auto-rollback marker"
[[ -L "$PENDING_LATEST" ]] || fail "auto-rollback latest link"
cancel_pending_for_backup "$backup"
[[ ! -e "$pending" ]] || fail "auto-rollback cancellation"

printf 'All remote-role tests passed.\n'
