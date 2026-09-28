#!/usr/bin/env bash
# bbr-tune.sh - 远程 Linux 服务器 TCP/BBR 自动测试与参数寻优工具
set -Eeuo pipefail

VERSION="2.0.0"
PROGRAM="${0##*/}"
SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="${PWD}/${SCRIPT_PATH}"

STATE_DIR="/var/lib/bbr-tcp-tuning"
SESSION_ROOT="${STATE_DIR}/sessions"
BACKUP_ROOT="${STATE_DIR}/backups"
LATEST_BACKUP="${STATE_DIR}/latest"
PENDING_DIR="${STATE_DIR}/pending"
PENDING_LATEST="${STATE_DIR}/pending-latest"
HISTORY_FILE="${STATE_DIR}/history.tsv"
SYSCTL_FILE="/etc/sysctl.d/99-bbr-tcp-tuning.conf"
MODULES_FILE="/etc/modules-load.d/bbr-tcp-tuning.conf"
ENV_FILE="/etc/default/bbr-tcp-tuning"
QDISC_HELPER="/usr/local/sbin/bbr-tcp-qdisc"
SERVICE_FILE="/etc/systemd/system/bbr-tcp-tuning.service"

COMMAND="menu"
IFACE="auto"
SERVER_ADDRESS=""
TARGET_MBPS=""
RTT_MS=""
START_STREAMS="1"
TEST_STREAMS="1"
DURATION="15"
WAIT_SECONDS="300"
MAX_CANDIDATES="4"
TARGET_UTILIZATION="90"
MAX_RETRANS_PERCENT="1"
AUTO_ROLLBACK_SECONDS="3600"
PERSIST_FINAL="0"
FORCE="0"
YES="0"
BACKUP_PATH=""
QUIET="0"

SESSION_ID=""
SESSION_DIR=""
RUN_LOG=""
REPORT_FILE=""
COMPARISON_FILE=""
TEST_PORT=""
CURRENT_TEST_PID=""
BACKUP_DIR=""
TUNING_ACTIVE="0"

MEM_TOTAL_MIB="0"
MEM_AVAILABLE_MIB="0"
MEM_EFFECTIVE_MIB="0"
MEM_BUFFER_CAP_MIB="0"
BDP_BYTES="0"
BDP_MIB="0"

RESULT_MBPS="0"
RESULT_BYTES="0"
RESULT_RETRANS="0"
RESULT_RETRANS_PERCENT="100"
RESULT_SCORE="-999999"
RESULT_PASS="no"

INITIAL_SINGLE_MBPS="0"
BASELINE_MBPS="0"
BASELINE_RETRANS="0"
BASELINE_RETRANS_PERCENT="100"
BASELINE_SCORE="-999999"
BASELINE_PASS="no"
BASELINE_STREAMS="1"
BASELINE_BUFFER_BYTES="0"

BEST_KIND="baseline"
BEST_BUFFER_MIB="0"
BEST_FACTOR="original"
BEST_MBPS="0"
BEST_RETRANS="0"
BEST_RETRANS_PERCENT="100"
BEST_SCORE="-999999"
BEST_PASS="no"

FINAL_MBPS="0"
FINAL_RETRANS="0"
FINAL_RETRANS_PERCENT="100"
FINAL_SCORE="-999999"
FINAL_PASS="no"
FINAL_BUFFER_BYTES="0"
OUTCOME=""
QOS_DETECTED="0"

BEFORE_CC=""
BEFORE_QDISC=""
BEFORE_RMEM=""
BEFORE_WMEM=""
BEFORE_BUFFER_BYTES="0"

CANDIDATE_MIBS=()
CANDIDATE_FACTORS=()

log_line() {
  local level="$1"; shift
  (( QUIET )) && [[ "$level" == "INFO" ]] && return 0
  printf '[%s] [%-5s] %s\n' "$(date '+%H:%M:%S')" "$level" "$*"
}
info() { log_line INFO "$*"; }
warn() { log_line WARN "$*" >&2; }
error() { log_line ERROR "$*" >&2; }
die() { error "$*"; exit 1; }

section() {
  printf '\n┌──────────────────────────────────────────────────────────────┐\n'
  printf '│ %-60s │\n' "$*"
  printf '└──────────────────────────────────────────────────────────────┘\n'
}

usage() {
  cat <<'USAGE'
远程服务器 TCP/BBR 自动寻优工具

用法：
  sudo ./bbr-tune.sh                         交互界面
  sudo ./bbr-tune.sh autotune [参数]         自动测试并选择最优参数
  ./bbr-tune.sh status [--iface DEV]         查看当前 TCP/BBR 状态
  ./bbr-tune.sh history                      查看历史测试会话
  sudo ./bbr-tune.sh confirm                 确认保留当前参数并取消安全回滚
  sudo ./bbr-tune.sh rollback [--backup DIR] 恢复调优前参数

自动寻优参数：
  --bandwidth-mbps N       目标带宽，单位 Mbps，必填
  --rtt-ms N               本地到服务器 RTT，单位 ms，必填
  --server-address HOST    本地 iperf3 应连接的服务器地址
  --iface auto|DEV         出口网卡，默认自动识别
  --parallel N             起始并发流数，默认 1；必要时自动测试 8/16 流
  --duration N             每轮测试时长，默认 15 秒
  --wait-seconds N         每轮等待本地连接的时间，默认 300 秒
  --max-candidates N       最多测试的 TCP 缓冲候选数，默认 4
  --target-utilization N   达标吞吐百分比，默认 90
  --max-retrans-percent N  最大估算重传比例，默认 1
  --auto-rollback-seconds N 安全回滚时间，默认 3600 秒
  --persist                最优参数确认后写入持久化配置
  --force                  允许覆盖无法完整恢复的自定义 root qdisc

工作方式：
  1. 脚本始终运行在远程 Linux 服务器。
  2. 本地电脑只执行屏幕显示的 iperf3 -c ... -R 命令。
  3. 先测试调优前性能，再按服务器内存与 BDP 生成候选参数。
  4. 对候选参数逐一测试，出现性能平台后停止，复测最优候选。
  5. 如果最优候选不如原配置，自动恢复原配置。
  6. 所有结果和原始 JSON 长期保存在 /var/lib/bbr-tcp-tuning/sessions。
USAGE
}

is_integer() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
have() { command -v "$1" >/dev/null 2>&1; }
require_linux() { [[ "$(uname -s)" == "Linux" ]] || die "该操作只能在远程 Linux 服务器执行"; }
require_root() { (( EUID == 0 )) || die "该操作需要 root 权限，请使用 sudo"; }

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "参数 $1 缺少值"
}

parse_args() {
  if (( $# == 0 )); then
    COMMAND="menu"
    return
  fi
  case "$1" in
    menu|autotune|status|history|confirm|rollback|help) COMMAND="$1"; shift ;;
    --help|-h) COMMAND="help"; shift ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    *) die "未知命令：$1" ;;
  esac

  while (( $# )); do
    case "$1" in
      --bandwidth-mbps) need_value "$@"; TARGET_MBPS="$2"; shift 2 ;;
      --rtt-ms) need_value "$@"; RTT_MS="$2"; shift 2 ;;
      --server-address) need_value "$@"; SERVER_ADDRESS="$2"; shift 2 ;;
      --iface) need_value "$@"; IFACE="$2"; shift 2 ;;
      --parallel) need_value "$@"; START_STREAMS="$2"; shift 2 ;;
      --duration) need_value "$@"; DURATION="$2"; shift 2 ;;
      --wait-seconds) need_value "$@"; WAIT_SECONDS="$2"; shift 2 ;;
      --max-candidates) need_value "$@"; MAX_CANDIDATES="$2"; shift 2 ;;
      --target-utilization) need_value "$@"; TARGET_UTILIZATION="$2"; shift 2 ;;
      --max-retrans-percent) need_value "$@"; MAX_RETRANS_PERCENT="$2"; shift 2 ;;
      --auto-rollback-seconds) need_value "$@"; AUTO_ROLLBACK_SECONDS="$2"; shift 2 ;;
      --backup) need_value "$@"; BACKUP_PATH="$2"; shift 2 ;;
      --persist) PERSIST_FINAL="1"; shift ;;
      --force) FORCE="1"; shift ;;
      --yes|-y) YES="1"; shift ;;
      --quiet|-q) QUIET="1"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
}

