#!/usr/bin/env bash
# bbr-tune.sh - 远程 Linux 服务器 TCP/BBR 自动测试与参数寻优工具
set -Eeuo pipefail

VERSION="2.1.1"
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
RTT_SOURCE=""
START_STREAMS="1"
TEST_STREAMS="1"
DURATION="15"
WAIT_SECONDS="300"
TARGET_UTILIZATION="90"
MAX_RETRANS_PERCENT="1"
AUTO_ROLLBACK_SECONDS="3600"
TCP_BUFFER_ABSOLUTE_MAX_MIB="1024"
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
RESULT_RTT_MS="0"
RESULT_RTT_SOURCE=""
RESULT_CLIENT_ADDRESS=""
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
SEARCH_ROUNDS="0"
OVERSHOOT_DETECTED="0"
OVERSHOOT_MIB="0"

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
  printf '\n┌──────────────────────────────────────────────────────────────\n'
  printf '│ %s\n' "$*"
  printf '└──────────────────────────────────────────────────────────────\n'
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
  --bandwidth-mbps N       期望的端到端下载带宽，单位 Mbps，必填
                           方向为“远程服务器 → 本地电脑”；通常填写
                           服务器出站上限与本地下载上限中的较小值
  --server-address HOST    本地 iperf3 应连接的服务器地址
  --iface auto|DEV         出口网卡，默认自动识别
  --parallel N             起始并发流数，默认 1；必要时自动测试 8/16 流
  --duration N             每轮测试时长，默认 15 秒
  --target-utilization N   达标吞吐百分比，默认 90
  --max-retrans-percent N  最大估算重传比例，默认 1
  --persist                最优参数复测后写入开机配置
  --force                  允许覆盖无法完整恢复的自定义 root qdisc

自动测试规则：
  1. 脚本只在远程 Linux 服务器修改 TCP/BBR 参数。
  2. 本地电脑只运行屏幕显示的 iperf3 客户端命令，不改任何本地参数。
  3. 首轮反向 iperf3 会自动测量本地与服务器之间的 TCP RTT，无需填写 RTT。
  4. TCP 缓存预算仅按服务器总内存（含 cgroup 总上限）分档计算，不使用可用内存决定上限。
  5. 候选数量不设人工上限：先持续增大缓存；发现性能越界后回退并二分精调。
  6. 每轮固定等待本地连接 300 秒；修改后固定保留 3600 秒安全回滚窗口。
  7. 所有结果和原始 JSON 长期保存在 /var/lib/bbr-tcp-tuning/sessions。
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
      --server-address) need_value "$@"; SERVER_ADDRESS="$2"; shift 2 ;;
      --iface) need_value "$@"; IFACE="$2"; shift 2 ;;
      --parallel) need_value "$@"; START_STREAMS="$2"; shift 2 ;;
      --duration) need_value "$@"; DURATION="$2"; shift 2 ;;
      --target-utilization) need_value "$@"; TARGET_UTILIZATION="$2"; shift 2 ;;
      --max-retrans-percent) need_value "$@"; MAX_RETRANS_PERCENT="$2"; shift 2 ;;
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
  [[ -n "$TARGET_MBPS" ]] || die "autotune 需要 --bandwidth-mbps"
  is_number "$TARGET_MBPS" || die "目标带宽必须是正数"
  is_integer "$START_STREAMS" || die "并发流数必须是整数"
  is_integer "$DURATION" || die "测试时长必须是整数"
  is_number "$TARGET_UTILIZATION" || die "目标利用率必须是数字"
  is_number "$MAX_RETRANS_PERCENT" || die "重传比例必须是数字"
  awk -v v="$TARGET_MBPS" 'BEGIN {exit !(v>0)}' || die "目标带宽必须大于 0"
  (( START_STREAMS >= 1 && START_STREAMS <= 64 )) || die "并发流数必须在 1~64"
  (( DURATION >= 5 && DURATION <= 300 )) || die "测试时长必须在 5~300 秒"
  awk -v v="$TARGET_UTILIZATION" 'BEGIN {exit !(v>0 && v<=100)}' || die "目标利用率必须在 0~100"
  awk -v v="$MAX_RETRANS_PERCENT" 'BEGIN {exit !(v>=0 && v<=100)}' || die "重传比例必须在 0~100"
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

guess_client_address() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $1}' <<<"$SSH_CONNECTION"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    awk '{print $1}' <<<"$SSH_CLIENT"
  fi
}

measure_ping_rtt() {
  local address="$1" output value
  [[ -n "$address" ]] && have ping || return 1
  output="$(ping -n -c 5 -W 2 "$address" 2>/dev/null)" || return 1
  value="$(awk -F= '/min\/avg\/max|round-trip/ {gsub(/[[:space:]]/,"",$2); split($2,a,"/"); print a[2]; exit}' <<<"$output")"
  is_number "$value" || return 1
  awk -v v="$value" 'BEGIN {printf "%.2f",v}'
}

format_bytes_mib() {
  awk -v b="${1:-0}" 'BEGIN {printf "%d bytes (%.2f MiB)",b,b/1048576}'
}

