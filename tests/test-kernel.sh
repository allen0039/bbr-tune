#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/bbr-kernel.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

k_parse install --track lts --cpu-level 2 --yes --console-available
eq "$K_ACTION:$K_TRACK:$K_CPU:$K_YES:$K_CONSOLE" install:lts:2:1:1 'kernel arguments'
for args in 'install --track rc' 'install --cpu-level 4' 'install --source arbitrary' 'install --track'; do
  if (k_parse $args) >/dev/null 2>&1; then fail "invalid arguments accepted: $args"; fi
done
K_ARCH=x86_64; K_OS=debian; K_SUITE=bookworm; k_supported_os || fail 'Debian amd64 refused'
K_ARCH=aarch64; if k_supported_os; then fail 'arm64 cannot use amd64 packages'; fi
K_ARCH=x86_64; K_SUITE=bullseye; if k_supported_os; then fail 'unverified distro accepted'; fi

flags='cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3'
flags3="$flags avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"
printf 'flags : %s\nflags : %s\n' "$flags3" "$flags" >"$TMP/cpuinfo"
eq "$(k_cpu_level "$TMP/cpuinfo")" 2 'intersection across vCPUs'
printf 'flags : %s\nflags : sse2\n' "$flags3" >"$TMP/cpuinfo"
eq "$(k_cpu_level "$TMP/cpuinfo")" 1 'conservative CPU baseline'
K_TRACK=lts; K_CPU=auto; k_choose_meta 3
eq "$K_META" linux-xanmod-lts-x64v1 'auto prefers portable LTS'
K_TRACK=main; K_CPU=3; k_choose_meta 3
eq "$K_META" linux-xanmod-x64v3 'explicit supported CPU level'
if (K_CPU=3; k_choose_meta 2) >/dev/null 2>&1; then fail 'unsupported CPU level accepted'; fi

cat >"$TMP/releases.json" <<'JSON'
{"releases":[{"version":"6.18.54","moniker":"longterm"},{"version":"7.2.8","moniker":"stable"},{"version":"7.3-rc5","moniker":"mainline"},{"version":"6.13.7","moniker":"stable","iseol":true}]}
JSON
k_check_maintained 6.18.54-xanmod1 "$TMP/releases.json" >/dev/null
for version in 6.18.53-xanmod1 6.13.7-xanmod1 7.3-rc5-xanmod1 invalid; do
  if k_check_maintained "$version" "$TMP/releases.json" >/dev/null 2>&1; then fail "unmaintained kernel accepted: $version"; fi
done
printf 'pub:::::::::\nfpr:::::::::%s:\nsub:::::::::\nfpr:::::::::SUBKEY:\n' "$K_KEY_FINGERPRINT" >"$TMP/key"
eq "$(k_key_fingerprint <"$TMP/key")" "$K_KEY_FINGERPRINT" 'pin primary, not subkey'
printf 'pub:::::::::\nfpr:::::::::OTHER:\n' >>"$TMP/key"
eq "$(k_key_fingerprint <"$TMP/key")" '' 'reject additional trusted primary key'
eq "$(k_build_jobs 8388608 4194304 16)" 2 'memory-aware compile concurrency'
eq "$(k_build_jobs 134217728 134217728 32)" 8 'compile CPU load cap'
if k_build_jobs 1048576 900000 8 >/dev/null; then fail 'unsafe low-memory compile accepted'; fi

cat >"$TMP/grub.cfg" <<'GRUB'
menuentry 'Linux' $menuentry_id_option 'gnulinux-simple-uuid' {
}
submenu 'Advanced Linux' $menuentry_id_option 'gnulinux-advanced-uuid' {
 menuentry 'Old Linux' $menuentry_id_option 'gnulinux-5.15.0-old-advanced-uuid' {
 }
 menuentry 'Old Linux recovery' $menuentry_id_option 'gnulinux-5.15.0-old-recovery-uuid' {
 }
 menuentry 'New Linux' $menuentry_id_option 'gnulinux-6.18.54-x64v1-xanmod1-advanced-uuid' {
 }
}
GRUB
eq "$(k_grub_entry 5.15.0-old "$TMP/grub.cfg")" 'gnulinux-advanced-uuid>gnulinux-5.15.0-old-advanced-uuid' 'stable, non-recovery GRUB ID'
if k_grub_entry missing "$TMP/grub.cfg" >/dev/null 2>&1; then fail 'missing GRUB entry accepted'; fi
cat "$TMP/grub.cfg" "$TMP/grub.cfg" >"$TMP/ambiguous.cfg"
if k_grub_entry 5.15.0-old "$TMP/ambiguous.cfg" >/dev/null 2>&1; then fail 'ambiguous GRUB entry accepted'; fi

