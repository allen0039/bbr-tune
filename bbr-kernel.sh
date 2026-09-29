#!/usr/bin/env bash
# Remote Linux kernel lifecycle; kept separate from TCP measurement and rollback.
set -Eeuo pipefail
KERNEL_HELPER_VERSION="2.6.1"
K_ROOT="/var/lib/bbr-tcp-tuning/kernels"
K_LATEST="${K_ROOT}/latest"
K_TRACK=lts
K_CPU=auto
K_YES=0
K_CONSOLE=0
K_METHOD=package
K_ACTION=menu
K_KEY_URL="https://dl.xanmod.org/archive.key"
K_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
K_REPO="https://gitlab.com/xanmod/linux.git"
K_REPO_URL="https://deb.xanmod.org"
K_BOOT_DIR="/boot"
K_MODULES_DIR="/lib/modules"
K_GRUB_CFG="/boot/grub/grub.cfg"
K_GRUB_ENV="/boot/grub/grubenv"
K_GRUB_DEFAULT="/etc/default/grub"
K_GRUB_DROP="/etc/default/grub.d/99-bbr-tune-kernel.cfg"
K_SESSION=""
K_STATUS=""
K_OLD=""
K_TARGET=""
K_OLD_ENTRY=""
K_TARGET_ENTRY=""
K_META=""
K_META_VERSION=""
K_TAG=""
K_COMMIT=""
K_BOOT_GUARDED=0
K_APT=()