format_mib() {
  awk -v m="${1:-0}" 'BEGIN {printf "%.2f MiB",m}'
}

format_pass() {
  [[ "$1" == "yes" ]] && printf '是' || printf '否'
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

  calculate_memory_buffer_cap "$MEM_EFFECTIVE_MIB"
}

calculate_memory_buffer_cap() {
  local total_mib="$1" cap
  cap=$(( total_mib / 64 ))
  (( cap < 4 )) && cap=4
  (( cap > TCP_BUFFER_ABSOLUTE_MAX_MIB )) && cap="$TCP_BUFFER_ABSOLUTE_MAX_MIB"
  MEM_BUFFER_CAP_MIB="$(floor_pow2 "$cap")"
  (( MEM_BUFFER_CAP_MIB < 4 )) && MEM_BUFFER_CAP_MIB=4
  return 0
}

calculate_bdp() {
  BDP_BYTES="$(awk -v bw="$TARGET_MBPS" -v rtt="$RTT_MS" 'BEGIN {printf "%.0f", bw*1000000*(rtt/1000)/8}')"
  BDP_MIB="$(awk -v b="$BDP_BYTES" 'BEGIN {printf "%.2f", b/1048576}')"
}

candidate_factor() {
  local mib="$1"
  awk -v bytes="$(( mib * 1048576 ))" -v bdp="$BDP_BYTES" 'BEGIN {if(bdp<=0) print "0.00"; else printf "%.2f",bytes/bdp}'
}

add_candidate() {
  local mib="$1" existing
  for existing in "${CANDIDATE_MIBS[@]:-}"; do
    [[ "$existing" == "$mib" ]] && return 0
  done
  CANDIDATE_MIBS+=("$mib")
  CANDIDATE_FACTORS+=("$(candidate_factor "$mib")")
}