# Exercise artifact installation and full boot lifecycle with only fake package,
# kernel and boot commands. No actual /boot, sysctl, package manager or GRUB writes.
(
  K_ROOT="$TMP/state"; K_LATEST="$K_ROOT/latest"; K_SESSION="$K_ROOT/session"
  K_BOOT_DIR="$TMP/boot"; K_MODULES_DIR="$TMP/modules"; K_GRUB_CFG="$K_BOOT_DIR/grub.cfg"
  K_GRUB_ENV="$K_BOOT_DIR/grubenv"; K_GRUB_DROP="$TMP/default/grub.d/kernel.cfg"; K_GRUB_DEFAULT="$TMP/default/grub"
  mkdir -p "$K_BOOT_DIR" "$K_MODULES_DIR" "$K_SESSION/packages" "$TMP/default"
  cp "$TMP/grub.cfg" "$K_GRUB_CFG"
  printf '\nload_env\nset default="${saved_entry}"\nsave_env next_entry\n' >>"$K_GRUB_CFG"
  echo 'GRUB_DEFAULT=0' >"$K_GRUB_DEFAULT"; : >"$K_GRUB_ENV"
  K_OLD=5.15.0-old; K_TARGET=6.18.54-x64v1-xanmod1
  K_META=linux-xanmod-lts-x64v1; K_TAG=6.18.54-xanmod1; K_META_VERSION=6.18.54-xanmod1-0; K_CPU=1
  K_YES=1; K_CONSOLE=1; K_METHOD=package
  for item in vmlinuz initrd.img config; do echo old >"$K_BOOT_DIR/$item-$K_OLD"; done
  for name in "linux-image-$K_TARGET" "linux-headers-$K_TARGET" "$K_META"; do echo "$name" >"$K_SESSION/packages/$name.deb"; done
  k_linux() { :; }; k_root() { :; }; k_lock() { :; }; k_secure_boot() { echo disabled; }
  dpkg-deb() { case "$3" in Package) cat "$2" ;; Architecture) echo amd64 ;; *) fail "unexpected deb query: $*" ;; esac; }
  sha256sum() { shasum -a 256 "$@"; }
  apt-mark() { printf '%s\n' "$*" >>"$TMP/apt-mark.log"; }
  dpkg-query() { echo "linux-image-$K_OLD: $K_BOOT_DIR/vmlinuz-$K_OLD"; }
  update-grub() { echo updated >>"$TMP/grub-updates"; }
  grub-set-default() {
    grep -v '^saved_entry=' "$K_GRUB_ENV" >"$K_GRUB_ENV.new" || true
    printf 'saved_entry=%s\n' "$1" >>"$K_GRUB_ENV.new"; mv "$K_GRUB_ENV.new" "$K_GRUB_ENV"
  }
  grub-reboot() {
    grep -v '^next_entry=' "$K_GRUB_ENV" >"$K_GRUB_ENV.new" || true
    printf 'next_entry=%s\n' "$1" >>"$K_GRUB_ENV.new"; mv "$K_GRUB_ENV.new" "$K_GRUB_ENV"
  }
  grub-editenv() {
    case "$2" in
      list) cat "$1" ;;
      unset) grep -v "^$3=" "$1" >"$1.new" || true; mv "$1.new" "$1" ;;
      *) fail "unexpected grub command: $*" ;;
    esac
  }
  apt-get() {
    [[ "$1" == install && " $* " == *' --no-remove '* ]] || fail 'unsafe apt operation'
    grep -Fqx "saved_entry=$K_OLD_ENTRY" "$K_GRUB_ENV" || fail 'old default not protected before install'
    echo "$*" >"$TMP/apt-install.log"
    mkdir -p "$K_MODULES_DIR/$K_TARGET"
    echo image >"$K_BOOT_DIR/vmlinuz-$K_TARGET"; echo initramfs >"$K_BOOT_DIR/initrd.img-$K_TARGET"
    echo CONFIG_TCP_CONG_BBR=y >"$K_BOOT_DIR/config-$K_TARGET"
  }
  modinfo() { echo 3; }
  k_install_artifacts >"$TMP/install.log" 2>&1
  eq "$K_STATUS" installed 'installation does not claim running kernel switch'
  [[ -s "$K_BOOT_DIR/vmlinuz-$K_OLD" ]] || fail 'old kernel removed'
  grep -Fq "manual linux-image-$K_OLD" "$TMP/apt-mark.log" || fail 'old image not protected from autoremove'
  if grep -Fq "$K_META.deb" "$TMP/apt-install.log"; then fail 'tracking meta-package must not be installed'; fi
  [[ -s "$K_SESSION/packages.sha256" ]] || fail 'package checksums missing'
  if grep -q '^next_entry=' "$K_GRUB_ENV"; then fail 'install automatically scheduled a reboot target'; fi
  if (k_install_artifacts) >/dev/null 2>&1; then fail 'existing kernel overwritten'; fi
  # Persisted state is data, never shell code. Observe lifecycle through the real loader.
  running="$K_OLD"; runtime_bbr=1
  uname() { if [[ "${1:-}" == -r ]]; then echo "$running"; else echo Linux; fi; }
  k_running_bbr_version() { echo "$runtime_bbr"; }
  modprobe() { [[ "$*" == tcp_bbr ]] || fail 'unexpected module load'; }
  sysctl() { [[ "$*" == '-n net.ipv4.tcp_congestion_control' ]] || fail 'kernel verifier wrote TCP parameters'; echo cubic; }
  reboot() { fail 'automatic reboot is forbidden'; }
  K_ACTION=trial; k_continue >"$TMP/trial.log" 2>&1
  eq "$K_STATUS" trial 'trial phase'
  grep -Fqx "saved_entry=$K_OLD_ENTRY" "$K_GRUB_ENV" || fail 'trial changed permanent default'
  grep -Fqx "next_entry=$K_TARGET_ENTRY" "$K_GRUB_ENV" || fail 'one-time new kernel target missing'
  if (K_ACTION=accept; k_continue) >/dev/null 2>&1; then fail 'accepted while still on old kernel'; fi
  running="$K_TARGET"
  if (K_ACTION=accept; k_continue) >/dev/null 2>&1; then fail 'accepted based on kernel name without BBR3'; fi
  runtime_bbr=3; K_ACTION=verify; k_continue >"$TMP/verify.log" 2>&1
  eq "$(k_read_field status)" trial 'verify does not permanently accept'
  K_ACTION=accept; k_continue >"$TMP/accept.log" 2>&1
  eq "$(k_read_field status)" accepted 'accepted phase'
  grep -Fqx "saved_entry=$K_TARGET_ENTRY" "$K_GRUB_ENV" || fail 'confirmed kernel not default'
  K_ACTION=fallback; k_continue >"$TMP/fallback.log" 2>&1
  eq "$(k_read_field status)" fallback-planned 'fallback phase'
  grep -Fqx "saved_entry=$K_OLD_ENTRY" "$K_GRUB_ENV" || fail 'fallback default not old kernel'
  grep -Fqx "next_entry=$K_OLD_ENTRY" "$K_GRUB_ENV" || fail 'fallback next boot not old kernel'
  [[ "$running" == "$K_TARGET" ]] || fail 'fallback claimed immediate kernel switch'
)

# The installed entrypoint needs a matched helper and must forward kernel arguments.
bash "$ROOT/bbr-tune.sh" kernel help | grep -q 'BBRv3 内核管理' || fail 'main kernel subcommand'
forbidden='pro''mpt'
if grep -qi "$forbidden" "$ROOT/bbr-kernel.sh"; then fail 'prohibited development wording'; fi
printf 'All kernel compatibility, artifact and boot-lifecycle tests passed.\n'
