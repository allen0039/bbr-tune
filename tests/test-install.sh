#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/install.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
installed="${tmp}/sbin/bbr-tune"
linked="${tmp}/bin/bbr-tune"
install_payload "${ROOT}/bbr-tune.sh" "$installed" "$linked"
[[ -x "$installed" ]] || fail "installed executable"
[[ -L "$linked" ]] || fail "command symlink"
[[ "$(readlink "$linked")" == "$installed" ]] || fail "symlink target"
"$linked" --version | grep -q '^bbr-tune ' || fail "installed command version"
bash -n "${ROOT}/install.sh"
cat "${ROOT}/install.sh" | bash -s -- --help | grep -q '一键安装脚本' || fail "piped installer entrypoint"

printf 'All installer tests passed.\n'