validate_autotune_options() {
  [[ -n "$TARGET_MBPS" && -n "$RTT_MS" ]] || die "autotune 需要 --bandwidth-mbps 和 --rtt-ms"
  is_number "$TARGET_MBPS" || die "目标带宽必须是正数"
  is_number "$RTT_MS" || die "RTT 必须是正数"
  is_integer "$START_STREAMS" || die "并发流数必须是整数"
  is_integer "$DURATION" || die "测试时长必须是整数"
  is_integer "$WAIT_SECONDS" || die "等待时间必须是整数"
  is_integer "$MAX_CANDIDATES" || die "候选数量必须是整数"
  is_number "$TARGET_UTILIZATION" || die "目标利用率必须是数字"
  is_number "$MAX_RETRANS_PERCENT" || die "重传比例必须是数字"
  is_integer "$AUTO_ROLLBACK_SECONDS" || die "安全回滚时间必须是整数"
  awk -v v="$TARGET_MBPS" 'BEGIN {exit !(v>0)}' || die "目标带宽必须大于 0"
  awk -v v="$RTT_MS" 'BEGIN {exit !(v>0)}' || die "RTT 必须大于 0"
  (( START_STREAMS >= 1 && START_STREAMS <= 64 )) || die "并发流数必须在 1~64"
  (( DURATION >= 5 && DURATION <= 300 )) || die "测试时长必须在 5~300 秒"
  (( WAIT_SECONDS >= 30 && WAIT_SECONDS <= 3600 )) || die "等待时间必须在 30~3600 秒"
  (( MAX_CANDIDATES >= 1 && MAX_CANDIDATES <= 6 )) || die "候选数量必须在 1~6"
  awk -v v="$TARGET_UTILIZATION" 'BEGIN {exit !(v>0 && v<=100)}' || die "目标利用率必须在 0~100"
  awk -v v="$MAX_RETRANS_PERCENT" 'BEGIN {exit !(v>=0 && v<=100)}' || die "重传比例必须在 0~100"
  (( AUTO_ROLLBACK_SECONDS == 0 || (AUTO_ROLLBACK_SECONDS >= 300 && AUTO_ROLLBACK_SECONDS <= 86400) )) || \
    die "安全回滚时间必须为 0，或在 300~86400 秒"
}

resolve_iface() {
  if [[ "$IFACE" != "auto" ]]; then
    printf '%s\n' "$IFACE"
    return
  fi
  ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

guess_server_address() {
  if [[ -n "$SERVER_ADDRESS" ]]; then
    printf '%s\n' "$SERVER_ADDRESS"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $3}' <<<"$SSH_CONNECTION"
  else
    ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
  fi
}

sysctl_get() { sysctl -n "$1" 2>/dev/null || true; }
sysctl_exists() { sysctl -n "$1" >/dev/null 2>&1; }

install_iperf3_if_needed() {
  have iperf3 && return 0
  require_root
  info "服务器未安装 iperf3，开始自动安装"
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y iperf3
  elif have dnf; then
    dnf install -y iperf3
  elif have yum; then
    yum install -y iperf3
  elif have zypper; then
    zypper --non-interactive install iperf3
  elif have apk; then
    apk add --no-cache iperf3
  elif have pacman; then
    pacman -S --needed --noconfirm iperf3
  else
    die "无法识别服务器包管理器，请手动安装 iperf3"
  fi
  have iperf3 || die "包管理器执行完成，但仍未找到 iperf3"
  info "iperf3 已安装：$(iperf3 --version 2>/dev/null | head -1)"
}

port_is_free() {
  local port="$1" listeners
  listeners="$(ss -H -ltn 2>/dev/null)" || return 1
  if awk -v target="$port" '{addr=$4; sub(/^.*:/,"",addr); if(addr==target) found=1} END{exit !found}' <<<"$listeners"; then
    return 1
  fi
  return 0
}