generate_candidates() {
  local need_mib current
  CANDIDATE_MIBS=()
  CANDIDATE_FACTORS=()
  need_mib="$(awk -v b="$BDP_BYTES" 'BEGIN {printf "%.0f", (b+1048575)/1048576}')"
  (( need_mib < 4 )) && need_mib=4
  current="$(ceil_pow2 "$need_mib")"
  (( current > MEM_BUFFER_CAP_MIB )) && current="$MEM_BUFFER_CAP_MIB"
  while true; do
    add_candidate "$current"
    (( current >= MEM_BUFFER_CAP_MIB )) && break
    current=$(( current * 2 ))
    (( current > MEM_BUFFER_CAP_MIB )) && current="$MEM_BUFFER_CAP_MIB"
  done
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

cancel_pending_dir() {
  local pending="$1" type="" id="" recorded real
  if [[ ! -d "$pending" ]]; then
    [[ -L "$PENDING_LATEST" ]] && rm -f "$PENDING_LATEST"
    return 0
  fi
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
  if [[ "$recorded" == "$real" || -L "$PENDING_LATEST" && -z "$recorded" ]]; then
    rm -f "$PENDING_LATEST"
  fi
  return 0
}

cancel_rollback_for_backup() {
  cancel_pending_dir "$(pending_path "$1")"
}

pending_guard() {
  local pending backup=""
  pending="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  if [[ -z "$pending" ]]; then
    if [[ -L "$PENDING_LATEST" ]]; then
      rm -f "$PENDING_LATEST"
      warn "已清理失效的安全回滚标记"
    fi
    return 0
  fi
  if [[ ! -d "$pending" ]]; then
    rm -f "$PENDING_LATEST"
    warn "已清理不存在的安全回滚记录"
    return 0
  fi
  if [[ -r "${pending}/backup" ]]; then
    backup="$(cat "${pending}/backup" 2>/dev/null || true)"
  fi
  if [[ -f "${pending}/armed" ]]; then
    warn "检测到上一次调优尚未确认；新一轮调优将以当前服务器参数作为基线"
    cancel_pending_dir "$pending"
    info "已取消上一次安全回滚计时器，新会话可以继续"
  else
    cancel_pending_dir "$pending"
    info "已清理上一次会话遗留的无效状态"
  fi
  if [[ -n "$backup" && ! -d "$backup" ]]; then
    warn "上一次会话的备份目录已不存在：$backup"
  fi
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
  printf 'stage\tround\tconfig\tstreams\tbuffer_mib\tbdp_ratio\trtt_ms\tmbps\tretrans\tretrans_percent\tscore\tpassed\n' >"$REPORT_FILE"
}

parse_iperf_json() {
  local file="$1" values bps bytes retrans rtt_us client
  if have python3; then
    values="$(python3 - "$file" <<'PY_JSON'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data=json.load(fh)
sent=data.get("end", {}).get("sum_sent", {})
rtts=[]
for stream in data.get("end", {}).get("streams", []):
    sender=stream.get("sender", stream)
    value=sender.get("mean_rtt")
    if isinstance(value, (int, float)) and value > 0:
        rtts.append(value)
connected=data.get("start", {}).get("connected", [])
client=connected[0].get("remote_host", "") if connected else ""
rtt=sum(rtts)/len(rtts) if rtts else 0
print(f'{sent.get("bits_per_second",0)}\t{sent.get("bytes",0)}\t{sent.get("retransmits",0)}\t{rtt}\t{client}')
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
    rtt_us="$(awk '/"mean_rtt"[[:space:]]*:/ {v=$0; sub(/^.*:[[:space:]]*/,"",v); sub(/,.*/,"",v); if(v+0>0){sum+=v;n++}} END {if(n) printf "%.2f",sum/n; else print 0}' "$file")"
    client="$(awk '/"remote_host"[[:space:]]*:/ {v=$0; sub(/^.*:[[:space:]]*"/,"",v); sub(/".*/,"",v); print v; exit}' "$file")"
    values="${values}"$'\t'"${rtt_us}"$'\t'"${client}"
  fi
  [[ -n "$values" ]] || return 1
  IFS=$'\t' read -r bps bytes retrans rtt_us client <<<"$values"
  is_number "$bps" && is_number "$bytes" && is_number "$retrans" || return 1
  RESULT_MBPS="$(awk -v v="$bps" 'BEGIN {printf "%.2f",v/1000000}')"
  RESULT_BYTES="$(awk -v v="$bytes" 'BEGIN {printf "%.0f",v}')"
  RESULT_RETRANS="$(awk -v v="$retrans" 'BEGIN {printf "%.0f",v}')"
  RESULT_RETRANS_PERCENT="$(awk -v r="$RESULT_RETRANS" -v b="$RESULT_BYTES" 'BEGIN {if(b<=0)print "100.0000";else printf "%.4f",r*1448/b*100}')"
  if is_number "${rtt_us:-}" && awk -v v="$rtt_us" 'BEGIN {exit !(v>0)}'; then
    RESULT_RTT_MS="$(awk -v v="$rtt_us" 'BEGIN {printf "%.2f",v/1000}')"
    RESULT_RTT_SOURCE="iperf3 JSON"
  else
    RESULT_RTT_MS="0"
    RESULT_RTT_SOURCE=""
  fi
  RESULT_CLIENT_ADDRESS="${client:-}"
}

adopt_measured_rtt() {
  if is_number "$RESULT_RTT_MS" && awk -v v="$RESULT_RTT_MS" 'BEGIN {exit !(v>0)}'; then
    RTT_MS="$RESULT_RTT_MS"
    RTT_SOURCE="${RESULT_RTT_SOURCE:-TCP 实测}"
  fi
}

candidate_regressed() {
  local candidate="$1" reference="$2"
  awk -v a="$candidate" -v b="$reference" 'BEGIN {exit !(a < b-0.50)}'
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

sample_tcp_rtt() {
  local port="$1"
  ss -tin 2>/dev/null | awk -v needle=":${port}" '
    index($0,needle) {matched=1; next}
    matched && /rtt:/ {
      v=$0
      sub(/^.*rtt:/,"",v)
      sub(/\/.*/,"",v)
      gsub(/[[:space:]]/,"",v)
      if(v ~ /^[0-9]+([.][0-9]+)?$/) print v
      exit
    }
    matched && $0 !~ /^[[:space:]]/ {matched=0}
  '
}

average_rtt_samples() {
  local file="$1"
  awk 'NF && $1 ~ /^[0-9]+([.][0-9]+)?$/ {sum+=$1; n++} END {if(n) printf "%.2f",sum/n}' "$file"
}

run_reverse_test() {
  local label="$1" streams="$2" address="$3" display_label="${4:-$1}" json_file err_file rtt_file elapsed=0 limit rc sample fallback_addr fallback_rtt
  json_file="${SESSION_DIR}/${label}.json"
  err_file="${SESSION_DIR}/${label}.err"
  rtt_file="${SESSION_DIR}/${label}.rtt-samples"
  port_is_free "$TEST_PORT" || die "测试端口 ${TEST_PORT} 已被占用"
  : >"$json_file"; : >"$err_file"; : >"$rtt_file"
  iperf3 -s -1 -J -p "$TEST_PORT" >"$json_file" 2>"$err_file" &
  CURRENT_TEST_PID=$!
  sleep 1
  kill -0 "$CURRENT_TEST_PID" 2>/dev/null || { cat "$err_file" >&2; die "iperf3 服务端启动失败"; }

  section "${display_label}｜${streams} 个 TCP 流｜端口 ${TEST_PORT}"
  printf '本地只需执行下面一条命令（不会修改本地 TCP 参数）：\n\n'
  printf '  iperf3 -c %s -p %s -R -P %s -t %s -i 1\n\n' "$address" "$TEST_PORT" "$streams" "$DURATION"
  printf '等待规则：最多等待连接 %s 秒；开始传输后约运行 %s 秒。\n' "$WAIT_SECONDS" "$DURATION"
  limit=$(( WAIT_SECONDS + DURATION + 10 ))
  while kill -0 "$CURRENT_TEST_PID" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed+1))
    sample="$(sample_tcp_rtt "$TEST_PORT" || true)"
    [[ -n "$sample" ]] && printf '%s\n' "$sample" >>"$rtt_file"
    if (( elapsed % 5 == 0 )); then
      printf '[TEST ] 状态：等待连接或测试进行中｜已用 %3s 秒｜端口 %s\n' "$elapsed" "$TEST_PORT"
    fi
    if (( elapsed >= limit )); then
      kill "$CURRENT_TEST_PID" 2>/dev/null || true
      wait "$CURRENT_TEST_PID" 2>/dev/null || true
      CURRENT_TEST_PID=""
      die "本轮测试超时：${WAIT_SECONDS} 秒内未连接，或测试未正常结束"
    fi
  done
  set +e
  wait "$CURRENT_TEST_PID"; rc=$?
  set -e
  CURRENT_TEST_PID=""
  (( rc == 0 )) || { cat "$err_file" >&2 || true; die "iperf3 测试失败，退出码 ${rc}"; }
  parse_iperf_json "$json_file" || { cat "$json_file" >&2 || true; die "无法解析 iperf3 测试结果"; }
  if ! awk -v v="$RESULT_RTT_MS" 'BEGIN {exit !(v>0)}'; then
    RESULT_RTT_MS="$(average_rtt_samples "$rtt_file")"
    if [[ -n "$RESULT_RTT_MS" ]]; then RESULT_RTT_SOURCE="ss TCP socket"; else RESULT_RTT_MS="0"; fi
  fi
  if ! awk -v v="$RESULT_RTT_MS" 'BEGIN {exit !(v>0)}'; then
    fallback_addr="${RESULT_CLIENT_ADDRESS:-$(guess_client_address)}"
    fallback_rtt="$(measure_ping_rtt "$fallback_addr" || true)"
    if [[ -n "$fallback_rtt" ]]; then RESULT_RTT_MS="$fallback_rtt"; RESULT_RTT_SOURCE="ICMP ping 备用测量"; fi
  fi
  calculate_result_quality
  print_interval_log "$json_file"
  printf '\n  平均下载吞吐：%s Mbps\n' "$RESULT_MBPS"
  printf '  TCP 重传次数：%s 次\n' "$RESULT_RETRANS"
  printf '  估算重传率：%s%%\n' "$RESULT_RETRANS_PERCENT"
  if awk -v v="$RESULT_RTT_MS" 'BEGIN {exit !(v>0)}'; then
    printf '  TCP 平均 RTT：%s ms\n' "$RESULT_RTT_MS"
  else
    printf '  TCP 平均 RTT：未取得\n'
  fi
  printf '  是否达到目标：%s\n\n' "$(format_pass "$RESULT_PASS")"
}
record_result() {
  local stage="$1" config="$2" streams="$3" buffer_mib="$4" factor="$5"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$stage" "$SEARCH_ROUNDS" "$config" "$streams" "$buffer_mib" "$factor" "$RESULT_RTT_MS" \
    "$RESULT_MBPS" "$RESULT_RETRANS" "$RESULT_RETRANS_PERCENT" "$RESULT_SCORE" "$RESULT_PASS" >>"$REPORT_FILE"
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
  local speed_summary retrans_summary outcome_summary overshoot_summary
  delta="$(awk -v a="$BASELINE_MBPS" -v b="$FINAL_MBPS" 'BEGIN {if(a<=0)print "0.00";else printf "%.2f",(b-a)/a*100}')"
  delta_retrans="$(awk -v a="$BASELINE_RETRANS_PERCENT" -v b="$FINAL_RETRANS_PERCENT" 'BEGIN {printf "%.4f",b-a}')"
  after_cc="$(sysctl_get net.ipv4.tcp_congestion_control)"
  after_qdisc="$(root_qdisc_kind "$iface")"
  after_rmem="$(sysctl_get net.ipv4.tcp_rmem)"
  after_wmem="$(sysctl_get net.ipv4.tcp_wmem)"
  if awk -v d="$delta" 'BEGIN {exit !(d>0.005)}'; then
    speed_summary="下载速度提高 ${delta}%（${BASELINE_MBPS} → ${FINAL_MBPS} Mbps）"
  elif awk -v d="$delta" 'BEGIN {exit !(d< -0.005)}'; then
    speed_summary="下载速度下降 ${delta#-}%（${BASELINE_MBPS} → ${FINAL_MBPS} Mbps）"
  else
    speed_summary="下载速度基本不变（${BASELINE_MBPS} → ${FINAL_MBPS} Mbps）"
  fi
  if awk -v d="$delta_retrans" 'BEGIN {exit !(d< -0.00005)}'; then
    retrans_summary="重传率下降 ${delta_retrans#-} 个百分点，稳定性改善"
  elif awk -v d="$delta_retrans" 'BEGIN {exit !(d>0.00005)}'; then
    retrans_summary="重传率上升 ${delta_retrans} 个百分点"
  else
    retrans_summary="重传率基本不变"
  fi
  case "$OUTCOME" in
    optimized-runtime) outcome_summary="已选出实测最优参数，目前仅在运行中生效；确认后可取消安全回滚" ;;
    optimized-persistent) outcome_summary="已选出实测最优参数，并已写入开机配置" ;;
    baseline-retained) outcome_summary="新参数没有超过原配置，已保留调优前参数" ;;
    baseline-restored-after-confirmation) outcome_summary="最优候选复测不稳定，已恢复调优前参数" ;;
    *) outcome_summary="$OUTCOME" ;;
  esac
  if (( OVERSHOOT_DETECTED )); then
    overshoot_summary="已在 ${OVERSHOOT_MIB} MiB 检测到性能回落，并完成回退精调"
  else
    overshoot_summary="未出现明显回落；搜索到总内存预算允许的上限"
  fi

  cat >"$COMPARISON_FILE" <<EOF_COMPARE