k_log() { printf '[%s] [KERNEL] %s\n' "$(date '+%H:%M:%S')" "$*"; }
k_die() { k_log "失败：$*" >&2; exit 1; }
k_have() { command -v "$1" >/dev/null 2>&1; }
k_linux() { [[ "$(uname -s)" == Linux ]] || k_die '内核操作只能在远程 Linux 服务器运行'; }
k_root() { (( EUID == 0 )) || k_die '请使用 sudo 或 root'; }
k_fetch() { curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --location --retry 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"; }
k_yes_no() {
  local answer
  [[ -t 0 ]] || return 1
  read -r -p "$1 [y/N]：" answer || return 1
  [[ "$answer" == y || "$answer" == Y ]]
}
k_usage() {
  cat <<'HELP'
BBRv3 内核管理（仅远程服务器）
  bbr-tune kernel plan                 检测环境并显示选择建议，不安装
  bbr-tune kernel install              安装签名仓库提供的预编译内核（推荐）
  bbr-tune kernel build                从相同发行版本的固定源码构建并安装
  bbr-tune kernel trial                设置下一次启动试用新内核，不重启
  bbr-tune kernel verify               验证运行内核与 BBRv3，不更改 TCP 参数
  bbr-tune kernel accept               验证后将新内核设为默认启动项
  bbr-tune kernel fallback             下次启动旧内核，不重启、不卸载内核
  bbr-tune kernel status               查看已记录的内核操作

安装/构建选项：
  --track lts|main                     默认 lts；main 仅使用维护中的稳定分支
  --cpu-level auto|1|2|3               auto 保守使用 x86-64-v1；更高等级需 CPU 验证
  --console-available                  确认具备云控制台/救援访问与重启恢复能力
  --yes                               非交互确认（不能绕过兼容性/启动检查）

支持自动安装：Debian 12/13、Ubuntu 24.04/26.04，amd64，GRUB2。
不在容器内换内核，不关闭 Secure Boot，不自动重启，不删除旧内核。
TCP 参数回滚不能回滚内核；内核失败需从控制台重启/选择旧内核。
HELP
}
k_parse() {
  if (( $# )); then K_ACTION="$1"; shift; fi
  case "$K_ACTION" in menu|plan|install|build|trial|verify|accept|fallback|status|help|--help) ;; *) k_die "未知内核操作：$K_ACTION" ;; esac
  while (( $# )); do
    case "$1" in
      --track|--cpu-level)
        (( $# >= 2 )) || k_die "$1 缺少值"
        if [[ "$1" == --track ]]; then K_TRACK="$2"; else K_CPU="$2"; fi
        shift 2 ;;
      --console-available) K_CONSOLE=1; shift ;;
      --yes) K_YES=1; shift ;;
      --help|-h) K_ACTION=help; shift ;;
      *) k_die "未知内核参数：$1" ;;
    esac
  done
  case "$K_TRACK" in lts|main) ;; *) k_die 'track 仅支持 lts 或 main' ;; esac
  case "$K_CPU" in auto|1|2|3) ;; *) k_die 'CPU 等级仅支持 auto、1、2、3' ;; esac
}
k_detect_os() {
  local ID=unknown VERSION_CODENAME=unknown
  [[ ! -r /etc/os-release ]] || source /etc/os-release
  K_OS="$ID"; K_SUITE="$VERSION_CODENAME"
  K_ARCH="$(uname -m)"; K_OLD="$(uname -r)"
}
k_supported_os() {
  [[ "$K_ARCH" == x86_64 ]] || return 1
  case "$K_OS:$K_SUITE" in debian:bookworm|debian:trixie|ubuntu:noble|ubuntu:resolute) return 0 ;; *) return 1 ;; esac
}
k_cpu_level() {
  # Every visible vCPU must expose the requested ISA; no -march=native build.
  awk -F: '
    /^flags[[:space:]]*:/ {
      flags=" " $2 " "; gsub(/[[:space:]]+/," ",flags); level=1
      split("cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3",need," "); good=1
      for(i in need) if(index(flags," " need[i] " ")==0)good=0
      if(good)level=2
      split("avx avx2 bmi1 bmi2 f16c fma abm movbe xsave",need3," ")
      for(i in need3)if(index(flags," " need3[i] " ")==0)good=0
      if(good)level=3
      if(!n || level<minimum)minimum=level; n++
    }
    END {print (n?minimum:0)}' "${1:-/proc/cpuinfo}"
}
k_choose_meta() {
  local max="$1" level="$K_CPU"
  [[ "$level" != auto ]] || level=1
  (( max >= level )) || k_die "CPU 可确认等级为 v${max}，不能使用 v${level} 内核"
  if [[ "$K_TRACK" == lts ]]; then K_META="linux-xanmod-lts-x64v${level}"
  else K_META="linux-xanmod-x64v${level}"; fi
  K_CPU="$level"
}
k_running_bbr_version() {
  if [[ -r /sys/module/tcp_bbr/version ]]; then cat /sys/module/tcp_bbr/version
  else printf 'unknown\n'; fi
}
k_plan() {
  k_linux; k_detect_os
  printf '\nBBRv3 内核环境评估\n----------------------------------------\n'
  printf '系统             : %s / %s\n架构             : %s\n当前内核         : %s\n' "$K_OS" "$K_SUITE" "$K_ARCH" "$K_OLD"
  printf '运行时 BBR 版本  : %s（unknown 不表示 v1）\n' "$(k_running_bbr_version)"
  printf 'Secure Boot      : %s\n' "$(k_secure_boot)"
  if [[ -f "$K_GRUB_CFG" ]] && k_have update-grub; then printf '启动管理         : 检测到 GRUB2（安装前仍需验证具体布局）\n'
  else printf '启动管理         : 未确认受支持的 GRUB2 布局，不自动更换内核\n'; fi
  printf 'CPU 可确认等级   : x86-64-v%s\n' "$(k_cpu_level)"
  if k_supported_os; then
    k_choose_meta "$(k_cpu_level)"
    printf '建议候选包       : %s（安装时解析版本，不固定过时版本号）\n' "$K_META"
  else
    printf '自动安装         : 当前发行版/架构未纳入验证范围，仅提供检测\n'
  fi
  if [[ "$(k_running_bbr_version)" == 3 ]]; then printf '当前已确认 BBRv3：不必仅为启用 v3 而更换内核；仍需维护安全更新。\n'; fi
  printf '选择原则         : 优先 LTS / 保守 ISA / 保留原内核 / 重启后再实测\n'
  printf '来源             : XanMod 第三方签名仓库；不是发行版官方内核\n'
  printf '源码构建         : 固定对应源码提交，继承现有驱动，保留 BBRv3 上游算法\n'
  printf '安全限制         : 需非容器、GRUB2、Secure Boot 关闭、无 DKMS 依赖\n'
  printf '注意             : bbr 名称及 x64v3 包后缀均不能单独证明 BBRv3\n\n'
}
k_secure_boot() {
  [[ -d /sys/firmware/efi ]] || { echo disabled; return; }
  if k_have mokutil; then
    local status
    status="$(LC_ALL=C mokutil --sb-state 2>/dev/null)" || { echo unknown; return; }
    case "$status" in *'SecureBoot disabled'*) echo disabled ;; *'SecureBoot enabled'*) echo enabled ;; *) echo unknown ;; esac
  elif k_have python3; then
    python3 - <<'PY_SB'
import glob
paths=glob.glob('/sys/firmware/efi/efivars/SecureBoot-*')
try:
    data=open(paths[0],'rb').read()
    print({0:'disabled',1:'enabled'}.get(data[4],'unknown'))