choose_random_port() {
  local port attempt
  for ((attempt=1; attempt<=300; attempt++)); do
    port=$((20000 + (((RANDOM << 15) | RANDOM) % 40000)))
    if port_is_free "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

floor_pow2() {
  awk -v n="$1" 'BEGIN {p=1; while(p*2<=n)p*=2; print p}'
}

ceil_pow2() {
  awk -v n="$1" 'BEGIN {p=1; while(p<n)p*=2; print p}'
}

detect_memory_limits() {
  local total_kib available_kib cgroup_bytes="" cgroup_mib
  total_kib="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
  [[ -n "$available_kib" ]] || available_kib="$(awk '/^MemFree:/ {print $2}' /proc/meminfo)"
  MEM_TOTAL_MIB=$(( total_kib / 1024 ))
  MEM_AVAILABLE_MIB=$(( available_kib / 1024 ))
  MEM_EFFECTIVE_MIB="$MEM_TOTAL_MIB"

  if [[ -r /sys/fs/cgroup/memory.max ]]; then
    read -r cgroup_bytes </sys/fs/cgroup/memory.max || true
  elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    read -r cgroup_bytes </sys/fs/cgroup/memory/memory.limit_in_bytes || true
  fi
  if [[ "$cgroup_bytes" =~ ^[0-9]+$ ]] && (( cgroup_bytes > 0 && cgroup_bytes < 9223372036854771712 )); then
    cgroup_mib=$(( cgroup_bytes / 1048576 ))
    if (( cgroup_mib > 0 && cgroup_mib < MEM_EFFECTIVE_MIB )); then
      MEM_EFFECTIVE_MIB="$cgroup_mib"
    fi
  fi

  calculate_memory_buffer_cap "$MEM_EFFECTIVE_MIB" "$MEM_AVAILABLE_MIB"
}

calculate_memory_buffer_cap() {
  local effective_mib="$1" available_mib="$2" by_total by_available cap
  by_total=$(( effective_mib / 64 ))
  by_available=$(( available_mib / 16 ))
  (( by_total < 4 )) && by_total=4
  (( by_available < 4 )) && by_available=4
  cap="$by_total"
  (( by_available < cap )) && cap="$by_available"
  (( cap > 256 )) && cap=256
  MEM_BUFFER_CAP_MIB="$(floor_pow2 "$cap")"
  if (( MEM_BUFFER_CAP_MIB < 4 )); then MEM_BUFFER_CAP_MIB=4; fi
  return 0
}

calculate_bdp() {
  BDP_BYTES="$(awk -v bw="$TARGET_MBPS" -v rtt="$RTT_MS" 'BEGIN {printf "%.0f", bw*1000000*(rtt/1000)/8}')"
  BDP_MIB="$(awk -v b="$BDP_BYTES" 'BEGIN {printf "%.2f", b/1048576}')"
}

add_candidate() {
  local mib="$1" factor="$2" existing
  for existing in "${CANDIDATE_MIBS[@]:-}"; do
    [[ "$existing" == "$mib" ]] && return 0
  done
  CANDIDATE_MIBS+=("$mib")
  CANDIDATE_FACTORS+=("$factor")
}

generate_candidates() {
  local factor bytes need_mib rounded
  CANDIDATE_MIBS=()
  CANDIDATE_FACTORS=()
  for factor in 1.0 1.5 2.0 3.0 4.0; do
    bytes="$(awk -v b="$BDP_BYTES" -v f="$factor" 'BEGIN {printf "%.0f", b*f}')"
    need_mib="$(awk -v b="$bytes" 'BEGIN {printf "%.0f", (b+1048575)/1048576}')"
    (( need_mib < 4 )) && need_mib=4
    rounded="$(ceil_pow2 "$need_mib")"
    (( rounded > MEM_BUFFER_CAP_MIB )) && rounded="$MEM_BUFFER_CAP_MIB"
    add_candidate "$rounded" "$factor"
    (( ${#CANDIDATE_MIBS[@]} >= MAX_CANDIDATES )) && break
  done
  (( ${#CANDIDATE_MIBS[@]} > 0 )) || add_candidate "$MEM_BUFFER_CAP_MIB" "memory-cap"
}

current_buffer_max() {
  local core_r core_w tcp_r tcp_w tr tw max=0 n
  core_r="$(sysctl_get net.core.rmem_max)"
  core_w="$(sysctl_get net.core.wmem_max)"
  tcp_r="$(sysctl_get net.ipv4.tcp_rmem)"
  tcp_w="$(sysctl_get net.ipv4.tcp_wmem)"
  tr="$(awk '{print $3}' <<<"$tcp_r")"
  tw="$(awk '{print $3}' <<<"$tcp_w")"
  for n in "$core_r" "$core_w" "$tr" "$tw"; do
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > max )) && max="$n"
  done
  printf '%s\n' "$max"
}

root_qdisc_kind() {
  tc qdisc show dev "$1" 2>/dev/null | awk '$0~/ root /{print $2; exit}'
}

qdisc_safe() {
  case "$1" in ""|noqueue|pfifo_fast|fq_codel|fq|mq) return 0 ;; *) return 1 ;; esac
}

apply_fq() {
  local iface="$1" root parents parent
  root="$(root_qdisc_kind "$iface")"
  if [[ "$root" == "mq" ]]; then
    parents="$(tc qdisc show dev "$iface" | awk '{for(i=1;i<=NF;i++) if($i=="parent" && $(i+1)~/^:/) print $(i+1)}' | sort -u)"
    if [[ -n "$parents" ]]; then
      while read -r parent; do
        [[ -n "$parent" ]] && tc qdisc replace dev "$iface" parent "$parent" fq
      done <<<"$parents"
      return
    fi
  fi
  tc qdisc replace dev "$iface" root fq
}

read_tcp_vector() {
  local key="$1" fallback="$2" value
  value="$(sysctl_get "$key")"
  if [[ "$value" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

build_sysctl_content() {
  local buffer_bytes="$1" rvec wvec rmin rdef wmin wdef
  rvec="$(read_tcp_vector net.ipv4.tcp_rmem '4096 131072 6291456')"
  wvec="$(read_tcp_vector net.ipv4.tcp_wmem '4096 16384 4194304')"
  read -r rmin rdef _ <<<"$rvec"
  read -r wmin wdef _ <<<"$wvec"
  cat <<EOF_SYSCTL
# Managed by bbr-tune.sh ${VERSION}; generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Memory-aware cap=${MEM_BUFFER_CAP_MIB}MiB, target=${TARGET_MBPS}Mbps, RTT=${RTT_MS}ms, BDP=${BDP_MIB}MiB
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${buffer_bytes}
net.core.wmem_max = ${buffer_bytes}
net.ipv4.tcp_rmem = ${rmin} ${rdef} ${buffer_bytes}
net.ipv4.tcp_wmem = ${wmin} ${wdef} ${buffer_bytes}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
EOF_SYSCTL
}

apply_sysctl_content() {
  local buffer_bytes="$1" raw filtered line key
  raw="$(mktemp)"
  filtered="$(mktemp)"
  build_sysctl_content "$buffer_bytes" >"$raw"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then
      printf '%s\n' "$line" >>"$filtered"
      continue
    fi
    key="${line%%=*}"
    key="${key//[[:space:]]/}"
    if sysctl_exists "$key"; then
      printf '%s\n' "$line" >>"$filtered"
    else
      printf '# unsupported: %s\n' "$line" >>"$filtered"
      warn "当前内核不支持 ${key}，已跳过"
    fi
  done <"$raw"
  sysctl -p "$filtered" >/dev/null
  rm -f "$raw" "$filtered"
}

ensure_bbr() {
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  local available
  available="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  [[ " $available " == *" bbr "* ]] || die "当前内核不支持 BBR"
}

apply_candidate() {
  local iface="$1" buffer_mib="$2" buffer_bytes
  buffer_bytes=$(( buffer_mib * 1048576 ))
  apply_sysctl_content "$buffer_bytes"
  apply_fq "$iface"
}

atomic_write() {
  local path="$1" mode="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

write_persistent_config() {
  local iface="$1" buffer_mib="$2" buffer_bytes
  buffer_bytes=$(( buffer_mib * 1048576 ))
  build_sysctl_content "$buffer_bytes" | atomic_write "$SYSCTL_FILE" 0644
  cat <<'EOF_MODULES' | atomic_write "$MODULES_FILE" 0644
# Managed by bbr-tune.sh
tcp_bbr
sch_fq
EOF_MODULES
  cat <<EOF_ENV | atomic_write "$ENV_FILE" 0644
# Managed by bbr-tune.sh
BBR_IFACE=$(printf '%q' "$iface")
EOF_ENV
  cat <<'EOF_HELPER' | atomic_write "$QDISC_HELPER" 0755
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/default/bbr-tcp-tuning
iface="$BBR_IFACE"
if [[ "$iface" == "auto" ]]; then
  iface="$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
root="$(tc qdisc show dev "$iface" | awk '$0~/ root /{print $2; exit}')"
if [[ "$root" == "mq" ]]; then
  parents="$(tc qdisc show dev "$iface" | awk '{for(i=1;i<=NF;i++) if($i=="parent" && $(i+1)~/^:/) print $(i+1)}' | sort -u)"
  if [[ -n "$parents" ]]; then
    while read -r parent; do [[ -n "$parent" ]] && tc qdisc replace dev "$iface" parent "$parent" fq; done <<<"$parents"
    exit 0
  fi
fi
tc qdisc replace dev "$iface" root fq
EOF_HELPER
  cat <<'EOF_SERVICE' | atomic_write "$SERVICE_FILE" 0644
[Unit]
Description=TCP BBR and fq setup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bbr-tcp-qdisc

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  if have systemctl; then
    systemctl daemon-reload
    systemctl enable bbr-tcp-tuning.service >/dev/null
    systemctl restart bbr-tcp-tuning.service
  else
    warn "系统没有 systemd：sysctl 配置已保存，但 fq qdisc 需要自行设置开机任务"
  fi
}

backup_file() {
  local backup="$1" path="$2" tag="$3"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a "$path" "${backup}/${tag}.file"
    printf '%s\tpresent\t%s\n' "$tag" "$path" >>"${backup}/files.tsv"
  else
    printf '%s\tabsent\t%s\n' "$tag" "$path" >>"${backup}/files.tsv"
  fi
}

create_backup() {
  local iface="$1" backup key value service_enabled="unknown" service_active="unknown"
  backup="${BACKUP_ROOT}/${SESSION_ID}"
  mkdir -p "$backup"
  : >"${backup}/files.tsv"
  backup_file "$backup" "$SYSCTL_FILE" sysctl
  backup_file "$backup" "$MODULES_FILE" modules
  backup_file "$backup" "$ENV_FILE" env
  backup_file "$backup" "$QDISC_HELPER" helper
  backup_file "$backup" "$SERVICE_FILE" service
  if have systemctl; then
    service_enabled="$(systemctl is-enabled bbr-tcp-tuning.service 2>/dev/null || true)"
    service_active="$(systemctl is-active bbr-tcp-tuning.service 2>/dev/null || true)"
  fi
  cat >"${backup}/meta.env" <<EOF_META
IFACE=$(printf '%q' "$iface")
ROOT_QDISC=$(printf '%q' "$(root_qdisc_kind "$iface")")
SERVICE_ENABLED=$(printf '%q' "$service_enabled")
SERVICE_ACTIVE=$(printf '%q' "$service_active")
EOF_META
  tc -s -d qdisc show dev "$iface" >"${backup}/qdisc.txt" 2>&1 || true
  : >"${backup}/sysctl.tsv"
  for key in net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_sack \
    net.ipv4.tcp_dsack net.ipv4.tcp_window_scaling; do
    value="$(sysctl_get "$key")"
    [[ -n "$value" ]] && printf '%s\t%s\n' "$key" "$value" >>"${backup}/sysctl.tsv"
  done
  ln -sfn "$backup" "$LATEST_BACKUP"
  printf '%s\n' "$backup"
}

restore_files() {
  local backup="$1" tag state path
  while IFS=$'\t' read -r tag state path; do
    [[ -n "$tag" && -n "$path" ]] || continue
    if [[ "$state" == "present" ]]; then
      rm -f "$path"
      cp -a "${backup}/${tag}.file" "$path"
    else
      rm -f "$path"
    fi
  done <"${backup}/files.tsv"
}

restore_qdisc() {
  local backup="$1" iface="$2" kind="$3" parent leaf
  tc qdisc del dev "$iface" root 2>/dev/null || true
  case "$kind" in
    ""|noqueue|pfifo_fast) ;;
    mq)
      tc qdisc replace dev "$iface" root mq 2>/dev/null || return 0
      while read -r leaf parent; do
        case "$leaf" in fq|fq_codel|pfifo_fast|sfq) tc qdisc replace dev "$iface" parent "$parent" "$leaf" 2>/dev/null || true ;; esac
      done < <(awk '{kind=$2; parent=""; for(i=1;i<=NF;i++) if($i=="parent")parent=$(i+1); if(parent~/^:/)print kind,parent}' "${backup}/qdisc.txt")
      ;;
    fq|fq_codel|sfq) tc qdisc replace dev "$iface" root "$kind" 2>/dev/null || true ;;
    *) warn "原 qdisc ${kind} 无法完整自动重建，请参考 ${backup}/qdisc.txt" ;;
  esac
}

restore_backup() {
  local backup="$1" iface="" kind="" key value
  local IFACE="" ROOT_QDISC="" ROOT_QDISC_KIND="" SERVICE_ENABLED="unknown" SERVICE_ACTIVE="unknown"
  # shellcheck disable=SC1090
  source "${backup}/meta.env"
  iface="$IFACE"; kind="${ROOT_QDISC:-$ROOT_QDISC_KIND}"
  if have systemctl; then systemctl disable --now bbr-tcp-tuning.service >/dev/null 2>&1 || true; fi
  restore_files "$backup"
  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] && sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
  done <"${backup}/sysctl.tsv"
  restore_qdisc "$backup" "$iface" "$kind"
  if have systemctl; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "$SERVICE_FILE" ]]; then
      if [[ "$SERVICE_ENABLED" == "enabled" ]]; then
        systemctl enable bbr-tcp-tuning.service >/dev/null 2>&1 || true
      else
        systemctl disable bbr-tcp-tuning.service >/dev/null 2>&1 || true
      fi
      if [[ "$SERVICE_ACTIVE" == "active" ]]; then
        systemctl start bbr-tcp-tuning.service >/dev/null 2>&1 || true
      fi
    fi
  fi
  return 0
}

