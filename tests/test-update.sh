#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/bbr-tune.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

require_linux() { :; }; require_root() { :; }
export UPDATE_TEST_LOG="$tmp/installer.log"
export BBR_TUNE_INSTALL_PATH="$tmp/installed-bbr-tune"
export UPDATE_TEST_INSTALLED_VERSION="2.10.4"
UPDATE_TEST_SHA='7ef501bf6eb5e546dd0a2bdcf0dcbce537e1b134'
download_update_installer() {
  printf '%s\n' "$1" >>"$tmp/download-urls"
  if [[ "$1" == *'/commits/main?'* ]]; then
    printf '{"sha":"%s"}\n' "$UPDATE_TEST_SHA" >"$2"
    return
  fi
  cat >"$2" <<'INSTALLER'
#!/usr/bin/env bash
printf '%s|%s\n' "$BBR_TUNE_RAW_BASE" "$*" >"$UPDATE_TEST_LOG"
printf '#!/usr/bin/env bash\nprintf "bbr-tune %%s\\n" "%s"\n' "$UPDATE_TEST_INSTALLED_VERSION" >"$BBR_TUNE_INSTALL_PATH"
chmod +x "$BBR_TUNE_INSTALL_PATH"
INSTALLER
}
update_command >"$tmp/github.out" 2>&1 || fail 'GitHub update failed'
[[ "$(cat "$tmp/installer.log")" == "https://raw.githubusercontent.com/dingding229/bbr-tune/${UPDATE_TEST_SHA}|--install-only" ]] || fail 'GitHub source not passed to installer'
grep -q "https://api.github.com/repos/dingding229/bbr-tune/commits/main?bbr_tune_refresh=" "$tmp/download-urls" || fail 'GitHub commit API not used'
grep -q "https://raw.githubusercontent.com/dingding229/bbr-tune/${UPDATE_TEST_SHA}/install.sh?bbr_tune_refresh=" "$tmp/download-urls" || fail 'GitHub installer not pinned to commit'
grep -q '仍是版本 2.10.4' "$tmp/github.out" || fail 'unchanged version not reported'
UPDATE_TEST_INSTALLED_VERSION="2.10.5"
update_command >"$tmp/newer.out" || fail 'newer version update failed'
grep -q '已从 2.10.4 更新到 2.10.5' "$tmp/newer.out" || fail 'new version not reported'

download_update_installer() {
  if [[ "$1" == *'/commits/main?'* ]]; then printf '{"sha":"%s"}\n' "$UPDATE_TEST_SHA" >"$2"; else printf 'not a shell installer\n' >"$2"; fi
}
if update_command >"$tmp/invalid-installer.out" 2>&1; then fail 'invalid installer executed'; fi
grep -q '安装器无效' "$tmp/invalid-installer.out" || fail 'invalid installer explanation missing'

download_update_installer() {
  if [[ "$1" == *'/commits/main?'* ]]; then printf '{"sha":"%s"}\n' "$UPDATE_TEST_SHA" >"$2"; return; fi
  cat >"$2" <<'FAILED_INSTALLER'
#!/usr/bin/env bash
exit 7
FAILED_INSTALLER
}
if update_command >"$tmp/failed-installer.out" 2>&1; then fail 'installer failure reported success'; fi
grep -q '更新未完成' "$tmp/failed-installer.out" || fail 'installer failure explanation missing'

ui_yes_no() { return 0; }
ui_execute() { printf '%s\n' "$*" >"$tmp/menu-action"; }
ui_update >"$tmp/menu.out" || fail 'update menu failed'
[[ "$(cat "$tmp/menu-action")" == '1 update' ]] || fail 'menu selected wrong update action'
rm -f "$tmp/menu-action"
ui_yes_no() { return 1; }
if ui_update >"$tmp/menu-cancel.out"; then fail 'menu cancellation reported success'; fi
[[ ! -e "$tmp/menu-action" ]] || fail 'cancelled menu started update'

printf 'All update and menu tests passed.\n'