TCP/BBR 调优前后对比
====================

一眼看懂
--------
结论：${outcome_summary}
速度：${speed_summary}
稳定性：${retrans_summary}
搜索过程：${overshoot_summary}

本次测试条件
------------
会话编号：${SESSION_ID}
测试时间：$(date '+%Y-%m-%d %H:%M:%S %z')
测试方向：远程服务器 → 本地电脑（iperf3 -R）
服务器地址：${SERVER_ADDRESS}
出口网卡：${iface}
目标带宽：${TARGET_MBPS} Mbps
目标含义：服务器出站、本地下载和中间链路三者可达到上限中的较小值
达标门槛：目标带宽的 ${TARGET_UTILIZATION}% 且估算重传率不高于 ${MAX_RETRANS_PERCENT}%
自动 RTT：${RTT_MS} ms（${RTT_SOURCE}）
测试并发：${BASELINE_STREAMS} 个 TCP 流
候选搜索轮数：${SEARCH_ROUNDS}

服务器总内存与缓存预算
----------------------
物理总内存：$(format_mib "$MEM_TOTAL_MIB")
当前可用内存：$(format_mib "$MEM_AVAILABLE_MIB")（仅记录，不参与缓存上限计算）
用于分档的总内存：$(format_mib "$MEM_EFFECTIVE_MIB")（物理总内存与 cgroup 总上限取较小值）
TCP 单连接缓存预算：$(format_mib "$MEM_BUFFER_CAP_MIB")（用于分档的总内存 ÷ 64）
本链路 BDP：${BDP_MIB} MiB