pending_path() { printf '%s/%s\n' "$PENDING_DIR" "$(basename "$1")"; }

schedule_rollback() {
  local backup="$1" pending unit pid
  (( AUTO_ROLLBACK_SECONDS > 0 )) || return 0
  pending="$(pending_path "$backup")"
  mkdir -p "$pending"
  printf '%s\n' "$backup" >"${pending}/backup"
  : >"${pending}/armed"
  if have systemd-run && have systemctl && systemctl is-system-running >/dev/null 2>&1; then
    unit="bbr-tcp-rollback-$(date +%s)-$$"
    systemd-run --quiet --unit "$unit" --on-active="${AUTO_ROLLBACK_SECONDS}s" \
      /usr/bin/env BBR_AUTO_ROLLBACK=1 /bin/bash "$SCRIPT_PATH" rollback --backup "$backup" --yes
    printf 'TYPE=systemd\nID=%q\n' "$unit" >"${pending}/timer.env"
  else
    nohup /bin/bash -c '
      sleep "$1"; [[ -f "$2" ]] || exit 0
      BBR_AUTO_ROLLBACK=1 /bin/bash "$3" rollback --backup "$4" --yes >>"$5" 2>&1
    ' _ "$AUTO_ROLLBACK_SECONDS" "${pending}/armed" "$SCRIPT_PATH" "$backup" "${pending}/rollback.log" >/dev/null 2>&1 &
    pid=$!
    printf 'TYPE=process\nID=%q\n' "$pid" >"${pending}/timer.env"
  fi
  ln -sfn "$pending" "$PENDING_LATEST"
  warn "已启用 ${AUTO_ROLLBACK_SECONDS} 秒安全回滚；确认服务器正常后执行 sudo $PROGRAM confirm"
}

cancel_rollback_for_backup() {
  local backup="$1" pending type="" id="" recorded real
  pending="$(pending_path "$backup")"
  [[ -d "$pending" ]] || return 0
  if [[ -r "${pending}/timer.env" ]]; then
    local TYPE="" ID=""
    # shellcheck disable=SC1090
    source "${pending}/timer.env"
    type="$TYPE"; id="$ID"
  fi
  rm -f "${pending}/armed"
  if [[ "${BBR_AUTO_ROLLBACK:-0}" != "1" ]]; then
    case "$type" in
      systemd) systemctl stop "${id}.timer" "${id}.service" >/dev/null 2>&1 || true ;;
      process)
        if [[ "$id" =~ ^[0-9]+$ ]]; then
          kill "$id" 2>/dev/null || true
          wait "$id" 2>/dev/null || true
        fi
        ;;
    esac
  fi
  recorded="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  real="$(readlink -f "$pending" 2>/dev/null || printf '%s' "$pending")"
  rm -rf "$pending"
  if [[ "$recorded" == "$real" ]]; then rm -f "$PENDING_LATEST"; fi
  return 0
}

pending_guard() {
  local pending
  pending="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  [[ -z "$pending" || ! -f "${pending}/armed" ]] || die "存在尚未确认的调优，请先执行 confirm 或 rollback"
}

confirm_tuning() {
  require_linux; require_root
  local pending backup
  pending="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  if [[ -z "$pending" || ! -d "$pending" ]]; then
    info "当前没有待确认的参数"
    return
  fi
  backup="$(cat "${pending}/backup")"
  cancel_rollback_for_backup "$backup"
  info "已确认保留当前参数，安全回滚已取消"
}

rollback_command() {
  require_linux; require_root
  local backup="$BACKUP_PATH"
  [[ -n "$backup" ]] || backup="$(readlink -f "$LATEST_BACKUP" 2>/dev/null || true)"
  [[ -n "$backup" && -d "$backup" ]] || die "未找到可用备份"
  if (( ! YES )) && [[ -t 0 ]]; then
    local answer
    read -r -p "确认恢复 ${backup}？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0
  elif (( ! YES )); then
    die "非交互回滚需要 --yes"
  fi
  cancel_rollback_for_backup "$backup"
  restore_backup "$backup"
  info "服务器 TCP/BBR 参数已恢复：$backup"
}

capture_state() {
  local iface="$1" file="$2"
  {
    printf 'time=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'interface=%s\n' "$iface"
    printf 'memory_total_mib=%s\n' "$MEM_TOTAL_MIB"
    printf 'memory_available_mib=%s\n' "$MEM_AVAILABLE_MIB"
    printf 'memory_effective_mib=%s\n' "$MEM_EFFECTIVE_MIB"
    printf 'memory_buffer_cap_mib=%s\n' "$MEM_BUFFER_CAP_MIB"
    for key in net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control net.core.default_qdisc \
      net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
      net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_sack net.ipv4.tcp_dsack net.ipv4.tcp_window_scaling; do
      printf '%s=%s\n' "$key" "$(sysctl_get "$key")"
    done
    printf '\n[qdisc]\n'
    tc -s -d qdisc show dev "$iface" 2>&1 || true
    if have nstat; then
      printf '\n[tcp-counters]\n'
      nstat -az 2>/dev/null | awk '/TcpRetransSegs|TcpExtTCPTimeouts|TcpExtTCPLoss|TcpExtTCPSackRecovery|TcpExtTCPDSACKRecv/{print}' || true
    fi
  } >"$file"
}