except (OSError,IndexError): print('unknown')
PY_SB
  else echo unknown
  fi
}
k_grub_entry() {
  python3 - "$1" "${2:-$K_GRUB_CFG}" <<'PY_GRUB'
import re, sys
release=sys.argv[1]
parent=''; found=[]
for line in open(sys.argv[2], encoding='utf-8'):
    # Distribution-generated stable IDs, not display titles or executable shell.
    if re.match(r'^\s*submenu\s',line):
        ids=re.findall(r'''["'](gnulinux-advanced-[^"']+)["']''',line)
        parent=ids[-1] if ids else ''
    if not re.match(r'^\s*menuentry\s',line): continue
    ids=re.findall(r'''["'](gnulinux-[^"']+)["']''',line)
    for item in ids:
        if item.startswith('gnulinux-'+release+'-advanced-'):
            found.append((parent+'>' if parent else '')+item)
if len(found)!=1: sys.exit('Cannot identify exactly one non-recovery GRUB entry for '+release)
print(found[0])
PY_GRUB
}
k_require_console() {
  (( K_CONSOLE )) || {
    k_yes_no '已确认云控制台/救援可用，能在新内核无法启动时手动重启或选择旧内核？' || k_die '必须先确认带外恢复能力；非交互使用 --console-available'
    K_CONSOLE=1
  }
}
k_confirm_install() {
  printf '\n将使用 XanMod 第三方内核；安装可能触发 initramfs、GRUB 及软件包维护脚本。\n'
  printf '保留旧内核为默认；不会自动重启。编译不会承诺获得比预编译内核更高的网速。\n'
  k_require_console
  (( K_YES )) || k_yes_no "继续 ${K_ACTION} 操作并允许安装所需依赖？" || k_die '已取消'
}
k_lock() {
  mkdir -p "$K_ROOT"
  command -v flock >/dev/null || k_die '缺少 flock（util-linux），不能安全串行化内核操作'
  exec 9>"${K_ROOT}/lock"
  flock -n 9 || k_die '另一个内核操作正在运行'
}
k_init_session() {
  umask 077
  K_SESSION="${K_ROOT}/$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$K_SESSION"
  exec > >(tee -a "${K_SESSION}/run.log") 2>&1
  trap k_failed EXIT
  k_log "审计目录：$K_SESSION"
}
k_save_state() {
  python3 - "$K_SESSION" "$K_STATUS" "$K_OLD" "$K_TARGET" "$K_OLD_ENTRY" "$K_TARGET_ENTRY" "$K_METHOD" "$K_META" "$K_META_VERSION" "$K_TAG" "$K_COMMIT" <<'PY_STATE'
import json, os, sys
keys=['status','old_kernel','target_kernel','old_entry','target_entry','method','package','package_version','source_tag','source_commit']
path=sys.argv[1]+'/state.json'
with open(path+'.tmp','w') as f: json.dump(dict(zip(keys,sys.argv[2:])),f,ensure_ascii=False,indent=2)
os.replace(path+'.tmp',path)
PY_STATE
}
k_failed() {
  local rc=$?
  trap - EXIT
  if (( rc )); then
    k_log "操作未完成（退出码 ${rc}）；不会自动重启或删除任何内核"
    if (( K_BOOT_GUARDED )); then
      k_log "已设置旧内核为默认；请先检查 ${K_SESSION}/run.log，勿盲目重启"
    fi
  fi
  exit "$rc"
}
k_require_environment() {
  k_linux; k_root; k_detect_os
  k_supported_os || k_die '自动内核安装仅支持 Debian 12/13、Ubuntu 24.04/26.04 的 amd64 服务器'
  [[ ! -e /.dockerenv && ! -e /run/.containerenv && ! -d /proc/vz ]] || k_die '容器不能更换宿主机内核'
  if k_have systemd-detect-virt && systemd-detect-virt --container --quiet; then k_die '容器环境不允许安装内核'; fi
  [[ ! -f /var/lib/bbr-tcp-tuning/pending-latest/armed ]] || k_die '存在待确认的 TCP 调优，请先 confirm 或 rollback'
  if [[ -f "${K_LATEST}/state.json" ]]; then
    local phase
    k_have python3 || k_die '已有内核操作记录但缺少 python3，请先恢复解析依赖后处理原会话'
    phase="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "${K_LATEST}/state.json")"
    case "$phase" in accepted|fallback-planned) ;; *) k_die '上次内核安装尚未完成确认，请先 verify/accept 或 fallback' ;; esac
  fi
  for cmd in apt-get apt-cache apt-mark dpkg dpkg-deb dpkg-query findmnt lsblk modinfo modprobe update-grub grub-editenv grub-set-default grub-reboot; do
    k_have "$cmd" || k_die "不支持的启动/软件包环境，缺少 ${cmd}"
  done
  [[ "$(dpkg --print-architecture)" == amd64 ]] || k_die '软件包架构不是 amd64'
  [[ -f "$K_GRUB_CFG" && -f "$K_GRUB_DEFAULT" && -r "${K_BOOT_DIR}/config-${K_OLD}" && -s "${K_BOOT_DIR}/vmlinuz-${K_OLD}" && -s "${K_BOOT_DIR}/initrd.img-${K_OLD}" ]] || k_die '缺少标准 GRUB、运行内核、配置或 initramfs；不能保证旧内核可启动'
  [[ ! -d /sys/firmware/efi || -d /sys/firmware/efi/efivars ]] || k_die '无法验证 UEFI Secure Boot 状态'
  local boot_fs boot_source boot_type
  boot_fs="$(findmnt -nro FSTYPE -T /boot/grub)"; boot_source="$(findmnt -nro SOURCE -T /boot/grub)"
  case "$boot_fs" in ext2|ext3|ext4) ;; *) k_die '当前 /boot 文件系统未验证 GRUB 一次性启动环境写回，停止自动安装' ;; esac
  boot_type="$(lsblk -ndro TYPE "$boot_source")"
  case "$boot_type" in part|disk) ;; *) k_die 'LVM/RAID/特殊 /boot 设备不能保证 GRUB 一次性启动恢复，需人工管理' ;; esac
  local root_fs
  root_fs="$(findmnt -nro FSTYPE -T /)"
  case "$root_fs" in ext2|ext3|ext4|xfs|btrfs) ;; *) k_die '当前根文件系统依赖未纳入通用内核验证（例如 ZFS/网络根），停止自动安装' ;; esac
  # Fail closed for out-of-tree drivers; boot-critical ZFS/DKMS cannot be inferred from iperf.
  if [[ -d /var/lib/dkms ]] && find /var/lib/dkms -mindepth 2 -maxdepth 2 -type d -print -quit | grep -q .; then
    k_die '检测到 DKMS 模块；需先人工验证驱动兼容性，本工具不自动替换该服务器内核'
  fi
  [[ -z "$(dpkg --audit)" ]] || k_die 'dpkg 存在未完成配置，请先修复软件包状态'
  local free_boot free_root
  free_boot="$(df -Pk /boot | awk 'END {print $4}')"; free_root="$(df -Pk / | awk 'END {print $4}')"
  (( free_boot >= 524288 && free_root >= 2097152 )) || k_die '需要 /boot 至少 512 MiB、根文件系统至少 2 GiB 空闲空间'
}
k_prepare_tools() {
  local cmd missing=0
  for cmd in curl gpg python3; do k_have "$cmd" || missing=1; done
  if (( missing )); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y ca-certificates curl gnupg python3
  fi
}
k_key_fingerprint() {
  awk -F: '$1=="pub"{n++;want=1} $1=="fpr"&&want{finger=$10;want=0} END{if(n==1)print finger}'
}
k_prepare_repo() {
  mkdir -p "${K_SESSION}/lists/partial" "${K_SESSION}/packages" "${K_SESSION}/gnupg"
  k_fetch "$K_KEY_URL" "${K_SESSION}/archive.asc"
  local fpr
  fpr="$(gpg --homedir "${K_SESSION}/gnupg" --batch --show-keys --with-colons "${K_SESSION}/archive.asc" | k_key_fingerprint)"
  [[ "$fpr" == "$K_KEY_FINGERPRINT" ]] || k_die 'XanMod 仓库密钥指纹不匹配，停止；不会自动信任新密钥'
  gpg --homedir "${K_SESSION}/gnupg" --batch --dearmor --output "${K_SESSION}/keyring.gpg" "${K_SESSION}/archive.asc"
  printf 'deb [arch=amd64 signed-by=%s] %s %s main\n' "${K_SESSION}/keyring.gpg" "$K_REPO_URL" "$K_SUITE" >"${K_SESSION}/sources.list"
  K_APT=(-o "Dir::Etc::sourcelist=${K_SESSION}/sources.list" -o 'Dir::Etc::sourceparts=-' -o "Dir::State::lists=${K_SESSION}/lists" -o 'APT::Get::AllowUnauthenticated=false' -o 'Acquire::AllowInsecureRepositories=false' -o 'Acquire::AllowDowngradeToInsecureRepositories=false' -o 'APT::Sandbox::User=root')
  # Isolated, root-private APT state: no permanent third-party source or global key.
  apt-get "${K_APT[@]}" update
  K_META_VERSION="$(apt-cache "${K_APT[@]}" policy "$K_META" | awk '/Candidate:/ {print $2;exit}')"
  [[ -n "$K_META_VERSION" && "$K_META_VERSION" != '(none)' ]] || k_die "仓库未提供兼容候选 ${K_META}；不会安装其他架构或来源的内核"
  apt-cache "${K_APT[@]}" show "${K_META}=${K_META_VERSION}" >"${K_SESSION}/package.txt"
  local browser
  browser="$(awk -F': ' '/^Vcs-Browser:/{print $2;exit}' "${K_SESSION}/package.txt")"
  K_TAG="${browser##*/}"
  [[ "$browser" == "https://gitlab.com/xanmod/linux/-/tree/${K_TAG}" && "$K_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+-xanmod[0-9]+$ ]] || k_die '候选缺少可验证的稳定版源码标签'
  k_fetch https://www.kernel.org/releases.json "${K_SESSION}/kernel-releases.json"
  k_check_maintained "$K_TAG" "${K_SESSION}/kernel-releases.json"
  k_log "候选：${K_META} ${K_META_VERSION}；源码标签：${K_TAG}"
}
k_check_maintained() {
  python3 - "$1" "$2" <<'PY_MAINTAINED'
import json, re, sys
match=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)-xanmod\d+',sys.argv[1])
if not match: sys.exit('Invalid stable kernel tag')
version=tuple(map(int,match.groups()))
for item in json.load(open(sys.argv[2]))['releases']:
    if item.get('moniker') not in ('stable','longterm') or item.get('iseol'): continue
    if not re.fullmatch(r'\d+\.\d+\.\d+',item['version']): continue
    current=tuple(map(int,item['version'].split('.')))
    if current[:2]==version[:2] and version>=current:
        print('维护检查：同系列最新稳定/LTS 修订已满足（不含 RC 或 EOL 分支）')
        break
else: sys.exit('Candidate is EOL, unlisted, or behind current upstream security revision; wait for vendor update')
PY_MAINTAINED
}
k_guard_old_boot() {
  [[ ! -f /var/lib/bbr-tcp-tuning/pending-latest/armed ]] || k_die '下载/编译期间出现待确认 TCP 调优，先处理后再安装内核'
  [[ "$(k_secure_boot)" == disabled ]] || k_die 'Secure Boot 已启用或状态未知；不自动关闭、不自动注册签名密钥'
  K_OLD_ENTRY="$(k_grub_entry "$K_OLD")" || k_die '无法确定运行内核的稳定启动项 ID'
  grub-editenv "$K_GRUB_ENV" list >"${K_SESSION}/grubenv.before"
  if grep -q '^next_entry=.' "${K_SESSION}/grubenv.before"; then k_die '已有一次性启动项，需先处理，不能覆盖'; fi
  cp -a "$K_GRUB_DEFAULT" "${K_SESSION}/grub.before"
  if [[ -f "$K_GRUB_DROP" ]]; then cp -a "$K_GRUB_DROP" "${K_SESSION}/grub-drop.before"; fi
  mkdir -p "$(dirname "$K_GRUB_DROP")"
  # Save the old ID before generating any new GRUB config or installing an image.
  grub-set-default "$K_OLD_ENTRY"
  printf '# Managed by bbr-tune kernel; retain the verified default\nGRUB_DEFAULT=saved\nGRUB_SAVEDEFAULT=false\n' >"${K_GRUB_DROP}.tmp"
  chmod 0644 "${K_GRUB_DROP}.tmp"; mv "${K_GRUB_DROP}.tmp" "$K_GRUB_DROP"
  update-grub
  grep -Fq 'set default="${saved_entry}"' "$K_GRUB_CFG" && grep -Fq 'save_env next_entry' "$K_GRUB_CFG" || k_die 'GRUB 未生成 saved 默认项及可清除的一次性启动逻辑'
  local old_package
  old_package="$(dpkg-query -S "${K_BOOT_DIR}/vmlinuz-${K_OLD}" | sed -n 's/: .*vmlinuz-.*$//p')"
  [[ "$old_package" =~ ^linux-image[-a-zA-Z0-9.+~]+$ ]] || k_die '无法确认旧内核的软件包归属'
  apt-mark manual "$old_package"
  grub-editenv "$K_GRUB_ENV" list | grep -Fxq "saved_entry=${K_OLD_ENTRY}" || k_die '旧内核默认项未能读回验证'
  K_BOOT_GUARDED=1; K_STATUS=prepared
  k_save_state
  ln -sfn "$K_SESSION" "$K_LATEST"
  k_log "旧内核保持默认：${K_OLD}；不会删除或自动重启"
}
k_download_packages() {
  local deps image headers
  deps="$(awk -F': ' '/^Depends:/{print $2;exit}' "${K_SESSION}/package.txt")"
  image="$(grep -oE 'linux-image-[0-9][a-zA-Z0-9.+~-]*' <<<"$deps" | head -n1)"
  headers="$(grep -oE 'linux-headers-[0-9][a-zA-Z0-9.+~-]*' <<<"$deps" | head -n1)"
  [[ -n "$image" && "$headers" == "linux-headers-${image#linux-image-}" ]] || k_die '无法解析唯一且匹配的内核 image / headers'
  K_TARGET="${image#linux-image-}"
  [[ "$K_TARGET" == "${K_TAG%-xanmod*}-x64v${K_CPU}-xanmod${K_TAG##*-xanmod}" ]] || k_die '内核 release 与已审核源码版本/CPU 等级不一致'
  (cd "${K_SESSION}/packages"; apt-get "${K_APT[@]}" download "${K_META}=${K_META_VERSION}" "$image" "$headers")
}
k_build_jobs() {
  local total_kib="$1" available_kib="$2" cpus="$3" memory jobs
  (( total_kib >= 2097152 && available_kib >= 1572864 )) || return 1
  memory=$((total_kib * 2 / 3)); (( available_kib >= memory )) || memory="$available_kib"
  jobs=$(( memory / 1572864 )); (( jobs > 0 )) || jobs=1
  (( jobs <= cpus )) || jobs="$cpus"; (( jobs <= 8 )) || jobs=8
  printf '%s\n' "$jobs"
}
k_build_source() {
  local total available cpus jobs work uid refsha
  total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"; available="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
  cpus="$(getconf _NPROCESSORS_ONLN)"
  jobs="$(k_build_jobs "$total" "${available:-0}" "$cpus")" || k_die '源码编译至少需要 2 GiB 总内存、1.5 GiB 当前可用内存；不自动创建 swap'
  (( $(df -Pk /var/tmp | awk 'END{print $4}') >= 62914560 )) || k_die '保留原调试/驱动配置的源码构建要求 /var/tmp 至少 60 GiB 空闲；建议使用预编译内核'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y build-essential bc bison flex libssl-dev libelf-dev dwarves libncurses-dev rsync fakeroot dpkg-dev git cpio python3 zstd lz4
  if ! id bbr-kbuild >/dev/null 2>&1; then useradd --system --no-create-home --shell /usr/sbin/nologin bbr-kbuild; fi
  uid="$(id -u bbr-kbuild)"; (( uid > 0 )) || k_die '构建用户不能为 root'
  work="$(mktemp -d /var/tmp/bbr-kbuild.XXXXXX)"
  printf '%s\n' "$work" >"${K_SESSION}/build-directory.txt"
  chmod 0750 "$work"; chown bbr-kbuild "$work"
  runuser -u bbr-kbuild -- git init "${work}/linux"
  runuser -u bbr-kbuild -- git -C "${work}/linux" remote add origin "$K_REPO"
  git -c http.version=HTTP/1.1 ls-remote --exit-code "$K_REPO" "refs/tags/${K_TAG}" "refs/tags/${K_TAG}^{}" >"${K_SESSION}/source-ref.txt"
  refsha="$(awk 'NR==1 {sha=$1} /\^\{\}$/ {sha=$1} END{print sha}' "${K_SESSION}/source-ref.txt")"
  [[ "$refsha" =~ ^[0-9a-f]{40}$ ]] || k_die '无法解析固定源码提交'
  K_COMMIT="$refsha"
  runuser -u bbr-kbuild -- git -c http.version=HTTP/1.1 -C "${work}/linux" fetch --depth=1 origin "$K_COMMIT"
  runuser -u bbr-kbuild -- git -C "${work}/linux" checkout --detach FETCH_HEAD
  [[ "$(runuser -u bbr-kbuild -- git -C "${work}/linux" rev-parse HEAD)" == "$K_COMMIT" ]] || k_die '源码提交不一致'
  grep -Eq '^#define[[:space:]]+BBR_VERSION[[:space:]]+3([[:space:]]|$)' "${work}/linux/net/ipv4/tcp_bbr.c" || k_die '源码不能确认 BBR_VERSION=3'
  cp "${K_BOOT_DIR}/config-${K_OLD}" "${work}/linux/.config"
  chown bbr-kbuild "${work}/linux/.config"
  cp "${K_BOOT_DIR}/config-${K_OLD}" "${K_SESSION}/config.before"
  local config="${work}/linux/scripts/config"
  runuser -u bbr-kbuild -- "$config" --file "${work}/linux/.config" \
    --enable NET_SCHED --enable NET_SCH_FQ --enable TCP_CONG_ADVANCED --module TCP_CONG_BBR \
    --enable GENERIC_CPU --disable X86_NATIVE_CPU --set-val X86_64_VERSION "$K_CPU" \
    --disable LOCALVERSION_AUTO --set-str LOCALVERSION "-bbrtune-${K_COMMIT:0:12}" \
    --set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS '' --set-str MODULE_SIG_KEY certs/signing_key.pem
  if grep -Fxq 'CONFIG_DEFAULT_BBR=y' "${K_SESSION}/config.before"; then
    runuser -u bbr-kbuild -- "$config" --file "${work}/linux/.config" --enable TCP_CONG_BBR
  fi
  runuser -u bbr-kbuild -- make -C "${work}/linux" olddefconfig
  grep -Eq '^CONFIG_TCP_CONG_BBR=[ym]$' "${work}/linux/.config" || k_die '构建配置未启用 BBR'
  for expected in CONFIG_NET_SCH_FQ=y CONFIG_GENERIC_CPU=y "CONFIG_X86_64_VERSION=${K_CPU}"; do
    grep -Fxq "$expected" "${work}/linux/.config" || k_die "构建配置未能保留要求：${expected}"
  done
  cp "${work}/linux/.config" "${K_SESSION}/config.build"
  diff -u "${K_SESSION}/config.before" "${K_SESSION}/config.build" >"${K_SESSION}/config.diff" || [[ $? == 1 ]]
  K_TARGET="$(runuser -u bbr-kbuild -- make -s --no-print-directory -C "${work}/linux" kernelrelease)"
  [[ "$K_TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-xanmod[0-9]+)?-bbrtune-[0-9a-f]{12}$ ]] || k_die '自编译 release 异常，停止以避免覆盖运行内核'
  [[ "${K_TARGET%%-*}" == "${K_TAG%%-*}" ]] || k_die '源码构建版本与已审核候选不一致'
  k_log "源码：${K_COMMIT}；构建并发：${jobs}；目录：${work}"
  runuser -u bbr-kbuild -- make -C "${work}/linux" -j"$jobs" bindeb-pkg
  local deb name
  for deb in "$work"/*.deb; do
    [[ -f "$deb" ]] || continue
    name="$(dpkg-deb -f "$deb" Package)"
    case "$name" in "linux-image-${K_TARGET}"|"linux-headers-${K_TARGET}") cp "$deb" "${K_SESSION}/packages/" ;; esac
  done
}
k_install_artifacts() {
  local deb name arch images=0 headers=0
  local debs=()
  [[ "$K_TARGET" != "$K_OLD" && ! -e "${K_BOOT_DIR}/vmlinuz-${K_TARGET}" ]] || k_die '目标内核已经存在；不会覆盖当前或现有内核'
  for deb in "${K_SESSION}/packages/"*.deb; do
    [[ -f "$deb" ]] || continue
    name="$(dpkg-deb -f "$deb" Package)"; arch="$(dpkg-deb -f "$deb" Architecture)"
    [[ "$arch" == amd64 || "$arch" == all ]] || k_die "包架构错误：${name} ${arch}"
    case "$name" in
      "linux-image-${K_TARGET}") images=$((images+1)) ;;
      "linux-headers-${K_TARGET}") headers=$((headers+1)) ;;
      "$K_META") continue ;; # Do not enable future unattended kernel upgrades through a meta-package.
      *) k_die "不安装未经选择的软件包：$name" ;;
    esac
    debs+=("$deb")
  done
  (( images == 1 && headers == 1 )) || k_die '必须恰有一个内核 image 和一个 headers 包'
  sha256sum "${debs[@]}" >"${K_SESSION}/packages.sha256"
  k_guard_old_boot
  DEBIAN_FRONTEND=noninteractive apt-get install --no-remove -y "${debs[@]}"
  [[ -s "${K_BOOT_DIR}/vmlinuz-${K_TARGET}" && -s "${K_BOOT_DIR}/initrd.img-${K_TARGET}" && -d "${K_MODULES_DIR}/${K_TARGET}" ]] || k_die '目标内核、initramfs 或 modules 不完整，不安排启动'
  grep -Eq '^CONFIG_TCP_CONG_BBR=[ym]$' "${K_BOOT_DIR}/config-${K_TARGET}" || k_die '已安装内核不包含 BBR'
  local version
  version="$(modinfo -k "$K_TARGET" -F version tcp_bbr 2>/dev/null || true)"
  [[ "$version" == 3 ]] || k_die '已安装内核不能通过模块元数据确认为 BBRv3；保留旧默认项，不安排试用'
  update-grub
  K_TARGET_ENTRY="$(k_grub_entry "$K_TARGET")" || k_die '新内核缺少可识别启动项'
  [[ "$(k_grub_entry "$K_OLD")" == "$K_OLD_ENTRY" ]] || k_die '旧内核启动项发生变化，停止'
  grub-editenv "$K_GRUB_ENV" list | grep -Fxq "saved_entry=${K_OLD_ENTRY}" || k_die '默认启动项不再是旧内核，请检查 GRUB'
  K_STATUS=installed; k_save_state
  k_log "已安装 ${K_TARGET}；当前仍运行 ${K_OLD}，不能宣称 BBRv3 已生效"
  k_log '下一步：sudo bbr-tune kernel trial；阅读恢复说明后自行安排重启'
  k_log '重启后：sudo bbr-tune kernel verify；验证业务后 sudo bbr-tune kernel accept'
  k_log '未添加持久第三方软件源，未安装跟随升级的元包；安全更新需定期重新评估并运行安装流程'
}
k_install() {
  k_linux; k_root; k_detect_os
  k_require_environment
  k_confirm_install
  k_lock; k_init_session
  k_prepare_tools
  k_choose_meta "$(k_cpu_level)"
  [[ "$(k_secure_boot)" == disabled ]] || k_die 'Secure Boot 已启用或未知，停止自动安装'
  k_grub_entry "$K_OLD" >/dev/null || k_die '原内核启动项不明确，拒绝开始内核下载或编译'
  k_prepare_repo
  if [[ "$K_ACTION" == build ]]; then K_METHOD=source; k_build_source
  else K_METHOD=package; k_download_packages; fi
  k_install_artifacts
  trap - EXIT
}
k_read_field() {
  python3 - "$K_SESSION/state.json" "$1" <<'PY_FIELD'
import json,sys
v=json.load(open(sys.argv[1]))[sys.argv[2]]
if not isinstance(v,str) or '\n' in v or '\t' in v: sys.exit('Invalid kernel state')
print(v)
PY_FIELD
}
k_load_last() {
  [[ -f "${K_LATEST}/state.json" ]] || k_die '没有可继续的内核操作记录'
  K_SESSION="$(cd "$K_LATEST" && pwd -P)"
  K_STATUS="$(k_read_field status)"; K_OLD="$(k_read_field old_kernel)"; K_TARGET="$(k_read_field target_kernel)"
  K_OLD_ENTRY="$(k_read_field old_entry)"; K_TARGET_ENTRY="$(k_read_field target_entry)"
  K_METHOD="$(k_read_field method)"; K_META="$(k_read_field package)"; K_META_VERSION="$(k_read_field package_version)"
  K_TAG="$(k_read_field source_tag)"; K_COMMIT="$(k_read_field source_commit)"
}
k_verify() {
  [[ "$(uname -r)" == "$K_TARGET" ]] || k_die "当前运行 $(uname -r)，不是目标 ${K_TARGET}；尚未完成内核切换"
  modprobe tcp_bbr
  [[ "$(k_running_bbr_version)" == 3 ]] || k_die '运行时 BBR 版本不能确认为 3；不以算法名称 bbr 或内核包后缀代替证明'
  printf '\n运行内核     : %s\n运行时 BBR   : 3\n拥塞控制默认 : %s\n' "$K_TARGET" "$(sysctl -n net.ipv4.tcp_congestion_control)"
  printf '验证通过；只验证内核能力，未修改 TCP 参数。请检查代理业务后再 accept。\n'
}
k_continue() {
  k_linux; k_root; k_lock; k_load_last
  exec > >(tee -a "${K_SESSION}/run.log") 2>&1
  case "$K_ACTION" in
    verify) k_verify ;;
    trial)
      [[ "$K_STATUS" == installed || "$K_STATUS" == trial ]] || k_die "当前阶段 ${K_STATUS} 不能安排试用"
      [[ "$(uname -r)" == "$K_OLD" ]] || k_die '已不在原内核，先 verify，不重复安排试用'
      k_require_console
      local next
      next="$(grub-editenv "$K_GRUB_ENV" list | sed -n 's/^next_entry=//p')"
      [[ -z "$next" || "$next" == "$K_TARGET_ENTRY" ]] || k_die '存在其他一次性启动请求，不能覆盖'
      grep -Fq 'set default="${saved_entry}"' "$K_GRUB_CFG" || k_die 'GRUB 不再使用 saved 默认项，不能安全安排试用'
      [[ "$(k_grub_entry "$K_OLD")" == "$K_OLD_ENTRY" && "$(k_grub_entry "$K_TARGET")" == "$K_TARGET_ENTRY" ]] || k_die '启动项变化，不能安全试用'
      grub-set-default "$K_OLD_ENTRY"
      grub-reboot "$K_TARGET_ENTRY"
      grub-editenv "$K_GRUB_ENV" list | grep -Fxq "next_entry=${K_TARGET_ENTRY}" || k_die '一次性启动项未能读回'
      K_STATUS=trial; k_save_state
      k_log '仅下一次启动试用新内核；请自行安排重启，本工具没有执行 reboot'
      k_log '若新内核无法启动，需使用控制台手动重启/选择旧内核；不保证无人值守自动恢复' ;;
    accept)
      [[ "$K_STATUS" == installed || "$K_STATUS" == trial || "$K_STATUS" == accepted ]] || k_die '当前阶段不能确认新内核'
      k_verify
      (( K_YES )) || k_yes_no '代理业务、网卡、存储与 SSH 已验证，确认新内核为默认？' || k_die '未确认'
      K_TARGET_ENTRY="$(k_grub_entry "$K_TARGET")"
      grub-set-default "$K_TARGET_ENTRY"; grub-editenv "$K_GRUB_ENV" unset next_entry
      grub-editenv "$K_GRUB_ENV" list | grep -Fxq "saved_entry=${K_TARGET_ENTRY}" || k_die '默认项读回失败'
      K_STATUS=accepted; k_save_state
      k_log '已确认默认内核；现在可以运行 sudo bbr-tune，对 BBRv3 重新做单/多连接实测' ;;
    fallback)
      [[ -s "${K_BOOT_DIR}/vmlinuz-${K_OLD}" && -s "${K_BOOT_DIR}/initrd.img-${K_OLD}" ]] || k_die '旧内核文件缺失，需使用云救援环境'
      K_OLD_ENTRY="$(k_grub_entry "$K_OLD")"
      (( K_YES )) || k_yes_no "将下次启动和默认项恢复为 ${K_OLD}？不会立即重启" || k_die '已取消'
      grub-set-default "$K_OLD_ENTRY"; grub-reboot "$K_OLD_ENTRY"
      grub-editenv "$K_GRUB_ENV" list | grep -Fxq "saved_entry=${K_OLD_ENTRY}" || k_die '旧默认项读回失败'
      K_STATUS=fallback-planned; k_save_state
      k_log "下次启动旧内核 ${K_OLD}；当前内核不变，请自行安排重启" ;;
  esac
}
k_status() {
  k_linux
  printf '当前运行内核：%s\n运行时 BBR 版本：%s\n' "$(uname -r)" "$(k_running_bbr_version)"
  if [[ -r "${K_LATEST}/state.json" ]]; then
    k_load_last
    printf '操作阶段：%s\n原内核：%s\n目标内核：%s\n方法：%s\n日志目录：%s\n' "$K_STATUS" "$K_OLD" "$K_TARGET" "$K_METHOD" "$K_SESSION"
  else printf '尚无内核操作记录，或当前用户无权读取。\n'; fi
}
k_menu() {
  local choice
  [[ -t 0 ]] || { k_usage; return; }
  printf '\nBBRv3 内核管理\n  1) 检测环境与选择建议\n  2) 安装 LTS 预编译内核（推荐）\n  3) 从固定源码构建 LTS 内核\n  4) 下一次启动试用新内核\n  5) 重启后验证 BBRv3\n  6) 确认新内核为默认\n  7) 下次恢复旧内核\n  8) 查看操作状态\n  0) 返回\n'
  read -r -p '请选择：' choice || return
  case "$choice" in 1) K_ACTION=plan ;; 2) K_ACTION=install ;; 3) K_ACTION=build ;; 4) K_ACTION=trial ;; 5) K_ACTION=verify ;; 6) K_ACTION=accept ;; 7) K_ACTION=fallback ;; 8) K_ACTION=status ;; 0) return ;; *) k_die '无效选择' ;; esac
  k_dispatch
}
k_dispatch() {
  case "$K_ACTION" in
    menu) k_menu ;; plan) k_plan ;; install|build) k_install ;;
    trial|verify|accept|fallback) k_continue ;; status) k_status ;; help|--help) k_usage ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then k_parse "$@"; k_dispatch; fi