关键结果
--------
| 项目 | 调优前 | 调优后 |
|---|---:|---:|
| 下载吞吐 | ${BASELINE_MBPS} Mbps | ${FINAL_MBPS} Mbps |
| TCP 重传次数 | ${BASELINE_RETRANS} | ${FINAL_RETRANS} |
| 估算重传率 | ${BASELINE_RETRANS_PERCENT}% | ${FINAL_RETRANS_PERCENT}% |
| 是否达到目标 | $(format_pass "$BASELINE_PASS") | $(format_pass "$FINAL_PASS") |
| 拥塞控制算法 | ${BEFORE_CC} | ${after_cc} |
| 出口队列规则 | ${BEFORE_QDISC} | ${after_qdisc} |
| 缓存最大值 | $(format_bytes_mib "$BEFORE_BUFFER_BYTES") | $(format_bytes_mib "$final_buffer") |

TCP 参数明细
------------
tcp_rmem 调优前：${BEFORE_RMEM}
tcp_rmem 调优后：${after_rmem}
tcp_wmem 调优前：${BEFORE_WMEM}
tcp_wmem 调优后：${after_wmem}
最优候选：${BEST_KIND}
最优缓存：${BEST_BUFFER_MIB} MiB
最优缓存 / BDP：${BEST_FACTOR} 倍
单流 QoS 特征：$([[ "$QOS_DETECTED" == "1" ]] && echo "是" || echo "否")
EOF_COMPARE

  {
    printf '\n逐轮测试记录\n------------\n'
    printf '| 阶段 | 轮次 | 并发 | 缓存 MiB | RTT ms | 吞吐 Mbps | 重传率 | 达标 |\n'
    printf '|---|---:|---:|---:|---:|---:|---:|---:|\n'
    awk -F '\t' 'NR>1 {passed=($12=="yes"?"是":"否"); printf "| %s | %s | %s | %s | %s | %s | %s%% | %s |\n",$1,$2,$4,$5,$7,$8,$10,passed}' "$REPORT_FILE"
    printf '\n日志文件\n--------\n'
    printf '完整运行日志：%s\n' "$RUN_LOG"
    printf '结构化逐轮数据：%s\n' "$REPORT_FILE"
    printf '调优前系统状态：%s/system-before.txt\n' "$SESSION_DIR"
    printf '调优后系统状态：%s/system-after.txt\n' "$SESSION_DIR"
  } >>"$COMPARISON_FILE"
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

  local iface address root_kind next_stream first_speed candidate_count=0 index mib factor previous_best
  local lower upper midpoint gain
  iface="$(resolve_iface)"
  [[ -n "$iface" ]] || die "无法识别出口网卡"
  ip link show dev "$iface" >/dev/null 2>&1 || die "出口网卡不存在：$iface"
  address="$(guess_server_address)"
  [[ -n "$address" ]] || die "无法识别服务器连接地址，请使用 --server-address"
  SERVER_ADDRESS="$address"
  TEST_PORT="$(choose_random_port)" || die "无法找到未占用的随机端口"

  RTT_MS=""; RTT_SOURCE=""
  SEARCH_ROUNDS=0; OVERSHOOT_DETECTED=0; OVERSHOOT_MIB=0
  BEST_KIND="baseline"; BEST_BUFFER_MIB=0; BEST_FACTOR="原配置"; QOS_DETECTED=0

  detect_memory_limits
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
  printf '  测试方向：远程服务器 → 本地电脑\n'
  printf '  服务器地址：%s\n' "$address"
  printf '  出口网卡：%s\n' "$iface"
  printf '  目标带宽：%s Mbps\n' "$TARGET_MBPS"
  printf '  目标带宽含义：服务器出站、本地下载和中间链路上限中的较小值\n'
  printf '  RTT：首轮 iperf3 自动测量\n'
  printf '  随机测试端口：%s\n' "$TEST_PORT"
  printf '  总内存分档基数：%s\n' "$(format_mib "$MEM_EFFECTIVE_MIB")"
  printf '  TCP 缓存预算：%s\n' "$(format_mib "$MEM_BUFFER_CAP_MIB")"
  printf '  连接等待 / 安全回滚：%s 秒 / %s 秒\n' "$WAIT_SECONDS" "$AUTO_ROLLBACK_SECONDS"
  printf '  日志目录：%s\n\n' "$SESSION_DIR"
  warn "请确认云安全组和服务器防火墙允许 TCP ${TEST_PORT}；脚本不会修改本地电脑"

  trap abort_without_changes INT TERM
  TEST_STREAMS="$START_STREAMS"
  run_reverse_test "before-p${TEST_STREAMS}" "$TEST_STREAMS" "$address" "调优前基线"
  record_result before original "$TEST_STREAMS" "$(awk -v b="$BEFORE_BUFFER_BYTES" 'BEGIN {printf "%.2f",b/1048576}')" original
  INITIAL_SINGLE_MBPS="$RESULT_MBPS"
  first_speed="$RESULT_MBPS"
  adopt_measured_rtt
  if [[ -z "$RTT_MS" ]]; then
    die "无法自动取得本地与服务器之间的 RTT；请检查 iperf3 JSON、ss 或客户端 ICMP 可达性"
  fi
  calculate_bdp
  generate_candidates

  section "链路自动测量与搜索范围"
  printf '  实测 TCP RTT：%s ms（%s）\n' "$RTT_MS" "$RTT_SOURCE"
  printf '  目标链路 BDP：%s MiB\n' "$BDP_MIB"
  printf '  缓存搜索起点：%s MiB\n' "${CANDIDATE_MIBS[0]}"
  printf '  缓存安全上限：%s MiB\n' "$MEM_BUFFER_CAP_MIB"
  printf '  搜索方式：倍增逼近；性能回落后二分回退到 1 MiB 粒度\n\n'
  if awk -v b="$BDP_MIB" -v c="$MEM_BUFFER_CAP_MIB" 'BEGIN {exit !(b>c)}'; then
    warn "目标 BDP 大于按服务器总内存计算的缓存预算；不会突破内存安全上限"
  fi

  while result_low_speed_low_retrans; do
    next_stream="$(next_stream_count "$TEST_STREAMS")"
    [[ "$next_stream" != "$TEST_STREAMS" ]] || break
    TEST_STREAMS="$next_stream"
    info "单流重传较低但速度不足，改用 ${TEST_STREAMS} 个并发流判断是否存在单流 QoS"
    run_reverse_test "before-p${TEST_STREAMS}" "$TEST_STREAMS" "$address" "调优前并发诊断"
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
  BEST_BUFFER_MIB="$(awk -v b="$BASELINE_BUFFER_BYTES" 'BEGIN {printf "%.2f",b/1048576}')"

  if (( BASELINE_STREAMS > START_STREAMS )); then
    gain="$(awk -v a="$first_speed" -v b="$BASELINE_MBPS" 'BEGIN {if(a<=0)print 0;else printf "%.2f",(b-a)/a*100}')"
    if awk -v g="$gain" 'BEGIN {exit !(g>=15)}'; then QOS_DETECTED="1"; fi
    info "并发诊断完成：${START_STREAMS} 流 ${first_speed} Mbps → ${BASELINE_STREAMS} 流 ${BASELINE_MBPS} Mbps（${gain}%）"
  fi

  trap - INT TERM
  BACKUP_DIR="$(create_backup "$iface")"
  TUNING_ACTIVE="1"
  trap cleanup_tuning_on_exit EXIT
  trap stop_tuning_on_signal INT TERM
  schedule_rollback "$BACKUP_DIR"

  section "第一阶段：持续增大 TCP 缓存，逼近性能边界"
  for ((index=0; index<${#CANDIDATE_MIBS[@]}; index++)); do
    mib="${CANDIDATE_MIBS[$index]}"
    factor="${CANDIDATE_FACTORS[$index]}"
    candidate_count=$((candidate_count+1)); SEARCH_ROUNDS="$candidate_count"
    printf '\n[SEARCH] 第 %-3s 轮｜扩大探索｜缓存 %6s MiB｜约 %5s × BDP\n' "$SEARCH_ROUNDS" "$mib" "$factor"
    apply_candidate "$iface" "$mib"
    run_reverse_test "candidate-${SEARCH_ROUNDS}-${mib}m" "$BASELINE_STREAMS" "$address" "候选 ${SEARCH_ROUNDS}（扩大探索）"
    record_result candidate bbr-fq "$BASELINE_STREAMS" "$mib" "$factor"
    previous_best="$BEST_SCORE"
    if result_better_than "$RESULT_SCORE" "$BEST_SCORE"; then
      BEST_KIND="candidate-${SEARCH_ROUNDS}"
      BEST_BUFFER_MIB="$mib"
      BEST_FACTOR="$factor"
      BEST_MBPS="$RESULT_MBPS"
      BEST_RETRANS="$RESULT_RETRANS"
      BEST_RETRANS_PERCENT="$RESULT_RETRANS_PERCENT"
      BEST_SCORE="$RESULT_SCORE"
      BEST_PASS="$RESULT_PASS"
      info "更新最优：缓存 ${mib} MiB｜吞吐 ${BEST_MBPS} Mbps｜重传率 ${BEST_RETRANS_PERCENT}%"
    elif [[ "$BEST_KIND" != "baseline" ]] && (( mib > BEST_BUFFER_MIB )) && candidate_regressed "$RESULT_SCORE" "$BEST_SCORE"; then
      OVERSHOOT_DETECTED=1
      OVERSHOOT_MIB="$mib"
      warn "检测到性能边界：${mib} MiB 已低于当前最优 ${BEST_BUFFER_MIB} MiB，开始回退精调"
      break
    else
      info "本轮没有超过当前最优（本轮 ${RESULT_MBPS} Mbps，当前最优 ${BEST_MBPS} Mbps），继续向上测试"
    fi
  done

  if (( OVERSHOOT_DETECTED )) && [[ "$BEST_KIND" != "baseline" ]]; then
    lower="${BEST_BUFFER_MIB%.*}"
    upper="$OVERSHOOT_MIB"
    section "第二阶段：在 ${lower}～${upper} MiB 之间回退精调"
    while (( upper - lower > 1 )); do
      midpoint=$(( (lower + upper) / 2 ))
      factor="$(candidate_factor "$midpoint")"
      candidate_count=$((candidate_count+1)); SEARCH_ROUNDS="$candidate_count"
      printf '\n[SEARCH] 第 %-3s 轮｜回退精调｜缓存 %6s MiB｜约 %5s × BDP\n' "$SEARCH_ROUNDS" "$midpoint" "$factor"
      apply_candidate "$iface" "$midpoint"
      run_reverse_test "candidate-${SEARCH_ROUNDS}-${midpoint}m" "$BASELINE_STREAMS" "$address" "候选 ${SEARCH_ROUNDS}（回退精调）"
      record_result candidate bbr-fq "$BASELINE_STREAMS" "$midpoint" "$factor"
      if result_better_than "$RESULT_SCORE" "$BEST_SCORE"; then
        BEST_KIND="candidate-${SEARCH_ROUNDS}"
        BEST_BUFFER_MIB="$midpoint"
        BEST_FACTOR="$factor"
        BEST_MBPS="$RESULT_MBPS"
        BEST_RETRANS="$RESULT_RETRANS"
        BEST_RETRANS_PERCENT="$RESULT_RETRANS_PERCENT"
        BEST_SCORE="$RESULT_SCORE"
        BEST_PASS="$RESULT_PASS"
        lower="$midpoint"
        info "精调发现更优值：缓存 ${midpoint} MiB｜吞吐 ${BEST_MBPS} Mbps｜重传率 ${BEST_RETRANS_PERCENT}%"
      elif candidate_regressed "$RESULT_SCORE" "$BEST_SCORE"; then
        upper="$midpoint"
        info "${midpoint} MiB 已越过最优区域，继续向下回退"
      else
        lower="$midpoint"
        info "${midpoint} MiB 与当前最优基本持平，继续向上逼近边界"
      fi
    done
    info "回退精调完成：边界已收敛到 ${lower}～${upper} MiB，选择实测分数最高的 ${BEST_BUFFER_MIB} MiB"
  fi

  if [[ "$BEST_KIND" == "baseline" ]]; then
    info "全部安全候选均未超过调优前配置，恢复并保留原参数"
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
    section "最终复测：应用实测最优缓存 ${BEST_BUFFER_MIB} MiB"
    apply_candidate "$iface" "$BEST_BUFFER_MIB"
    run_reverse_test "final-${BEST_BUFFER_MIB}m" "$BASELINE_STREAMS" "$address" "最优参数复测"
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
      BEST_BUFFER_MIB="$(awk -v b="$BASELINE_BUFFER_BYTES" 'BEGIN {printf "%.2f",b/1048576}')"
      BEST_FACTOR="原配置"
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
        warn "最优参数已生效；请在 ${AUTO_ROLLBACK_SECONDS} 秒内另开 SSH 验证，然后执行 sudo $PROGRAM confirm"
      else
        warn "最优参数已生效；本次运行未启用定时安全回滚"
      fi
    fi
  fi

  capture_state "$iface" "${SESSION_DIR}/system-after.txt"
  write_comparison "$iface" "$FINAL_BUFFER_BYTES"
  append_history
  TUNING_ACTIVE="0"
  trap - EXIT
  if [[ "$FINAL_PASS" != "yes" ]]; then
    warn "最终结果仍未达到设定目标；脚本已在内存安全范围内选择实测最优配置"
  fi
  if (( QOS_DETECTED )); then
    warn "检测到单流 QoS 特征；业务传输建议使用 8～16 个并发连接"
  fi
  info "完整日志：$RUN_LOG"
  info "通俗对比报告：$COMPARISON_FILE"
}
status_command() {
  require_linux
  for cmd in ip tc sysctl awk; do have "$cmd" || die "缺少命令：$cmd"; done
  local iface rmax wmax
  iface="$(resolve_iface)"
  detect_memory_limits
  rmax="$(sysctl_get net.core.rmem_max)"
  wmax="$(sysctl_get net.core.wmem_max)"
  section "当前服务器 TCP/BBR 状态"
  printf '  时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
  printf '  内核：%s\n' "$(uname -srmo)"
  printf '  出口网卡：%s\n' "$iface"
  printf '  拥塞控制算法：%s\n' "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '  内核可用算法：%s\n' "$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  printf '  系统默认队列：%s\n' "$(sysctl_get net.core.default_qdisc)"
  printf '  出口实际队列：%s\n' "$(root_qdisc_kind "$iface")"
  printf '  服务器物理总内存：%s\n' "$(format_mib "$MEM_TOTAL_MIB")"
  printf '  缓存分档总内存：%s\n' "$(format_mib "$MEM_EFFECTIVE_MIB")"
  printf '  自动缓存预算：%s\n' "$(format_mib "$MEM_BUFFER_CAP_MIB")"
  printf '  接收缓存硬上限：%s\n' "$(format_bytes_mib "$rmax")"
  printf '  发送缓存硬上限：%s\n' "$(format_bytes_mib "$wmax")"
  printf '  tcp_rmem（最小/默认/最大）：%s\n' "$(sysctl_get net.ipv4.tcp_rmem)"
  printf '  tcp_wmem（最小/默认/最大）：%s\n' "$(sysctl_get net.ipv4.tcp_wmem)"
  printf '\n队列详细统计\n------------\n'
  tc -s -d qdisc show dev "$iface" || true
}

history_command() {
  if [[ ! -r "$HISTORY_FILE" ]]; then
    info "尚无历史测试记录"
    return
  fi
  section "TCP/BBR 历史测试"
  printf '| 时间 | 会话 | 目标 Mbps | RTT ms | 调优前 Mbps | 调优后 Mbps | 变化 | 缓存 MiB | 结果 |\n'
  printf '|---|---|---:|---:|---:|---:|---:|---:|---|\n'
  awk -F '\t' 'NR>1 {printf "| %s | %s | %s | %s | %s | %s | %s%% | %s | %s |\n",$1,$2,$3,$4,$6,$7,$8,$11,$12}' "$HISTORY_FILE"
  printf '\n完整历史数据：%s\n' "$HISTORY_FILE"
  printf '每个会话的日志目录：%s\n' "$SESSION_ROOT"
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
  local address bandwidth streams duration util retrans
  local args=()
  address="$(guess_server_address 2>/dev/null || true)"
  printf '%s目标带宽说明%s\n' "$UI_YELLOW" "$UI_RESET"
  printf '  本工具测试“远程服务器 → 本地电脑”的下载方向。\n'
  printf '  建议填写：服务器出站带宽上限与本地下载带宽上限中的较小值。\n'
  printf '  例如服务器限速 200 Mbps、本地宽带 1000 Mbps，应填写 200。\n\n'
  bandwidth="$(ui_read_number "期望端到端下载带宽 Mbps" "1000" "1" "100000")" || return
  address="$(ui_read_text "服务器公网 IP 或域名" "$address")" || return
  [[ -n "$address" ]] || { printf '%s服务器地址不能为空%s\n' "$UI_RED" "$UI_RESET"; return; }
  streams="$(ui_read_number "起始并发流" "1" "1" "64")" || return
  duration="$(ui_read_number "每轮测试秒数" "15" "5" "300")" || return
  util="$(ui_read_number "目标带宽利用率 %" "90" "1" "100")" || return
  retrans="$(ui_read_number "最大估算重传率 %" "1" "0" "100")" || return
  if ui_yes_no "最优参数通过复测后写入开机配置" "n"; then args+=(--persist); fi
  printf '\n%s自动规则%s\n' "$UI_YELLOW" "$UI_RESET"
  printf '  • RTT 由首轮 iperf3 自动测量。\n'
  printf '  • 候选数量不设人工上限，发现性能回落后自动回退精调。\n'
  printf '  • 每轮等待本地连接 %s 秒；安全回滚固定为 %s 秒。\n' "$WAIT_SECONDS" "$AUTO_ROLLBACK_SECONDS"
  printf '  • 本地只执行测速命令，不修改任何本地 TCP 参数。\n\n'
  ui_yes_no "开始自动寻优" "n" || return
  ui_execute 1 autotune --bandwidth-mbps "$bandwidth" --server-address "$address" \
    --parallel "$streams" --duration "$duration" \
    --target-utilization "$util" --max-retrans-percent "$retrans" "${args[@]}"
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