init_session() {
  SESSION_ID="$(date +%Y%m%d-%H%M%S)-$$"
  SESSION_DIR="${SESSION_ROOT}/${SESSION_ID}"
  mkdir -p "$SESSION_DIR"
  RUN_LOG="${SESSION_DIR}/run.log"
  REPORT_FILE="${SESSION_DIR}/results.tsv"
  COMPARISON_FILE="${SESSION_DIR}/comparison.txt"
  : >"$RUN_LOG"
  exec > >(tee -a "$RUN_LOG") 2>&1
  printf 'stage\tconfig\tstreams\tbuffer_mib\tfactor\tmbps\tretrans\tretrans_percent\tscore\tpassed\n' >"$REPORT_FILE"
}

parse_iperf_json() {
  local file="$1" values bps bytes retrans
  if have python3; then
    values="$(python3 - "$file" <<'PY_JSON'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data=json.load(fh)
sent=data["end"]["sum_sent"]
print(f'{sent.get("bits_per_second",0)}\t{sent.get("bytes",0)}\t{sent.get("retransmits",0)}')
PY_JSON
)" || return 1
  else
    values="$(awk '
      /"sum_sent"[[:space:]]*:/ {inside=1; next}
      inside && /"bits_per_second"[[:space:]]*:/ {v=$0; sub(/^.*:[[:space:]]*/,"",v); sub(/,.*/,"",v); bps=v}
      inside && /"bytes"[[:space:]]*:/ {v=$0; sub(/^.*:[[:space:]]*/,"",v); sub(/,.*/,"",v); bytes=v}
      inside && /"retransmits"[[:space:]]*:/ {v=$0; sub(/^.*:[[:space:]]*/,"",v); sub(/,.*/,"",v); retrans=v}
      inside && /^[[:space:]]*}/ {if(bps!=""){if(bytes=="")bytes=0;if(retrans=="")retrans=0;print bps"\t"bytes"\t"retrans;exit}}
    ' "$file")"
  fi
  [[ -n "$values" ]] || return 1
  IFS=$'\t' read -r bps bytes retrans <<<"$values"
  is_number "$bps" && is_number "$bytes" && is_number "$retrans" || return 1
  RESULT_MBPS="$(awk -v v="$bps" 'BEGIN {printf "%.2f",v/1000000}')"
  RESULT_BYTES="$(awk -v v="$bytes" 'BEGIN {printf "%.0f",v}')"
  RESULT_RETRANS="$(awk -v v="$retrans" 'BEGIN {printf "%.0f",v}')"
  RESULT_RETRANS_PERCENT="$(awk -v r="$RESULT_RETRANS" -v b="$RESULT_BYTES" 'BEGIN {if(b<=0)print "100.0000";else printf "%.4f",r*1448/b*100}')"
}

print_interval_log() {
  local file="$1"
  have python3 || return 0
  python3 - "$file" <<'PY_INTERVALS' || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data=json.load(fh)
    rows=[]
    for item in data.get("intervals", []):
        total=item.get("sum")
        if not total:
            streams=item.get("streams", [])
            total={
                "start": min((x.get("start",0) for x in streams), default=0),
                "end": max((x.get("end",0) for x in streams), default=0),
                "bits_per_second": sum(x.get("bits_per_second",0) for x in streams),
                "retransmits": sum(x.get("retransmits",0) for x in streams),
            }
        rows.append((total.get("start",0),total.get("end",0),total.get("bits_per_second",0)/1e6,total.get("retransmits",0)))
    if rows:
        print("[TEST ] 区间日志：")
        for start,end,mbps,retr in rows:
            print(f"[TEST ] {start:5.1f}-{end:5.1f}s  {mbps:9.2f} Mbps  Retr={retr}")
except Exception:
    pass
PY_INTERVALS
}

calculate_result_quality() {
  local min_mbps
  min_mbps="$(awk -v bw="$TARGET_MBPS" -v p="$TARGET_UTILIZATION" 'BEGIN {printf "%.4f",bw*p/100}')"
  RESULT_PASS="$(awk -v s="$RESULT_MBPS" -v min="$min_mbps" -v r="$RESULT_RETRANS_PERCENT" -v maxr="$MAX_RETRANS_PERCENT" \
    'BEGIN {print (s>=min && r<=maxr)?"yes":"no"}')"
  RESULT_SCORE="$(awk -v s="$RESULT_MBPS" -v min="$min_mbps" -v r="$RESULT_RETRANS_PERCENT" -v maxr="$MAX_RETRANS_PERCENT" \
    'BEGIN {speed=(min>0?s/min*100:0); if(speed>130)speed=130; penalty=(r>maxr?(r-maxr)*25:0); bonus=(s>=min && r<=maxr?1000:0); printf "%.4f",bonus+speed-penalty}')"
}

result_better_than() {
  local candidate="$1" current="$2"
  awk -v a="$candidate" -v b="$current" 'BEGIN {exit !(a>b+0.0001)}'
}

result_low_speed_low_retrans() {
  local min_mbps
  min_mbps="$(awk -v bw="$TARGET_MBPS" -v p="$TARGET_UTILIZATION" 'BEGIN {print bw*p/100}')"
  awk -v s="$RESULT_MBPS" -v min="$min_mbps" -v r="$RESULT_RETRANS_PERCENT" -v maxr="$MAX_RETRANS_PERCENT" \
    'BEGIN {exit !(s<min && r<=maxr)}'
}

next_stream_count() {
  if (( $1 < 8 )); then printf '8\n'; elif (( $1 < 16 )); then printf '16\n'; else printf '%s\n' "$1"; fi
}

run_reverse_test() {
  local label="$1" streams="$2" address="$3" json_file err_file elapsed=0 limit rc
  json_file="${SESSION_DIR}/${label}.json"
  err_file="${SESSION_DIR}/${label}.err"
  port_is_free "$TEST_PORT" || die "测试端口 ${TEST_PORT} 已被占用"
  : >"$json_file"; : >"$err_file"
  iperf3 -s -1 -J -p "$TEST_PORT" >"$json_file" 2>"$err_file" &
  CURRENT_TEST_PID=$!
  sleep 1
  kill -0 "$CURRENT_TEST_PID" 2>/dev/null || { cat "$err_file" >&2; die "iperf3 服务端启动失败"; }

  section "测试 ${label}｜${streams} 流｜端口 ${TEST_PORT}"
  printf '请在本地电脑执行：\n\n  iperf3 -c %s -p %s -R -P %s -t %s -i 1\n\n' \
    "$address" "$TEST_PORT" "$streams" "$DURATION"
  printf '服务器只接收测试结果，不会修改本地电脑。\n'
  limit=$(( WAIT_SECONDS + DURATION + 10 ))
  while kill -0 "$CURRENT_TEST_PID" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed+1))
    if (( elapsed % 5 == 0 )); then
      printf '[TEST ] 已运行/等待 %3ss，服务端 PID=%s，端口=%s\n' "$elapsed" "$CURRENT_TEST_PID" "$TEST_PORT"
    fi
    if (( elapsed >= limit )); then
      kill "$CURRENT_TEST_PID" 2>/dev/null || true
      wait "$CURRENT_TEST_PID" 2>/dev/null || true
      CURRENT_TEST_PID=""
      die "本轮测试超时"
    fi
  done
  set +e
  wait "$CURRENT_TEST_PID"; rc=$?
  set -e
  CURRENT_TEST_PID=""
  (( rc == 0 )) || { cat "$err_file" >&2 || true; die "iperf3 测试失败，退出码 ${rc}"; }
  parse_iperf_json "$json_file" || { cat "$json_file" >&2 || true; die "无法解析 iperf3 测试结果"; }
  calculate_result_quality
  print_interval_log "$json_file"
  printf '[RESULT] %.2f Mbps｜Retr=%s｜估算重传=%s%%｜score=%s｜达标=%s\n' \
    "$RESULT_MBPS" "$RESULT_RETRANS" "$RESULT_RETRANS_PERCENT" "$RESULT_SCORE" "$RESULT_PASS"
}

