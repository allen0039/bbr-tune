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
[[ -x "${installed}-kernel" ]] || fail "kernel helper not installed"
"$linked" kernel help | grep -q 'BBRv3 内核管理' || fail "installed kernel entrypoint"
# A mixed release must be rejected before overwriting either installed file.
cp "${ROOT}/bbr-kernel.sh" "$tmp/bad-kernel.sh"
sed 's/^KERNEL_HELPER_VERSION=.*/KERNEL_HELPER_VERSION="0.0.0"/' "$tmp/bad-kernel.sh" >"$tmp/mismatched.sh"
if (install_payload "${ROOT}/bbr-tune.sh" "$installed" "$linked" "$tmp/mismatched.sh") >/dev/null 2>&1; then
  fail "mismatched helper accepted"
fi
"$linked" kernel help | grep -q 'BBRv3 内核管理' || fail "failed update broke installed helper"
# --install-only must exit successfully and never open the interactive menu.
(
  INSTALL_PATH="$tmp/only/sbin/bbr-tune"; LINK_PATH="$tmp/only/bin/bbr-tune"
  require_linux_root() { :; }; install_runtime_dependencies() { :; }
  launch_tool() { fail 'install-only launched menu'; }
  main --install-only >/dev/null
) || fail "install-only exit status"
bash -n "${ROOT}/install.sh"
cat "${ROOT}/install.sh" | bash -s -- --help | grep -q '一键安装脚本' || fail "piped installer entrypoint"

printf 'All installer tests passed.\n'