record_result() {
  local stage="$1" config="$2" streams="$3" buffer_mib="$4" factor="$5"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$stage" "$config" "$streams" "$buffer_mib" "$factor" "$RESULT_MBPS" "$RESULT_RETRANS" \
    "$RESULT_RETRANS_PERCENT" "$RESULT_SCORE" "$RESULT_PASS" >>"$REPORT_FILE"
}

abort_without_changes() {
  trap - INT TERM
  set +e
  [[ -n "$CURRENT_TEST_PID" ]] && kill "$CURRENT_TEST_PID" 2>/dev/null || true
  warn "测试已中断；尚未修改服务器 TCP 参数"
  exit 130
}

cleanup_tuning_on_exit() {
  local rc=$?
  trap - EXIT ERR INT TERM
  if (( rc != 0 )) && [[ "$TUNING_ACTIVE" == "1" && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    set +e
    [[ -n "$CURRENT_TEST_PID" ]] && kill "$CURRENT_TEST_PID" 2>/dev/null || true
    warn "调优异常退出，正在恢复调优前参数"
    cancel_rollback_for_backup "$BACKUP_DIR"
    restore_backup "$BACKUP_DIR"
    TUNING_ACTIVE="0"
  fi
  exit "$rc"
}

stop_tuning_on_signal() {
  trap - INT TERM
  set +e
  [[ -n "$CURRENT_TEST_PID" ]] && kill "$CURRENT_TEST_PID" 2>/dev/null || true
  warn "收到中断信号，准备恢复调优前参数"
  exit 130
}

write_comparison() {
  local iface="$1" final_buffer="$2" delta delta_retrans after_cc after_qdisc after_rmem after_wmem
  delta="$(awk -v a="$BASELINE_MBPS" -v b="$FINAL_MBPS" 'BEGIN {if(a<=0)print "0.00";else printf "%.2f",(b-a)/a*100}')"
  delta_retrans="$(awk -v a="$BASELINE_RETRANS_PERCENT" -v b="$FINAL_RETRANS_PERCENT" 'BEGIN {printf "%.4f",b-a}')"
  after_cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
  after_qdisc="$(root_qdisc_kind "$iface")"
  after_rmem="$(sysctl_get net.ipv4.tcp_rmem)"
  after_wmem="$(sysctl_get net.ipv4.tcp_wmem)"
  cat >"$COMPARISON_FILE" <<EOF_COMPARE
TCP/BBR 调优详细对比
====================
会话：${SESSION_ID}
时间：$(date '+%Y-%m-%dT%H:%M:%S%z')
服务器：${SERVER_ADDRESS}
出口网卡：${iface}
目标：${TARGET_MBPS} Mbps × ${TARGET_UTILIZATION}%
RTT：${RTT_MS} ms
测试并发：${BASELINE_STREAMS}

服务器内存与缓存预算
--------------------
物理内存：${MEM_TOTAL_MIB} MiB
可用内存：${MEM_AVAILABLE_MIB} MiB
有效内存上限：${MEM_EFFECTIVE_MIB} MiB
自动 TCP 单连接缓存上限：${MEM_BUFFER_CAP_MIB} MiB
BDP：${BDP_MIB} MiB

调优前
------
拥塞算法：${BEFORE_CC}
root qdisc：${BEFORE_QDISC}
tcp_rmem：${BEFORE_RMEM}
tcp_wmem：${BEFORE_WMEM}
全局缓存上限：${BEFORE_BUFFER_BYTES} bytes
吞吐：${BASELINE_MBPS} Mbps
Retr：${BASELINE_RETRANS}
估算重传比例：${BASELINE_RETRANS_PERCENT}%
达标：${BASELINE_PASS}

调优后
------
结果：${OUTCOME}
拥塞算法：${after_cc}
root qdisc：${after_qdisc}
tcp_rmem：${after_rmem}
tcp_wmem：${after_wmem}
最终缓存上限：${final_buffer} bytes
吞吐：${FINAL_MBPS} Mbps
Retr：${FINAL_RETRANS}
估算重传比例：${FINAL_RETRANS_PERCENT}%
达标：${FINAL_PASS}

变化
----
吞吐变化：${delta}%
重传比例变化：${delta_retrans} 个百分点
最优候选：${BEST_KIND}
最优 BDP 系数：${BEST_FACTOR}
单流 QoS 特征：$([[ "$QOS_DETECTED" == "1" ]] && echo yes || echo no)

文件
----
运行日志：${RUN_LOG}
逐轮数据：${REPORT_FILE}
调优前状态：${SESSION_DIR}/system-before.txt
调优后状态：${SESSION_DIR}/system-after.txt
EOF_COMPARE
  cat "$COMPARISON_FILE"
}

append_history() {
  local delta
  mkdir -p "$STATE_DIR"
  if [[ ! -e "$HISTORY_FILE" ]]; then
    printf 'time\tsession\ttarget_mbps\trtt_ms\tstreams\tbefore_mbps\tafter_mbps\tdelta_percent\tbefore_retrans_percent\tafter_retrans_percent\tbuffer_cap_mib\toutcome\treport\n' >"$HISTORY_FILE"
  fi
  delta="$(awk -v a="$BASELINE_MBPS" -v b="$FINAL_MBPS" 'BEGIN {if(a<=0)print "0.00";else printf "%.2f",(b-a)/a*100}')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "$TARGET_MBPS" "$RTT_MS" "$BASELINE_STREAMS" "$BASELINE_MBPS" "$FINAL_MBPS" "$delta" \
    "$BASELINE_RETRANS_PERCENT" "$FINAL_RETRANS_PERCENT" "$MEM_BUFFER_CAP_MIB" "$OUTCOME" "$COMPARISON_FILE" >>"$HISTORY_FILE"
}

autotune() {
  require_linux; require_root; validate_autotune_options
  for cmd in ip tc sysctl modprobe awk mktemp ss tee; do have "$cmd" || die "服务器缺少命令：$cmd"; done
  pending_guard
  init_session
  install_iperf3_if_needed

  local iface address root_kind next_stream first_speed candidate_count=0 index mib factor no_improve=0 previous_best
  iface="$(resolve_iface)"
  [[ -n "$iface" ]] || die "无法识别出口网卡"
  ip link show dev "$iface" >/dev/null 2>&1 || die "出口网卡不存在：$iface"
  address="$(guess_server_address)"
  [[ -n "$address" ]] || die "无法识别服务器连接地址，请使用 --server-address"
  SERVER_ADDRESS="$address"
  TEST_PORT="$(choose_random_port)" || die "无法找到未占用的随机端口"

  detect_memory_limits
  calculate_bdp
  generate_candidates
  ensure_bbr

  BEFORE_CC="$(sysctl_get net.ipv4.tcp_congestion_control)"
  BEFORE_QDISC="$(root_qdisc_kind "$iface")"
  BEFORE_RMEM="$(sysctl_get net.ipv4.tcp_rmem)"
  BEFORE_WMEM="$(sysctl_get net.ipv4.tcp_wmem)"
  BEFORE_BUFFER_BYTES="$(current_buffer_max)"
  BASELINE_BUFFER_BYTES="$BEFORE_BUFFER_BYTES"
  root_kind="$BEFORE_QDISC"
  if ! qdisc_safe "$root_kind" && (( ! FORCE )); then
    die "检测到自定义 root qdisc '${root_kind}'；为避免破坏现有 QoS，需审计后使用 --force"
  fi
  capture_state "$iface" "${SESSION_DIR}/system-before.txt"

  section "自动寻优会话 ${SESSION_ID}"
  printf '服务器：%s\n出口网卡：%s\n随机端口：%s\n目标带宽：%s Mbps\nRTT：%s ms\n' \
    "$address" "$iface" "$TEST_PORT" "$TARGET_MBPS" "$RTT_MS"
  printf '内存：总计 %s MiB，可用 %s MiB，TCP 缓存自动上限 %s MiB\n' \
    "$MEM_TOTAL_MIB" "$MEM_AVAILABLE_MIB" "$MEM_BUFFER_CAP_MIB"
  printf 'BDP：%s MiB；候选缓存：' "$BDP_MIB"
  printf '%sMiB ' "${CANDIDATE_MIBS[@]}"
  printf '\n日志目录：%s\n' "$SESSION_DIR"
  warn "脚本不会修改本地电脑，也不会自动开放服务器防火墙；请允许 TCP ${TEST_PORT}"

  trap abort_without_changes INT TERM
  TEST_STREAMS="$START_STREAMS"
  run_reverse_test "before-p${TEST_STREAMS}" "$TEST_STREAMS" "$address"
  record_result before original "$TEST_STREAMS" "$(awk -v b="$BEFORE_BUFFER_BYTES" 'BEGIN {printf "%.2f",b/1048576}')" original
  INITIAL_SINGLE_MBPS="$RESULT_MBPS"
  first_speed="$RESULT_MBPS"

  while result_low_speed_low_retrans; do
    next_stream="$(next_stream_count "$TEST_STREAMS")"
    [[ "$next_stream" != "$TEST_STREAMS" ]] || break
    TEST_STREAMS="$next_stream"
    info "低重传但吞吐不足，增加到 ${TEST_STREAMS} 个并发流以识别单流 QoS"
    run_reverse_test "before-p${TEST_STREAMS}" "$TEST_STREAMS" "$address"
    record_result before original "$TEST_STREAMS" "$(awk -v b="$BEFORE_BUFFER_BYTES" 'BEGIN {printf "%.2f",b/1048576}')" original
  done

  BASELINE_STREAMS="$TEST_STREAMS"
  BASELINE_MBPS="$RESULT_MBPS"
  BASELINE_RETRANS="$RESULT_RETRANS"
  BASELINE_RETRANS_PERCENT="$RESULT_RETRANS_PERCENT"
  BASELINE_SCORE="$RESULT_SCORE"
  BASELINE_PASS="$RESULT_PASS"
  BEST_MBPS="$BASELINE_MBPS"
  BEST_RETRANS="$BASELINE_RETRANS"
  BEST_RETRANS_PERCENT="$BASELINE_RETRANS_PERCENT"
  BEST_SCORE="$BASELINE_SCORE"
  BEST_PASS="$BASELINE_PASS"

  if (( BASELINE_STREAMS > START_STREAMS )); then
    local gain
    gain="$(awk -v a="$first_speed" -v b="$BASELINE_MBPS" 'BEGIN {if(a<=0)print 0;else printf "%.2f",(b-a)/a*100}')"
    if awk -v g="$gain" 'BEGIN {exit !(g>=15)}'; then QOS_DETECTED="1"; fi
    info "并发诊断：${START_STREAMS} 流 ${first_speed} Mbps → ${BASELINE_STREAMS} 流 ${BASELINE_MBPS} Mbps，变化 ${gain}%"
  fi

  trap - INT TERM
  BACKUP_DIR="$(create_backup "$iface")"
  TUNING_ACTIVE="1"
  trap cleanup_tuning_on_exit EXIT
  trap stop_tuning_on_signal INT TERM
  schedule_rollback "$BACKUP_DIR"

  section "测试内存感知的 TCP 候选参数"
  for ((index=0; index<${#CANDIDATE_MIBS[@]}; index++)); do
    mib="${CANDIDATE_MIBS[$index]}"
    factor="${CANDIDATE_FACTORS[$index]}"
    candidate_count=$((candidate_count+1))
    info "候选 ${candidate_count}/${#CANDIDATE_MIBS[@]}：BBR + fq，buffer=${mib} MiB，BDP 系数=${factor}"
    apply_candidate "$iface" "$mib"
    run_reverse_test "candidate-${candidate_count}-${mib}m" "$BASELINE_STREAMS" "$address"
    record_result candidate bbr-fq "$BASELINE_STREAMS" "$mib" "$factor"
    previous_best="$BEST_SCORE"
    if result_better_than "$RESULT_SCORE" "$BEST_SCORE"; then
      BEST_KIND="candidate-${candidate_count}"
      BEST_BUFFER_MIB="$mib"
      BEST_FACTOR="$factor"
      BEST_MBPS="$RESULT_MBPS"
      BEST_RETRANS="$RESULT_RETRANS"
      BEST_RETRANS_PERCENT="$RESULT_RETRANS_PERCENT"
      BEST_SCORE="$RESULT_SCORE"
      BEST_PASS="$RESULT_PASS"
      no_improve=0
      info "当前最优更新：${BEST_MBPS} Mbps，重传 ${BEST_RETRANS_PERCENT}%"
    else
      no_improve=$((no_improve+1))
      info "该候选未超过当前最优 score=${previous_best}"
    fi
    if (( candidate_count >= 2 && no_improve >= 2 )); then
      info "连续两个更大缓存未带来改善，判定已进入性能平台，停止继续放大缓存"
      break
    fi
  done

  if [[ "$BEST_KIND" == "baseline" ]]; then
    info "所有候选均未超过调优前配置，恢复并保留原参数"
    cancel_rollback_for_backup "$BACKUP_DIR"
    restore_backup "$BACKUP_DIR"
    TUNING_ACTIVE="0"
    OUTCOME="baseline-retained"
    FINAL_MBPS="$BASELINE_MBPS"
    FINAL_RETRANS="$BASELINE_RETRANS"
    FINAL_RETRANS_PERCENT="$BASELINE_RETRANS_PERCENT"
    FINAL_SCORE="$BASELINE_SCORE"
    FINAL_PASS="$BASELINE_PASS"
    FINAL_BUFFER_BYTES="$BASELINE_BUFFER_BYTES"
    trap - INT TERM
  else
    section "复测最优候选 ${BEST_KIND}"
    apply_candidate "$iface" "$BEST_BUFFER_MIB"
    run_reverse_test "final-${BEST_BUFFER_MIB}m" "$BASELINE_STREAMS" "$address"
    record_result final bbr-fq "$BASELINE_STREAMS" "$BEST_BUFFER_MIB" "$BEST_FACTOR"
    FINAL_MBPS="$RESULT_MBPS"
    FINAL_RETRANS="$RESULT_RETRANS"
    FINAL_RETRANS_PERCENT="$RESULT_RETRANS_PERCENT"
    FINAL_SCORE="$RESULT_SCORE"
    FINAL_PASS="$RESULT_PASS"
    FINAL_BUFFER_BYTES=$(( BEST_BUFFER_MIB * 1048576 ))

    if awk -v f="$FINAL_SCORE" -v b="$BASELINE_SCORE" 'BEGIN {exit !(f<b-1)}'; then
      warn "最优候选复测结果低于调优前基线，恢复原参数"
      cancel_rollback_for_backup "$BACKUP_DIR"
      restore_backup "$BACKUP_DIR"
      TUNING_ACTIVE="0"
      OUTCOME="baseline-restored-after-confirmation"
      FINAL_MBPS="$BASELINE_MBPS"
      FINAL_RETRANS="$BASELINE_RETRANS"
      FINAL_RETRANS_PERCENT="$BASELINE_RETRANS_PERCENT"
      FINAL_SCORE="$BASELINE_SCORE"
      FINAL_PASS="$BASELINE_PASS"
      FINAL_BUFFER_BYTES="$BASELINE_BUFFER_BYTES"
      trap - INT TERM
    else
      OUTCOME="optimized-runtime"
      if (( PERSIST_FINAL )); then
        info "复测通过，写入持久化配置"
        write_persistent_config "$iface" "$BEST_BUFFER_MIB"
        OUTCOME="optimized-persistent"
      fi
      trap - INT TERM
      if (( AUTO_ROLLBACK_SECONDS > 0 )); then
        warn "最优参数已保留；请另开 SSH 验证后执行 sudo $PROGRAM confirm"
      else
        warn "最优参数已保留，但本次关闭了安全回滚"
      fi
    fi
  fi

  capture_state "$iface" "${SESSION_DIR}/system-after.txt"
  write_comparison "$iface" "$FINAL_BUFFER_BYTES"
  append_history
  TUNING_ACTIVE="0"
  trap - EXIT
  if [[ "$FINAL_PASS" != "yes" ]]; then
    warn "最优结果仍未达到设定目标，但已经选择实测分数最高且复测稳定的配置"
  fi
  if (( QOS_DETECTED )); then
    warn "检测到单流 QoS 特征；业务传输建议使用 8~16 个并发连接"
  fi
  info "完整日志：$RUN_LOG"
  info "详细对比：$COMPARISON_FILE"
}

status_command() {
  require_linux
  for cmd in ip tc sysctl awk; do have "$cmd" || die "缺少命令：$cmd"; done
  local iface
  iface="$(resolve_iface)"
  section "当前服务器 TCP/BBR 状态"
  printf '时间：%s\n内核：%s\n出口网卡：%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(uname -srmo)" "$iface"
  printf '拥塞算法：%s\n' "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '可用算法：%s\n' "$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  printf '默认 qdisc：%s\n' "$(sysctl_get net.core.default_qdisc)"
  printf 'root qdisc：%s\n' "$(root_qdisc_kind "$iface")"
  printf 'tcp_rmem：%s\n' "$(sysctl_get net.ipv4.tcp_rmem)"
  printf 'tcp_wmem：%s\n' "$(sysctl_get net.ipv4.tcp_wmem)"
  printf 'rmem_max：%s\nwmem_max：%s\n' "$(sysctl_get net.core.rmem_max)" "$(sysctl_get net.core.wmem_max)"
  tc -s -d qdisc show dev "$iface" || true
}

history_command() {
  if [[ ! -r "$HISTORY_FILE" ]]; then
    info "尚无历史测试记录"
    return
  fi
  section "TCP/BBR 历史测试"
  if have column; then column -t -s $'\t' "$HISTORY_FILE"; else cat "$HISTORY_FILE"; fi
  printf '\n每个会话的完整日志位于：%s\n' "$SESSION_ROOT"
}

ui_init() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    UI_BLUE=$'\033[1;36m'; UI_GREEN=$'\033[1;32m'; UI_YELLOW=$'\033[1;33m'; UI_RED=$'\033[1;31m'; UI_RESET=$'\033[0m'
  else
    UI_BLUE=""; UI_GREEN=""; UI_YELLOW=""; UI_RED=""; UI_RESET=""
  fi
}

ui_title() {
  clear 2>/dev/null || true
  printf '%s╔══════════════════════════════════════════════════════════════╗%s\n' "$UI_BLUE" "$UI_RESET"
  printf '%s║        远程服务器 TCP / BBR 自动寻优工具 v%-10s       ║%s\n' "$UI_BLUE" "$VERSION" "$UI_RESET"
  printf '%s╚══════════════════════════════════════════════════════════════╝%s\n\n' "$UI_BLUE" "$UI_RESET"
}

ui_read_text() {
  local label="$1" default="$2" value
  if [[ -n "$default" ]]; then read -r -p "${label} [${default}]：" value || return 1; else read -r -p "${label}：" value || return 1; fi
  printf '%s\n' "${value:-$default}"
}

ui_read_number() {
  local label="$1" default="$2" min="$3" max="$4" value
  while true; do
    value="$(ui_read_text "$label" "$default")" || return 1
    if is_number "$value" && awk -v v="$value" -v lo="$min" -v hi="$max" 'BEGIN {exit !(v>=lo && v<=hi)}'; then
      printf '%s\n' "$value"; return 0
    fi
    printf '%s请输入 %s～%s 的数字%s\n' "$UI_RED" "$min" "$max" "$UI_RESET" >&2
  done
}

ui_yes_no() {
  local label="$1" default="$2" answer suffix
  [[ "$default" == "y" ]] && suffix="[Y/n]" || suffix="[y/N]"
  while true; do
    read -r -p "${label} ${suffix}：" answer || return 1
    answer="${answer:-$default}"
    case "$answer" in y|Y|yes|YES) return 0 ;; n|N|no|NO) return 1 ;; esac
  done
}

ui_execute() {
  local need_root="$1"; shift
  local cmd=(bash "$SCRIPT_PATH" "$@") rc
  printf '\n%s执行：%s' "$UI_BLUE" "$UI_RESET"
  printf ' %q' "${cmd[@]}"
  printf '\n\n'
  if [[ "$need_root" == "1" && $EUID -ne 0 ]]; then
    have sudo || { printf '%s需要 root，但未安装 sudo%s\n' "$UI_RED" "$UI_RESET"; return 1; }
    if sudo "${cmd[@]}"; then rc=0; else rc=$?; fi
  else
    if "${cmd[@]}"; then rc=0; else rc=$?; fi
  fi
  if (( rc == 0 )); then
    printf '\n%s✓ 操作完成%s\n' "$UI_GREEN" "$UI_RESET"
  else
    printf '\n%s✗ 操作失败，退出码 %s%s\n' "$UI_RED" "$rc" "$UI_RESET"
  fi
  return "$rc"
}

ui_autotune() {
  local address bandwidth rtt streams duration candidates util retrans wait rollback
  local args=()
  address="$(guess_server_address 2>/dev/null || true)"
  bandwidth="$(ui_read_number "目标带宽 Mbps" "1000" "1" "100000")" || return
  rtt="$(ui_read_number "本地到服务器 RTT ms" "100" "0.1" "5000")" || return
  address="$(ui_read_text "服务器公网 IP 或域名" "$address")" || return
  [[ -n "$address" ]] || { printf '%s服务器地址不能为空%s\n' "$UI_RED" "$UI_RESET"; return; }
  streams="$(ui_read_number "起始并发流" "1" "1" "64")" || return
  duration="$(ui_read_number "每轮测试秒数" "15" "5" "300")" || return
  candidates="$(ui_read_number "最多测试候选数量" "4" "1" "6")" || return
  util="$(ui_read_number "目标带宽利用率 %" "90" "1" "100")" || return
  retrans="$(ui_read_number "最大估算重传比例 %" "1" "0" "100")" || return
  wait="$(ui_read_number "每轮等待本地连接秒数" "300" "30" "3600")" || return
  rollback="$(ui_read_number "安全回滚秒数" "3600" "300" "86400")" || return
  if ui_yes_no "最优参数通过复测后持久化" "n"; then args+=(--persist); fi
  printf '\n%s说明：%s脚本将在服务器端依次测试候选参数；每轮只需在本地执行屏幕显示的 iperf3 命令。\n' "$UI_YELLOW" "$UI_RESET"
  ui_yes_no "开始自动寻优" "n" || return
  ui_execute 1 autotune --bandwidth-mbps "$bandwidth" --rtt-ms "$rtt" --server-address "$address" \
    --parallel "$streams" --duration "$duration" --max-candidates "$candidates" \
    --target-utilization "$util" --max-retrans-percent "$retrans" --wait-seconds "$wait" \
    --auto-rollback-seconds "$rollback" "${args[@]}"
}

menu() {
  [[ -t 0 && -t 1 ]] || { usage; return; }
  require_linux
  ui_init
  local choice
  while true; do
    ui_title
    printf '  %s1)%s 自动测试并选择最优 TCP 参数\n' "$UI_GREEN" "$UI_RESET"
    printf '  2) 查看当前 TCP / BBR 状态\n'
    printf '  3) 查看历史测试与对比记录\n'
    printf '  4) 确认保留当前参数\n'
    printf '  5) 恢复调优前参数\n'
    printf '  6) 使用说明\n'
    printf '  0) 退出\n\n'
    read -r -p "请选择：" choice || return
    case "$choice" in
      1) ui_autotune || true ;;
      2) ui_execute 0 status --iface "$IFACE" || true ;;
      3) ui_execute 0 history || true ;;
      4) ui_execute 1 confirm || true ;;
      5) ui_execute 1 rollback --yes || true ;;
      6) usage ;;
      0) return ;;
      *) printf '%s无效选择%s\n' "$UI_RED" "$UI_RESET" ;;
    esac
    printf '\n按 Enter 返回主界面...'; read -r _ || true
  done
}

main() {
  parse_args "$@"
  case "$COMMAND" in
    menu) menu ;;
    autotune) autotune ;;
    status) status_command ;;
    history) history_command ;;
    confirm) confirm_tuning ;;
    rollback) rollback_command ;;
    help) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
