#!/usr/bin/env bash
# bbr-tune.sh - 基于 BDP、链路场景和出口整形的 Linux TCP/BBR 调优工具
# 目标：可审计、可预览、可回滚；不把 socket buffer 误当作限速器。
set -Eeuo pipefail

VERSION="1.3.1"
PROGRAM="${0##*/}"
SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="${PWD}/${SCRIPT_PATH}"

SYSCTL_FILE="/etc/sysctl.d/99-bbr-tcp-tuning.conf"
MODULES_FILE="/etc/modules-load.d/bbr-tcp-tuning.conf"
ENV_FILE="/etc/default/bbr-tcp-tuning"
QDISC_HELPER="/usr/local/sbin/bbr-tcp-qdisc"
SERVICE_FILE="/etc/systemd/system/bbr-tcp-tuning.service"
STATE_DIR="/var/lib/bbr-tcp-tuning"
BACKUP_ROOT="${STATE_DIR}/backups"
LATEST_LINK="${STATE_DIR}/latest"
IPERF_RUN_DIR="/run/bbr-tcp-tuning"
IPERF_PID_FILE="${IPERF_RUN_DIR}/iperf3.pid"
IPERF_PORT_FILE="${IPERF_RUN_DIR}/iperf3.port"
IPERF_LOG_FILE="${IPERF_RUN_DIR}/iperf3.log"
PENDING_DIR="${STATE_DIR}/pending"
PENDING_LATEST="${STATE_DIR}/pending-latest"

COMMAND=""
PROFILE="auto"
SYMPTOM="normal"
IFACE="auto"
BANDWIDTH_MBPS=""
CAP_MBPS=""
RTT_MS=""
LOSS_PERCENT="0"
HEADROOM_PERCENT="95"
BUFFER_FACTOR="1.35"
BUFFER_MAX_MIB="128"
TARGET=""
IPERF_SERVER=""
SERVER_ADDRESS=""
IPERF_PORT="0"
DURATION="15"
PARALLEL_STREAMS="1"
PING_COUNT="20"
PERSIST="1"
ALLOW_BUFFER_SHRINK="0"
FORCE="0"
ASSUME_YES="0"
BACKUP_PATH=""
AUTO_ROLLBACK_SECONDS="0"
TARGET_UTILIZATION="90"
MAX_RETRANS_PERCENT="1"
MAX_ITERATIONS="4"
TEST_WAIT_SECONDS="300"
PERSIST_ON_SUCCESS="0"
QUIET="0"

RESOLVED_PROFILE=""
RECOMMENDED_BUFFER_MIB=""
EFFECTIVE_BUFFER_MIB=""
BUFFER_BYTES=""
BDP_BYTES=""
BDP_MIB=""
SHAPER_MBPS=""
TBF_BURST_BYTES=""
TEST_RESULT_MBPS=""
TEST_RESULT_BYTES=""
TEST_RESULT_RETRANS=""
TEST_RESULT_RETRANS_PERCENT=""
CURRENT_TEST_PID=""
AUTOTUNE_MULTIFLOW="0"

log()  { (( QUIET )) || printf '%s\n' "$*"; }
info() { log "[INFO] $*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
用法：
  bbr-tune.sh                         # 进入交互菜单
  bbr-tune.sh interactive             # 进入交互菜单
  bbr-tune.sh probe    [探测参数]
  bbr-tune.sh plan     --bandwidth-mbps N --rtt-ms N [调优参数]
  bbr-tune.sh apply    --bandwidth-mbps N --rtt-ms N [调优参数]
  bbr-tune.sh autotune --bandwidth-mbps N --rtt-ms N [闭环测试参数]
  bbr-tune.sh iperf-start  [--iperf-port 0] [--server-address HOST]
  bbr-tune.sh iperf-status [--server-address HOST]
  bbr-tune.sh iperf-stop
  bbr-tune.sh confirm
  bbr-tune.sh verify   [--iface auto|DEV]
  bbr-tune.sh rollback [--backup DIR] [--yes]

命令：
  interactive 交互式向导；也可使用 menu 或 wizard 别名
  probe       检查服务器基线；缺少 iperf3 时自动安装，但不改 TCP/qdisc
  plan        计算 BDP、缓冲区、qdisc 和 sysctl 方案，不改配置
  apply       备份后应用配置；默认写入持久化文件并安装 systemd 服务
  autotune    等待本地客户端测试，读取服务器端结果并迭代调参直到达标
  iperf-start 在本机（远程服务器）启动临时 iperf3 服务端
  iperf-status 查看 iperf3 服务状态并打印客户端测速命令
  iperf-stop  停止由本脚本启动的 iperf3 服务端
  confirm     确认 SSH 连接正常并取消待执行的自动回滚
  verify      验证 BBR、sysctl、qdisc、重传计数和当前 TCP 连接
  rollback    回滚最近一次 apply；也可用 --backup 指定备份目录

调优参数：
  --profile auto|balanced|hard-cap|qos|lfn|lossy
  --symptom normal|hard-cap|single-flow-qos|lfn|random-loss
  --bandwidth-mbps N      目标吞吐，单位 Mbps
  --cap-mbps N            已知宿主机/网关硬上限；hard-cap 未指定时使用 bandwidth
  --rtt-ms N              基准 RTT，单位 ms
  --loss-percent N        基准丢包百分比；auto 模式 >=2% 时优先判为 lossy
  --iface auto|DEV        出口网卡；默认按 1.1.1.1 路由自动识别
  --headroom-percent N    hard-cap 整形占硬上限的百分比，默认 95
  --buffer-factor N       推荐 socket buffer = BDP × 系数，默认 1.35
  --buffer-max-mib N      自动计算上限，默认 128 MiB
  --allow-buffer-shrink   允许把现有全局 socket buffer 上限调低（默认禁止）
  --runtime-only          只修改当前运行时，不写持久化配置
  --force                 允许覆盖自定义 qdisc；回滚只能尽力恢复其类型
  --auto-rollback-seconds N 远程变更后 N 秒未 confirm 则自动回滚；0 表示禁用
  --yes                   非交互确认 apply/rollback

闭环测试参数：
  --target-utilization N  达标吞吐占目标带宽的百分比，默认 90
  --max-retrans-percent N 允许的估算重传比例，默认 1%
  --max-iterations N      最大自动调参轮数，默认 4
  --test-wait-seconds N   每轮等待本地客户端连接的秒数，默认 300
  --parallel N            初始并发流数，默认 1；低重传低吞吐时自动尝试 8/16 流
  --duration N            每轮测试时长，默认 15 秒
  --persist-on-success    达标后把最终服务器参数持久化

服务端探测与测速参数：
  --target HOST           从服务器执行可选的外部 ping，仅用于出口诊断
  --server-address HOST   打印给本地客户端使用的服务器公网 IP/域名
  --iperf-port N          服务端监听端口；默认 0，自动选择未占用的随机端口
  --ping-count N          默认 20

注意：本脚本运行在远程服务器。iperf3 的 -c/-R 命令应在你的本地客户端执行，
远程服务器只负责运行 iperf3 -s。

示例：
  sudo ./bbr-tune.sh
  ./bbr-tune.sh probe --target 1.1.1.1 --server-address speed.example.com
  sudo ./bbr-tune.sh iperf-start --iperf-port 0 --server-address speed.example.com
  ./bbr-tune.sh plan --profile hard-cap --cap-mbps 200 --bandwidth-mbps 200 --rtt-ms 30
  sudo ./bbr-tune.sh autotune --profile auto --bandwidth-mbps 1000 --rtt-ms 180 --parallel 1 --server-address speed.example.com
  sudo ./bbr-tune.sh confirm
  ./bbr-tune.sh verify
  sudo ./bbr-tune.sh rollback --yes
USAGE
}

need_arg() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "参数 $1 缺少值"
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    COMMAND="interactive"
    return
  fi
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
  esac
  COMMAND="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) need_arg "$@"; PROFILE="$2"; shift 2 ;;
      --symptom) need_arg "$@"; SYMPTOM="$2"; shift 2 ;;
      --iface) need_arg "$@"; IFACE="$2"; shift 2 ;;
      --bandwidth-mbps) need_arg "$@"; BANDWIDTH_MBPS="$2"; shift 2 ;;
      --cap-mbps) need_arg "$@"; CAP_MBPS="$2"; shift 2 ;;
      --rtt-ms) need_arg "$@"; RTT_MS="$2"; shift 2 ;;
      --loss-percent) need_arg "$@"; LOSS_PERCENT="$2"; shift 2 ;;
      --headroom-percent) need_arg "$@"; HEADROOM_PERCENT="$2"; shift 2 ;;
      --buffer-factor) need_arg "$@"; BUFFER_FACTOR="$2"; shift 2 ;;
      --buffer-max-mib) need_arg "$@"; BUFFER_MAX_MIB="$2"; shift 2 ;;
      --target) need_arg "$@"; TARGET="$2"; shift 2 ;;
      --iperf-server) need_arg "$@"; IPERF_SERVER="$2"; shift 2 ;;
      --server-address) need_arg "$@"; SERVER_ADDRESS="$2"; shift 2 ;;
      --iperf-port) need_arg "$@"; IPERF_PORT="$2"; shift 2 ;;
      --duration) need_arg "$@"; DURATION="$2"; shift 2 ;;
      --parallel) need_arg "$@"; PARALLEL_STREAMS="$2"; shift 2 ;;
      --ping-count) need_arg "$@"; PING_COUNT="$2"; shift 2 ;;
      --backup) need_arg "$@"; BACKUP_PATH="$2"; shift 2 ;;
      --auto-rollback-seconds) need_arg "$@"; AUTO_ROLLBACK_SECONDS="$2"; shift 2 ;;
      --target-utilization) need_arg "$@"; TARGET_UTILIZATION="$2"; shift 2 ;;
      --max-retrans-percent) need_arg "$@"; MAX_RETRANS_PERCENT="$2"; shift 2 ;;
      --max-iterations) need_arg "$@"; MAX_ITERATIONS="$2"; shift 2 ;;
      --test-wait-seconds) need_arg "$@"; TEST_WAIT_SECONDS="$2"; shift 2 ;;
      --persist-on-success) PERSIST_ON_SUCCESS="1"; shift ;;
      --runtime-only) PERSIST="0"; shift ;;
      --allow-buffer-shrink) ALLOW_BUFFER_SHRINK="1"; shift ;;
      --force) FORCE="1"; shift ;;
      --yes|-y) ASSUME_YES="1"; shift ;;
      --quiet|-q) QUIET="1"; shift ;;
      --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) die "未知参数：$1（使用 --help 查看帮助）" ;;
    esac
  done
}

validate_common_options() {
  case "$PROFILE" in auto|balanced|hard-cap|qos|lfn|lossy) ;; *) die "无效 profile：$PROFILE" ;; esac
  case "$SYMPTOM" in normal|hard-cap|single-flow-qos|lfn|random-loss) ;; *) die "无效 symptom：$SYMPTOM" ;; esac
  is_number "$LOSS_PERCENT" || die "--loss-percent 必须是非负数字"
  awk -v v="$LOSS_PERCENT" 'BEGIN { exit !(v >= 0 && v <= 100) }' || die "loss-percent 必须在 0~100 之间"
  is_number "$HEADROOM_PERCENT" || die "--headroom-percent 必须是数字"
  is_number "$BUFFER_FACTOR" || die "--buffer-factor 必须是数字"
  is_integer "$BUFFER_MAX_MIB" || die "--buffer-max-mib 必须是正整数"
  is_integer "$IPERF_PORT" || die "--iperf-port 必须是整数"
  is_integer "$DURATION" || die "--duration 必须是整数"
  is_integer "$PARALLEL_STREAMS" || die "--parallel 必须是整数"
  is_integer "$PING_COUNT" || die "--ping-count 必须是整数"
  is_integer "$AUTO_ROLLBACK_SECONDS" || die "--auto-rollback-seconds 必须是整数"
  is_number "$TARGET_UTILIZATION" || die "--target-utilization 必须是数字"
  is_number "$MAX_RETRANS_PERCENT" || die "--max-retrans-percent 必须是数字"
  is_integer "$MAX_ITERATIONS" || die "--max-iterations 必须是整数"
  is_integer "$TEST_WAIT_SECONDS" || die "--test-wait-seconds 必须是整数"

  awk -v v="$HEADROOM_PERCENT" 'BEGIN { exit !(v > 0 && v < 100) }' || die "headroom 必须在 0 与 100 之间"
  awk -v v="$BUFFER_FACTOR" 'BEGIN { exit !(v >= 1.0 && v <= 4.0) }' || die "buffer-factor 建议并限制在 1.0~4.0"
  (( BUFFER_MAX_MIB >= 2 )) || die "buffer-max-mib 至少为 2"
  (( IPERF_PORT >= 0 && IPERF_PORT <= 65535 )) || die "iperf 端口必须为 0（自动随机）或 1~65535"
  (( DURATION >= 1 && PARALLEL_STREAMS >= 1 && PING_COUNT >= 1 )) || die "探测计数必须大于 0"
  (( AUTO_ROLLBACK_SECONDS == 0 || (AUTO_ROLLBACK_SECONDS >= 30 && AUTO_ROLLBACK_SECONDS <= 86400) )) || die "自动回滚时间必须为 0，或在 30~86400 秒之间"
  awk -v v="$TARGET_UTILIZATION" 'BEGIN { exit !(v > 0 && v <= 100) }' || die "target-utilization 必须在 0~100 之间"
  awk -v v="$MAX_RETRANS_PERCENT" 'BEGIN { exit !(v >= 0 && v <= 100) }' || die "max-retrans-percent 必须在 0~100 之间"
  (( MAX_ITERATIONS >= 1 && MAX_ITERATIONS <= 10 )) || die "max-iterations 必须在 1~10 之间"
  (( TEST_WAIT_SECONDS >= 30 && TEST_WAIT_SECONDS <= 3600 )) || die "test-wait-seconds 必须在 30~3600 秒之间"
}

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "$COMMAND 只能在 Linux 上执行；plan 可在其他系统离线计算"
}

require_root() {
  (( EUID == 0 )) || die "$COMMAND 需要 root 权限，请使用 sudo"
}

have() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "缺少命令：$cmd"
  done
}

resolve_iface() {
  if [[ "$IFACE" != "auto" ]]; then
    printf '%s\n' "$IFACE"
    return 0
  fi
  require_cmds ip
  local dev
  dev="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "$dev" ]] || die "无法自动识别出口网卡，请用 --iface 指定"
  printf '%s\n' "$dev"
}

resolve_profile() {
  if [[ "$PROFILE" != "auto" ]]; then
    RESOLVED_PROFILE="$PROFILE"
    return
  fi

  case "$SYMPTOM" in
    hard-cap) RESOLVED_PROFILE="hard-cap" ;;
    single-flow-qos) RESOLVED_PROFILE="qos" ;;
    lfn) RESOLVED_PROFILE="lfn" ;;
    random-loss) RESOLVED_PROFILE="lossy" ;;
    normal)
      if awk -v loss="$LOSS_PERCENT" 'BEGIN { exit !(loss >= 2.0) }'; then
        RESOLVED_PROFILE="lossy"
      elif awk -v rtt="$RTT_MS" 'BEGIN { exit !(rtt >= 100.0) }'; then
        RESOLVED_PROFILE="lfn"
      else
        RESOLVED_PROFILE="balanced"
      fi
      ;;
  esac
}

next_pow2_mib() {
  awk -v bytes="$1" -v max_mib="$BUFFER_MAX_MIB" '
    BEGIN {
      mib = 1048576;
      need = int((bytes + mib - 1) / mib);
      p = 1;
      while (p < need) p *= 2;
      if (p < 2) p = 2;
      if (p > max_mib) p = max_mib;
      printf "%d\n", p;
    }'
}

calculate_plan() {
  [[ -n "$BANDWIDTH_MBPS" ]] || die "$COMMAND 需要 --bandwidth-mbps"
  [[ -n "$RTT_MS" ]] || die "$COMMAND 需要 --rtt-ms"
  is_number "$BANDWIDTH_MBPS" || die "--bandwidth-mbps 必须是正数"
  is_number "$RTT_MS" || die "--rtt-ms 必须是正数"
  awk -v v="$BANDWIDTH_MBPS" 'BEGIN { exit !(v > 0) }' || die "bandwidth 必须大于 0"
  awk -v v="$RTT_MS" 'BEGIN { exit !(v > 0) }' || die "rtt 必须大于 0"

  if [[ -n "$CAP_MBPS" ]]; then
    is_number "$CAP_MBPS" || die "--cap-mbps 必须是正数"
    awk -v v="$CAP_MBPS" 'BEGIN { exit !(v > 0) }' || die "cap 必须大于 0"
  fi

  resolve_profile

  local buffer_basis_mbps="$BANDWIDTH_MBPS"
  if [[ "$RESOLVED_PROFILE" == "hard-cap" && -n "$CAP_MBPS" ]]; then
    buffer_basis_mbps="$CAP_MBPS"
  fi

  BDP_BYTES="$(awk -v bw="$buffer_basis_mbps" -v rtt="$RTT_MS" 'BEGIN { printf "%.0f\n", bw * 1000000 * (rtt / 1000) / 8 }')"
  BDP_MIB="$(awk -v b="$BDP_BYTES" 'BEGIN { printf "%.2f\n", b / 1048576 }')"
  local recommended_bytes
  recommended_bytes="$(awk -v b="$BDP_BYTES" -v f="$BUFFER_FACTOR" 'BEGIN { printf "%.0f\n", b * f }')"
  RECOMMENDED_BUFFER_MIB="$(next_pow2_mib "$recommended_bytes")"
  EFFECTIVE_BUFFER_MIB="$RECOMMENDED_BUFFER_MIB"
  BUFFER_BYTES="$(( RECOMMENDED_BUFFER_MIB * 1048576 ))"

  local cap_basis="${CAP_MBPS:-$BANDWIDTH_MBPS}"
  SHAPER_MBPS="$(awk -v cap="$cap_basis" -v h="$HEADROOM_PERCENT" 'BEGIN { v=int(cap*h/100); if (v < 1) v=1; printf "%d\n", v }')"
  TBF_BURST_BYTES="$(awk -v rate="$SHAPER_MBPS" 'BEGIN { b=rate*125; if (b < 32768) b=32768; b=int((b+1023)/1024)*1024; printf "%d\n", b }')"
}

sysctl_get() {
  local key="$1"
  sysctl -n "$key" 2>/dev/null || true
}

sysctl_exists() {
  sysctl -n "$1" >/dev/null 2>&1
}

max_int() {
  local max=0 n
  for n in "$@"; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > max )) && max="$n"
  done
  printf '%s\n' "$max"
}

current_buffer_max() {
  local core_r core_w tcp_r tcp_w tcp_r_max tcp_w_max
  core_r="$(sysctl_get net.core.rmem_max)"
  core_w="$(sysctl_get net.core.wmem_max)"
  tcp_r="$(sysctl_get net.ipv4.tcp_rmem)"
  tcp_w="$(sysctl_get net.ipv4.tcp_wmem)"
  tcp_r_max="$(awk '{print $3}' <<<"$tcp_r")"
  tcp_w_max="$(awk '{print $3}' <<<"$tcp_w")"
  max_int "$core_r" "$core_w" "$tcp_r_max" "$tcp_w_max"
}

adjust_for_existing_buffers() {
  (( ALLOW_BUFFER_SHRINK )) && return 0
  [[ "$(uname -s)" == "Linux" ]] || return 0
  have sysctl || return 0
  local current_max
  current_max="$(current_buffer_max)"
  if [[ "$current_max" =~ ^[0-9]+$ ]] && (( current_max > BUFFER_BYTES )); then
    BUFFER_BYTES="$current_max"
    EFFECTIVE_BUFFER_MIB="$(awk -v b="$BUFFER_BYTES" 'BEGIN { printf "%.2f\n", b/1048576 }')"
  fi
}

read_tcp_vector_or_default() {
  local key="$1" fallback="$2" value
  value="$(sysctl_get "$key")"
  if [[ "$value" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

build_sysctl_content() {
  local rvec wvec rmin rdef wmin wdef
  rvec="$(read_tcp_vector_or_default net.ipv4.tcp_rmem '4096 131072 6291456')"
  wvec="$(read_tcp_vector_or_default net.ipv4.tcp_wmem '4096 16384 4194304')"
  read -r rmin rdef _ <<<"$rvec"
  read -r wmin wdef _ <<<"$wvec"

  cat <<EOF_SYSCTL
# Managed by bbr-tune.sh ${VERSION}; generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Profile=${RESOLVED_PROFILE}, bandwidth=${BANDWIDTH_MBPS}Mbps, RTT=${RTT_MS}ms, BDP=${BDP_MIB}MiB
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = ${BUFFER_BYTES}
net.core.wmem_max = ${BUFFER_BYTES}
net.ipv4.tcp_rmem = ${rmin} ${rdef} ${BUFFER_BYTES}
net.ipv4.tcp_wmem = ${wmin} ${wdef} ${BUFFER_BYTES}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
EOF_SYSCTL
}

profile_description() {
  case "$RESOLVED_PROFILE" in
    balanced) printf '%s' "短/中 RTT 通用：BBR + fq，缓冲区按 BDP 计算" ;;
    hard-cap) printf '%s' "外部硬限速：本机 TBF 整形至硬上限的 ${HEADROOM_PERCENT}%，子 qdisc 使用 fq" ;;
    qos) printf '%s' "单流 QoS：内核保持 BBR/fq；总吞吐需依赖业务层 8~16 并发" ;;
    lfn) printf '%s' "长肥管道：按 BDP 扩充自动调优上限，保持 fq pacing" ;;
    lossy) printf '%s' "随机丢包/抖动：BBR + fq + SACK/DSACK；不激进缩短连接超时" ;;
  esac
}

print_plan() {
  calculate_plan
  adjust_for_existing_buffers

  local iface_display="$IFACE"
  if [[ "$IFACE" == "auto" && "$(uname -s)" == "Linux" ]] && have ip; then
    iface_display="$(resolve_iface)"
  fi

  cat <<EOF_PLAN
=== BBR TCP 调优计划 ===
resolved_profile=${RESOLVED_PROFILE}
说明：$(profile_description)
出口网卡：${iface_display}
目标带宽：${BANDWIDTH_MBPS} Mbps
基准 RTT：${RTT_MS} ms
BDP：${BDP_BYTES} bytes (${BDP_MIB} MiB)
缓冲系数：${BUFFER_FACTOR}
推荐缓冲上限：${RECOMMENDED_BUFFER_MIB} MiB
实际拟用缓冲上限：${EFFECTIVE_BUFFER_MIB} MiB (${BUFFER_BYTES} bytes)
持久化：$([[ "$PERSIST" == "1" ]] && echo yes || echo no)
EOF_PLAN

  if [[ "$RESOLVED_PROFILE" == "hard-cap" ]]; then
    cat <<EOF_HARD
硬上限：${CAP_MBPS:-$BANDWIDTH_MBPS} Mbps
整形速率：${SHAPER_MBPS} Mbps
TBF burst：${TBF_BURST_BYTES} bytes
qdisc：tbf(root) -> fq(parent 1:1)
EOF_HARD
  else
    cat <<'EOF_FQ'
qdisc：fq（多队列网卡保留 mq，并将各 TX 队列叶子替换为 fq）
EOF_FQ
  fi

  cat <<'EOF_NOTES'

安全策略：
- 默认不降低系统现有 socket buffer 上限；buffer 是容量上限，不是可靠限速器。
- 不修改 tcp_retries2、tcp_pacing_*、netdev_max_backlog、tcp_max_syn_backlog。
- apply 前备份受管文件、关键 sysctl 和 qdisc 文本快照。
EOF_NOTES

  if [[ "$RESOLVED_PROFILE" == "qos" ]]; then
    cat <<'EOF_QOS'
- 单流 QoS 无法靠 sysctl 绕过；大文件工具建议从 8 流开始，再对比 16 流。
EOF_QOS
  fi
  if (( RECOMMENDED_BUFFER_MIB >= BUFFER_MAX_MIB )); then
    warn "缓冲区计算触及 --buffer-max-mib=${BUFFER_MAX_MIB}；请核对目标带宽/RTT和并发内存预算"
  fi
  if [[ "$ALLOW_BUFFER_SHRINK" == "1" ]]; then
    warn "已允许降低全局 socket buffer 上限，可能影响其他高 BDP 连接"
  fi
}

guess_server_address() {
  if [[ -n "$SERVER_ADDRESS" ]]; then
    printf '%s\n' "$SERVER_ADDRESS"
    return
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{print $3}' <<<"$SSH_CONNECTION"
    return
  fi
  local src
  src="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ -n "$src" ]]; then
    printf '%s\n' "$src"
  else
    printf '%s\n' '<服务器公网IP或域名>'
  fi
}

print_client_iperf_commands() {
  local address="$1" port="$2"
  cat <<EOF_CLIENT

=== 请在本地客户端执行，不要在远程服务器执行 ===
单流回程（服务器 -> 客户端）：
  iperf3 -c ${address} -p ${port} -R -t 20 -i 1

8 流回程：
  iperf3 -c ${address} -p ${port} -R -P 8 -t 20 -i 1

16 流回程：
  iperf3 -c ${address} -p ${port} -R -P 16 -t 20 -i 1

正向上传（客户端 -> 服务器，可选）：
  iperf3 -c ${address} -p ${port} -t 20 -i 1
EOF_CLIENT
}

iperf_server_pid() {
  [[ -r "$IPERF_PID_FILE" ]] || return 1
  local pid
  read -r pid <"$IPERF_PID_FILE"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -r "/proc/${pid}/comm" ]]; then
    grep -qx 'iperf3' "/proc/${pid}/comm" || return 1
  fi
  printf '%s\n' "$pid"
}

current_iperf_port() {
  local port=""
  if iperf_server_pid >/dev/null 2>&1 && [[ -r "$IPERF_PORT_FILE" ]]; then
    read -r port <"$IPERF_PORT_FILE"
  fi
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$port"
  else
    printf '%s\n' "$IPERF_PORT"
  fi
}

install_iperf3_if_needed() {
  have iperf3 && return 0
  require_root
  info "未检测到 iperf3，正在根据服务器发行版自动安装"

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
    pacman -Sy --noconfirm iperf3
  else
    die "无法识别服务器包管理器，请手动安装 iperf3 后重试"
  fi

  have iperf3 || die "已调用包管理器，但仍未找到 iperf3"
  info "iperf3 安装完成：$(iperf3 --version 2>/dev/null | head -1)"
}

port_is_free() {
  local port="$1" listeners
  listeners="$(ss -H -ltn 2>/dev/null)" || die "无法读取服务器 TCP 监听端口"
  if awk -v target="$port" '{
    local_addr=$4
    sub(/^.*:/, "", local_addr)
    if (local_addr == target) found=1
  } END {exit !found}' <<<"$listeners"; then
    return 1
  fi
  return 0
}

choose_random_free_port() {
  local port attempt
  for ((attempt=1; attempt<=200; attempt++)); do
    port=$((20000 + (((RANDOM << 15) | RANDOM) % 40000)))
    if port_is_free "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  die "尝试 200 次后仍无法找到未占用的随机 TCP 端口"
}

iperf_server_start() {
  require_linux
  require_root
  require_cmds ss nohup grep
  install_iperf3_if_needed
  local pid address active_port
  mkdir -p "$IPERF_RUN_DIR"
  chmod 0755 "$IPERF_RUN_DIR"

  if pid="$(iperf_server_pid 2>/dev/null)"; then
    active_port="$(current_iperf_port)"
    info "iperf3 服务端已经运行，PID=${pid}，端口=${active_port}"
    address="$(guess_server_address)"
    print_client_iperf_commands "$address" "$active_port"
    return 0
  fi
  rm -f "$IPERF_PID_FILE" "$IPERF_PORT_FILE"
  if (( IPERF_PORT == 0 )); then
    IPERF_PORT="$(choose_random_free_port)"
    info "已自动选择未占用的随机端口：${IPERF_PORT}"
  fi

  if ! port_is_free "$IPERF_PORT"; then
    die "TCP ${IPERF_PORT} 端口已被占用；请更换 --iperf-port 或检查现有服务"
  fi

  : >"$IPERF_LOG_FILE"
  nohup iperf3 -s -p "$IPERF_PORT" >"$IPERF_LOG_FILE" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" >"$IPERF_PID_FILE"
  printf '%s\n' "$IPERF_PORT" >"$IPERF_PORT_FILE"
  chmod 0644 "$IPERF_PID_FILE" "$IPERF_PORT_FILE" "$IPERF_LOG_FILE"
  sleep 1
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$IPERF_LOG_FILE" >&2 || true
    rm -f "$IPERF_PID_FILE" "$IPERF_PORT_FILE"
    die "iperf3 服务端启动失败"
  fi

  address="$(guess_server_address)"
  info "iperf3 服务端已启动：0.0.0.0:${IPERF_PORT}，PID=${pid}"
  warn "请确认云安全组和防火墙允许 TCP ${IPERF_PORT}；脚本不会自动开放防火墙"
  print_client_iperf_commands "$address" "$IPERF_PORT"
}

iperf_server_status() {
  require_linux
  local pid address active_port
  address="$(guess_server_address)"
  if pid="$(iperf_server_pid 2>/dev/null)"; then
    active_port="$(current_iperf_port)"
    printf 'iperf3_status=running\niperf3_pid=%s\niperf3_port=%s\n' "$pid" "$active_port"
    have ss && ss -ltnp 2>/dev/null | awk -v p=":${active_port}" '$4 ~ p"$" {print}' || true
    print_client_iperf_commands "$address" "$active_port"
  else
    printf 'iperf3_status=stopped\n'
    info "请运行 iperf-start；脚本会自动安装 iperf3 并随机选择空闲端口"
  fi
}

iperf_server_stop() {
  require_linux
  require_root
  local pid i
  if ! pid="$(iperf_server_pid 2>/dev/null)"; then
    rm -f "$IPERF_PID_FILE" "$IPERF_PORT_FILE"
    info "没有由本脚本启动的 iperf3 服务端"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for i in {1..20}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$IPERF_PID_FILE" "$IPERF_PORT_FILE"
  info "iperf3 服务端已停止"
}

probe() {
  require_linux
  require_cmds ip sysctl tc uname awk
  install_iperf3_if_needed
  [[ -z "$IPERF_SERVER" ]] || die "--iperf-server 已停用：远程服务器应运行 iperf3 -s；请在本地客户端执行 iperf3 -c ... -R"
  local iface
  iface="$(resolve_iface)"

  log "=== 远程服务器系统与 TCP 基线 ==="
  printf '时间: %s\n' "$(date -Is)"
  printf '内核: %s\n' "$(uname -srmo)"
  printf '出口网卡: %s\n' "$iface"
  printf '默认路由: '
  ip -o route get 1.1.1.1 2>/dev/null || true
  printf '建议客户端连接地址: %s\n' "$(guess_server_address)"
  printf '可用拥塞算法: %s\n' "$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  printf '当前拥塞算法: %s\n' "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '默认 qdisc: %s\n' "$(sysctl_get net.core.default_qdisc)"
  printf 'tcp_rmem: %s\n' "$(sysctl_get net.ipv4.tcp_rmem)"
  printf 'tcp_wmem: %s\n' "$(sysctl_get net.ipv4.tcp_wmem)"
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    printf '当前 SSH 会话: %s\n' "$SSH_CONNECTION"
  fi

  log ""
  log "=== 服务器出口 qdisc ==="
  tc -s -d qdisc show dev "$iface" || true

  if have nstat; then
    log ""
    log "=== 服务器 TCP 重传/丢包累计计数器 ==="
    nstat -az 2>/dev/null | awk '/TcpRetransSegs|TcpExtTCPTimeouts|TcpExtTCPLoss|TcpExtTCPSackRecovery|TcpExtTCPDSACKRecv/ {print}' || true
  fi

  if [[ -n "$TARGET" ]]; then
    have ping || die "指定了 --target，但系统缺少 ping"
    log ""
    log "=== 从服务器到外部目标的出口诊断：${TARGET} ==="
    ping -c "$PING_COUNT" -W 2 "$TARGET" || warn "ping 未完全成功；ICMP 可能被过滤"
  fi

  if iperf_server_pid >/dev/null 2>&1; then
    log ""
    log "iperf3 服务端状态：running"
    print_client_iperf_commands "$(guess_server_address)" "$(current_iperf_port)"
  else
    log ""
    log "iperf3 服务端状态：stopped（启动时会自动选择随机空闲端口）"
  fi
}

root_qdisc_kind() {
  local iface="$1"
  tc qdisc show dev "$iface" 2>/dev/null | awk '$0 ~ / root / {print $2; exit}'
}

qdisc_is_safe_to_replace() {
  local kind="$1"
  case "$kind" in
    ""|noqueue|pfifo_fast|fq_codel|fq|mq) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_apply() {
  (( ASSUME_YES )) && return 0
  if [[ -t 0 ]]; then
    local answer
    read -r -p "以上操作会修改全局 TCP 参数和出口 qdisc，继续？[y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "用户取消"
  else
    die "非交互执行 apply/rollback 时必须显式添加 --yes"
  fi
}

backup_one_file() {
  local backup="$1" path="$2" tag="$3"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a "$path" "${backup}/${tag}.file"
    printf '%s\tpresent\t%s\n' "$tag" "$path" >>"${backup}/files.tsv"
  else
    printf '%s\tabsent\t%s\n' "$tag" "$path" >>"${backup}/files.tsv"
  fi
}

create_backup() {
  local iface="$1" backup stamp key value
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$backup"
  : >"${backup}/files.tsv"

  backup_one_file "$backup" "$SYSCTL_FILE" sysctl
  backup_one_file "$backup" "$MODULES_FILE" modules
  backup_one_file "$backup" "$ENV_FILE" env
  backup_one_file "$backup" "$QDISC_HELPER" helper
  backup_one_file "$backup" "$SERVICE_FILE" service

  local service_enabled="unknown" service_active="unknown"
  if have systemctl; then
    service_enabled="$(systemctl is-enabled bbr-tcp-tuning.service 2>/dev/null || true)"
    service_active="$(systemctl is-active bbr-tcp-tuning.service 2>/dev/null || true)"
  fi
  cat >"${backup}/meta.env" <<EOF_META
IFACE=$(printf '%q' "$iface")
ROOT_QDISC_KIND=$(printf '%q' "$(root_qdisc_kind "$iface")")
SERVICE_ENABLED=$(printf '%q' "$service_enabled")
SERVICE_ACTIVE=$(printf '%q' "$service_active")
CREATED_AT=$(printf '%q' "$(date -Is)")
EOF_META
  tc -s -d qdisc show dev "$iface" >"${backup}/qdisc.txt" 2>&1 || true
  : >"${backup}/sysctl.tsv"
  for key in \
    net.core.default_qdisc \
    net.ipv4.tcp_congestion_control \
    net.core.rmem_max \
    net.core.wmem_max \
    net.ipv4.tcp_rmem \
    net.ipv4.tcp_wmem \
    net.ipv4.tcp_moderate_rcvbuf \
    net.ipv4.tcp_sack \
    net.ipv4.tcp_dsack \
    net.ipv4.tcp_window_scaling; do
    value="$(sysctl_get "$key")"
    [[ -n "$value" ]] && printf '%s\t%s\n' "$key" "$value" >>"${backup}/sysctl.tsv"
  done

  ln -sfn "$backup" "$LATEST_LINK"
  printf '%s\n' "$backup"
}

atomic_write() {
  local path="$1" mode="$2" tmp
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
}

write_persistent_files() {
  local iface="$1"

  mkdir -p "$(dirname "$SYSCTL_FILE")" "$(dirname "$MODULES_FILE")" \
    "$(dirname "$ENV_FILE")" "$(dirname "$QDISC_HELPER")" "$(dirname "$SERVICE_FILE")"
  # SYSCTL_FILE 已由 apply_sysctls_runtime 写入，并过滤了当前内核不支持的键。
  cat <<'EOF_MODULES' | atomic_write "$MODULES_FILE" 0644
# Managed by bbr-tune.sh
tcp_bbr
sch_fq
sch_tbf
EOF_MODULES

  cat <<EOF_ENV | atomic_write "$ENV_FILE" 0644
# Managed by bbr-tune.sh
BBR_IFACE=$(printf '%q' "$iface")
BBR_PROFILE=$(printf '%q' "$RESOLVED_PROFILE")
BBR_SHAPER_MBPS=$(printf '%q' "$SHAPER_MBPS")
BBR_TBF_BURST_BYTES=$(printf '%q' "$TBF_BURST_BYTES")
EOF_ENV

  cat <<'EOF_HELPER' | atomic_write "$QDISC_HELPER" 0755
#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE=/etc/default/bbr-tcp-tuning
[[ -r "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1091
source "$ENV_FILE"

resolve_iface() {
  if [[ "${BBR_IFACE:-auto}" != "auto" ]]; then
    printf '%s\n' "$BBR_IFACE"
  else
    ip -o route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
  fi
}

apply_fq() {
  local iface="$1" root parents parent
  root="$(tc qdisc show dev "$iface" | awk '$0 ~ / root / {print $2; exit}')"
  if [[ "$root" == "mq" ]]; then
    parents="$(tc qdisc show dev "$iface" | awk '{for (i=1; i<=NF; i++) if ($i=="parent" && $(i+1) ~ /^:/) print $(i+1)}' | sort -u)"
    if [[ -n "$parents" ]]; then
      while read -r parent; do
        [[ -n "$parent" ]] && tc qdisc replace dev "$iface" parent "$parent" fq
      done <<<"$parents"
      return
    fi
  fi
  tc qdisc replace dev "$iface" root fq
}

start() {
  local iface="" attempt
  for ((attempt=1; attempt<=30; attempt++)); do
    iface="$(resolve_iface 2>/dev/null || true)"
    if [[ -n "$iface" ]] && ip link show dev "$iface" >/dev/null 2>&1; then
      break
    fi
    iface=""
    sleep 1
  done
  [[ -n "$iface" ]] || { echo "cannot resolve a ready interface after 30s" >&2; exit 1; }
  if [[ "$BBR_PROFILE" == "hard-cap" ]]; then
    tc qdisc replace dev "$iface" root handle 1: tbf \
      rate "${BBR_SHAPER_MBPS}mbit" burst "${BBR_TBF_BURST_BYTES}" latency 50ms
    tc qdisc replace dev "$iface" parent 1:1 handle 10: fq
  else
    apply_fq "$iface"
  fi
}

stop() {
  local iface
  iface="$(resolve_iface)"
  tc qdisc del dev "$iface" root 2>/dev/null || true
}

case "${1:-start}" in
  start|reload) start ;;
  stop) stop ;;
  *) echo "usage: $0 {start|reload|stop}" >&2; exit 2 ;;
esac
EOF_HELPER

  cat <<'EOF_SERVICE' | atomic_write "$SERVICE_FILE" 0644
[Unit]
Description=BBR TCP tuning and egress qdisc
Wants=network-online.target
After=network-online.target
ConditionPathExists=/etc/default/bbr-tcp-tuning

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bbr-tcp-qdisc start
ExecReload=/usr/local/sbin/bbr-tcp-qdisc reload

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

ensure_bbr_available() {
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
  [[ "$RESOLVED_PROFILE" == "hard-cap" ]] && modprobe sch_tbf 2>/dev/null || true

  local available
  available="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  [[ " $available " == *" bbr "* ]] || die "当前内核未提供 bbr；未做修改。请安装发行版支持 BBR 的内核后重试"
}

apply_sysctls_runtime() {
  local raw filtered line key
  raw="$(mktemp)"
  filtered="$(mktemp)"
  build_sysctl_content >"$raw"

  # 只保留当前内核真实存在的键，避免跨内核版本因单个未知键导致整个加载失败。
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
      warn "跳过当前内核不存在的 sysctl：$key"
      printf '# unsupported on this kernel: %s\n' "$line" >>"$filtered"
    fi
  done <"$raw"

  sysctl -p "$filtered"
  if (( PERSIST )); then
    atomic_write "$SYSCTL_FILE" 0644 <"$filtered"
  fi
  rm -f "$raw" "$filtered"
}

apply_qdisc_runtime() {
  local iface="$1"
  BBR_IFACE="$iface" \
  BBR_PROFILE="$RESOLVED_PROFILE" \
  BBR_SHAPER_MBPS="$SHAPER_MBPS" \
  BBR_TBF_BURST_BYTES="$TBF_BURST_BYTES" \
  bash -c '
    set -Eeuo pipefail
    iface="$BBR_IFACE"
    if [[ "$BBR_PROFILE" == "hard-cap" ]]; then
      tc qdisc replace dev "$iface" root handle 1: tbf rate "${BBR_SHAPER_MBPS}mbit" burst "${BBR_TBF_BURST_BYTES}" latency 50ms
      tc qdisc replace dev "$iface" parent 1:1 handle 10: fq
    else
      root="$(tc qdisc show dev "$iface" | awk '\''$0 ~ / root / {print $2; exit}'\'')"
      if [[ "$root" == "mq" ]]; then
        parents="$(tc qdisc show dev "$iface" | awk '\''{for (i=1; i<=NF; i++) if ($i=="parent" && $(i+1) ~ /^:/) print $(i+1)}'\'' | sort -u)"
        if [[ -n "$parents" ]]; then
          while read -r parent; do [[ -n "$parent" ]] && tc qdisc replace dev "$iface" parent "$parent" fq; done <<<"$parents"
          exit 0
        fi
      fi
      tc qdisc replace dev "$iface" root fq
    fi
  '
}

pending_rollback_dir() {
  local backup="$1"
  printf '%s/%s\n' "$PENDING_DIR" "$(basename "$backup")"
}

schedule_remote_rollback() {
  local backup="$1"
  (( AUTO_ROLLBACK_SECONDS > 0 )) || return 0
  local pending unit pid
  pending="$(pending_rollback_dir "$backup")"
  mkdir -p "$pending"
  printf '%s\n' "$backup" >"${pending}/backup"
  : >"${pending}/armed"

  if have systemd-run && have systemctl && systemctl is-system-running >/dev/null 2>&1; then
    unit="bbr-tcp-rollback-$(date +%s)-$$"
    systemd-run --quiet --unit "$unit" --on-active="${AUTO_ROLLBACK_SECONDS}s" \
      /usr/bin/env BBR_AUTO_ROLLBACK=1 /bin/bash "$SCRIPT_PATH" rollback --backup "$backup" --yes
    cat >"${pending}/timer.env" <<EOF_TIMER
TIMER_TYPE=systemd
TIMER_ID=$(printf '%q' "$unit")
EOF_TIMER
  else
    nohup /bin/bash -c '
      seconds="$1"; marker="$2"; script="$3"; backup="$4"; log_file="$5"
      sleep "$seconds"
      [[ -f "$marker" ]] || exit 0
      BBR_AUTO_ROLLBACK=1 /bin/bash "$script" rollback --backup "$backup" --yes >>"$log_file" 2>&1
    ' _ "$AUTO_ROLLBACK_SECONDS" "${pending}/armed" "$SCRIPT_PATH" "$backup" "${pending}/rollback.log" \
      >/dev/null 2>&1 &
    pid=$!
    cat >"${pending}/timer.env" <<EOF_TIMER
TIMER_TYPE=process
TIMER_ID=$(printf '%q' "$pid")
EOF_TIMER
  fi
  ln -sfn "$pending" "$PENDING_LATEST"
  warn "已设置 ${AUTO_ROLLBACK_SECONDS} 秒 SSH 安全回滚。确认连接正常后执行：sudo $PROGRAM confirm"
}

cancel_pending_for_backup() {
  local backup="$1" pending type="" id=""
  pending="$(pending_rollback_dir "$backup")"
  [[ -d "$pending" ]] || return 0
  if [[ -r "${pending}/timer.env" ]]; then
    local TIMER_TYPE="" TIMER_ID=""
    # shellcheck disable=SC1090
    source "${pending}/timer.env"
    type="$TIMER_TYPE"; id="$TIMER_ID"
  fi
  rm -f "${pending}/armed"
  if [[ "${BBR_AUTO_ROLLBACK:-0}" != "1" ]]; then
    case "$type" in
      systemd)
        systemctl stop "${id}.timer" "${id}.service" >/dev/null 2>&1 || true
        systemctl reset-failed "${id}.service" >/dev/null 2>&1 || true
        ;;
      process)
        if [[ "$id" =~ ^[0-9]+$ ]]; then
          kill "$id" 2>/dev/null || true
          wait "$id" 2>/dev/null || true
        fi
        ;;
    esac
  fi
  local recorded pending_real
  recorded="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  pending_real="$(readlink -f "$pending" 2>/dev/null || printf '%s' "$pending")"
  rm -rf "$pending"
  if [[ "$recorded" == "$pending_real" ]]; then
    rm -f "$PENDING_LATEST"
  fi
  return 0
}

cancel_pending_rollback() {
  require_linux
  require_root
  local pending backup
  pending="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  if [[ -z "$pending" || ! -d "$pending" ]]; then
    info "当前没有待确认的自动回滚"
    return 0
  fi
  backup="$(cat "${pending}/backup" 2>/dev/null || true)"
  [[ -n "$backup" ]] || die "待确认状态缺少备份路径：$pending"
  cancel_pending_for_backup "$backup"
  info "已确认 SSH 连接正常，自动回滚已取消"
}

pending_rollback_guard() {
  local pending
  pending="$(readlink -f "$PENDING_LATEST" 2>/dev/null || true)"
  if [[ -n "$pending" && -f "${pending}/armed" ]]; then
    die "存在尚未确认的远程变更：$pending。请先执行 '$PROGRAM confirm'，或等待/执行回滚"
  fi
}

parse_iperf_server_json() {
  local json_file="$1" values bps bytes retrans error_text

  # 不额外安装 jq：优先使用服务器已有的 Python 3，否则解析 iperf3 -J 的
  # 稳定 pretty-print 结构。这样除用户明确要求的 iperf3 外不安装其他软件包。
  if have python3; then
    values="$(python3 - "$json_file" <<'PY_JSON'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    sent = data["end"]["sum_sent"]
    print(f'{sent.get("bits_per_second", 0)}\t{sent.get("bytes", 0)}\t{sent.get("retransmits", 0)}')
except Exception as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
PY_JSON
)" || return 1
  else
    values="$(awk '
      /"sum_sent"[[:space:]]*:/ { in_sum=1; next }
      in_sum && /"bits_per_second"[[:space:]]*:/ {
        v=$0; sub(/^.*:[[:space:]]*/, "", v); sub(/,[[:space:]]*$/, "", v); bps=v
      }
      in_sum && /"bytes"[[:space:]]*:/ {
        v=$0; sub(/^.*:[[:space:]]*/, "", v); sub(/,[[:space:]]*$/, "", v); bytes=v
      }
      in_sum && /"retransmits"[[:space:]]*:/ {
        v=$0; sub(/^.*:[[:space:]]*/, "", v); sub(/,[[:space:]]*$/, "", v); retrans=v
      }
      in_sum && /^[[:space:]]*}/ {
        if (bps != "") {
          if (bytes == "") bytes=0
          if (retrans == "") retrans=0
          print bps "\t" bytes "\t" retrans
          exit
        }
      }
    ' "$json_file")"
  fi

  if [[ -z "$values" ]]; then
    error_text="$(awk '
      /"error"[[:space:]]*:/ {
        v=$0; sub(/^.*:[[:space:]]*/, "", v); sub(/,[[:space:]]*$/, "", v); gsub(/^"|"$/, "", v); print v; exit
      }
    ' "$json_file")"
    [[ -n "$error_text" ]] && warn "iperf3：${error_text}"
    warn "iperf3 JSON 中没有有效的 end.sum_sent 测试结果"
    return 1
  fi

  IFS=$'\t' read -r bps bytes retrans <<<"$values"
  is_number "$bps" && is_number "$bytes" && is_number "$retrans" || {
    warn "iperf3 JSON 测试结果不是有效数字"
    return 1
  }
  TEST_RESULT_MBPS="$(awk -v v="$bps" 'BEGIN {printf "%.2f", v/1000000}')"
  TEST_RESULT_BYTES="$(awk -v v="$bytes" 'BEGIN {printf "%.0f", v}')"
  TEST_RESULT_RETRANS="$(awk -v v="$retrans" 'BEGIN {printf "%.0f", v}')"
  TEST_RESULT_RETRANS_PERCENT="$(awk -v r="$TEST_RESULT_RETRANS" -v b="$TEST_RESULT_BYTES" \
    'BEGIN {if (b<=0) print "100.0000"; else printf "%.4f", r*1448/b*100}')"
}

abort_current_test_signal() {
  trap - INT TERM
  set +e
  if [[ -n "$CURRENT_TEST_PID" ]]; then
    kill "$CURRENT_TEST_PID" 2>/dev/null || true
    wait "$CURRENT_TEST_PID" 2>/dev/null || true
    CURRENT_TEST_PID=""
  fi
  warn "收到中断信号，已停止服务器端临时 iperf3 测试；尚未修改 BBR 参数"
  exit 130
}

run_reverse_test() {
  local session_dir="$1" label="$2" address="$3" port="$4" streams="$5" duration="$6" wait_seconds="$7"
  local json_file="${session_dir}/${label}.json" err_file="${session_dir}/${label}.err"
  local elapsed=0 rc=0

  port_is_free "$port" || die "测试端口 ${port} 当前被占用"
  : >"$json_file"
  : >"$err_file"
  iperf3 -s -1 -J -p "$port" >"$json_file" 2>"$err_file" &
  CURRENT_TEST_PID=$!
  sleep 1
  kill -0 "$CURRENT_TEST_PID" 2>/dev/null || {
    cat "$err_file" >&2 || true
    CURRENT_TEST_PID=""
    die "iperf3 一次性服务端启动失败"
  }

  cat <<EOF_TEST

================================================================
服务器已等待第 ${label} 次本地测试，随机端口：${port}
请在你的本地电脑执行以下命令；脚本不会修改本地任何参数：

  iperf3 -c ${address} -p ${port} -R -P ${streams} -t ${duration} -i 1

如果无法连接，请检查云安全组和服务器防火墙是否允许 TCP ${port}。
服务器最多等待 ${wait_seconds} 秒。
================================================================
EOF_TEST

  while kill -0 "$CURRENT_TEST_PID" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if (( elapsed % 15 == 0 )); then
      info "仍在等待本地客户端连接或测试完成，已等待 ${elapsed}s"
    fi
    if (( elapsed >= wait_seconds )); then
      kill "$CURRENT_TEST_PID" 2>/dev/null || true
      wait "$CURRENT_TEST_PID" 2>/dev/null || true
      CURRENT_TEST_PID=""
      warn "等待本地客户端测试超时"
      return 124
    fi
  done

  set +e
  wait "$CURRENT_TEST_PID"
  rc=$?
  set -e
  CURRENT_TEST_PID=""
  if (( rc != 0 )); then
    cat "$err_file" >&2 || true
    return "$rc"
  fi
  parse_iperf_server_json "$json_file"
  printf '测试结果：吞吐=%s Mbps，Retr=%s，估算重传比例=%s%%\n' \
    "$TEST_RESULT_MBPS" "$TEST_RESULT_RETRANS" "$TEST_RESULT_RETRANS_PERCENT"
}

test_result_speed_low() {
  local min_mbps
  min_mbps="$(awk -v bw="$BANDWIDTH_MBPS" -v p="$TARGET_UTILIZATION" 'BEGIN {printf "%.4f", bw*p/100}')"
  awk -v speed="$TEST_RESULT_MBPS" -v min="$min_mbps" 'BEGIN {exit !(speed < min)}'
}

test_result_retrans_high() {
  awk -v retrans="$TEST_RESULT_RETRANS_PERCENT" -v maxr="$MAX_RETRANS_PERCENT" \
    'BEGIN {exit !(retrans > maxr)}'
}

test_result_meets_target() {
  ! test_result_speed_low && ! test_result_retrans_high
}

next_parallel_stream_count() {
  local current="$1"
  if (( current < 8 )); then
    printf '8\n'
  elif (( current < 16 )); then
    printf '16\n'
  else
    printf '%s\n' "$current"
  fi
}

increase_test_parallelism() {
  local next
  next="$(next_parallel_stream_count "$PARALLEL_STREAMS")"
  [[ "$next" != "$PARALLEL_STREAMS" ]] || return 1
  PARALLEL_STREAMS="$next"
  AUTOTUNE_MULTIFLOW="1"
  if [[ "$RESOLVED_PROFILE" != "hard-cap" ]]; then
    PROFILE="qos"
    SYMPTOM="single-flow-qos"
    RESOLVED_PROFILE="qos"
  fi
  return 0
}

next_buffer_factor() {
  awk -v f="$1" 'BEGIN {
    if (f < 1.5) print "2.0";
    else if (f < 2.5) print "3.0";
    else if (f < 4.0) print "4.0";
    else print f;
  }'
}

increase_effective_buffer_factor() {
  local old_factor="$BUFFER_FACTOR" old_bytes="$BUFFER_BYTES" candidate

  while true; do
    candidate="$(next_buffer_factor "$BUFFER_FACTOR")"
    if [[ "$candidate" == "$BUFFER_FACTOR" ]]; then
      BUFFER_FACTOR="$old_factor"
      calculate_plan
      adjust_for_existing_buffers
      return 1
    fi

    BUFFER_FACTOR="$candidate"
    calculate_plan
    adjust_for_existing_buffers
    if (( BUFFER_BYTES > old_bytes )); then
      return 0
    fi
  done
}

minimum_headroom_percent() {
  awk -v target="$TARGET_UTILIZATION" 'BEGIN {
    floor=int(target + 2.999999);
    target_ceil=int(target); if (target_ceil < target) target_ceil++;
    if (floor > 98) floor=98;
    if (floor < target_ceil) floor=target_ceil;
    if (floor > 99) floor=99;
    printf "%.0f", floor;
  }'
}

configure_hard_cap_candidate() {
  local floor
  PROFILE="hard-cap"
  SYMPTOM="hard-cap"
  [[ -n "$CAP_MBPS" ]] || CAP_MBPS="$BANDWIDTH_MBPS"
  floor="$(minimum_headroom_percent)"
  if awk -v h="$HEADROOM_PERCENT" -v f="$floor" 'BEGIN {exit !(h < f)}'; then
    HEADROOM_PERCENT="$floor"
  fi
}

prepare_initial_autotune_candidate() {
  if test_result_retrans_high; then
    configure_hard_cap_candidate
    info "基线重传高于 ${MAX_RETRANS_PERCENT}%：首轮启用服务器端 TBF 预整形（${HEADROOM_PERCENT}%）+ BBR/fq"
  elif test_result_speed_low; then
    info "基线重传可接受但吞吐不足：首轮按 RTT/BDP 应用 BBR/fq 与缓冲区方案"
  fi
}

adjust_autotune_candidate() {
  local floor new_headroom previous_factor new_factor

  if test_result_retrans_high; then
    if [[ "$RESOLVED_PROFILE" != "hard-cap" ]]; then
      configure_hard_cap_candidate
      info "重传仍偏高：下一轮切换为服务器端 hard-cap 预整形，比例 ${HEADROOM_PERCENT}%"
      return 0
    fi

    floor="$(minimum_headroom_percent)"
    new_headroom="$(awk -v h="$HEADROOM_PERCENT" -v floor="$floor" \
      'BEGIN {n=int(h-3); if(n<floor)n=floor; printf "%.0f", n}')"
    if awk -v old="$HEADROOM_PERCENT" -v new="$new_headroom" 'BEGIN {exit !(new < old)}'; then
      HEADROOM_PERCENT="$new_headroom"
      info "重传仍偏高：下一轮把服务器 TBF 整形比例降至 ${HEADROOM_PERCENT}%"
      return 0
    fi

    warn "重传仍高于阈值，但整形比例已到 ${floor}% 安全下限；继续降低将无法满足目标吞吐"
    return 1
  fi

  if test_result_speed_low; then
    if increase_test_parallelism; then
      info "重传很低但单流/少量流吞吐不足：下一轮改用 ${PARALLEL_STREAMS} 个并发流判断是否存在运营商单流 QoS"
      return 0
    fi

    previous_factor="$BUFFER_FACTOR"
    if increase_effective_buffer_factor; then
      new_factor="$BUFFER_FACTOR"
      info "16 流总吞吐仍未达标：下一轮把服务器 BDP 缓冲系数从 ${previous_factor} 提高至 ${new_factor}（buffer=${BUFFER_BYTES}）"
      return 0
    fi
    warn "16 流总吞吐仍未达标，且继续提高 BDP 系数不会增大当前有效缓冲上限"
  fi

  return 1
}

persist_current_tuning() {
  local iface="$1"
  have systemctl || die "系统没有 systemd，无法按本脚本方式持久化最终参数"
  PERSIST=1
  apply_sysctls_runtime
  write_persistent_files "$iface"
  systemctl daemon-reload
  systemctl enable bbr-tcp-tuning.service >/dev/null
  systemctl restart bbr-tcp-tuning.service
}

autotune_session() {
  require_linux
  require_root
  require_cmds ip tc sysctl modprobe awk mktemp ss grep
  pending_rollback_guard
  [[ -n "$BANDWIDTH_MBPS" && -n "$RTT_MS" ]] || die "autotune 需要 --bandwidth-mbps 和 --rtt-ms"
  install_iperf3_if_needed

  local iface address port session_dir report_file backup="" root_kind
  local round success=0 candidate_note
  local min_mbps
  iface="$(resolve_iface)"
  ip link show dev "$iface" >/dev/null 2>&1 || die "网卡不存在：$iface"
  address="$(guess_server_address)"
  port="$(choose_random_free_port)"
  session_dir="${STATE_DIR}/autotune/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$session_dir"
  report_file="${session_dir}/results.tsv"
  printf 'round\tprofile\tstreams\tbuffer_factor\theadroom\tbuffer_bytes\tmbps\tretrans\tretrans_percent\tpassed\n' >"$report_file"
  min_mbps="$(awk -v bw="$BANDWIDTH_MBPS" -v p="$TARGET_UTILIZATION" 'BEGIN {printf "%.2f", bw*p/100}')"

  cat <<EOF_SESSION
=== 服务器端自动闭环调优 ===
服务器地址：${address}
随机测试端口：${port}
目标带宽：${BANDWIDTH_MBPS} Mbps
达标吞吐：>= ${min_mbps} Mbps（${TARGET_UTILIZATION}%）
最大估算重传比例：${MAX_RETRANS_PERCENT}%
初始测试并发流：${PARALLEL_STREAMS}
最大调参轮数：${MAX_ITERATIONS}
结果目录：${session_dir}

注意：脚本只修改这台服务器。你的本地电脑只运行 iperf3 测试命令。
EOF_SESSION
  warn "请确保云安全组/服务器防火墙允许本次随机 TCP 端口 ${port}"

  info "先执行基线测试；基线达标时不会修改任何服务器参数"
  trap abort_current_test_signal INT TERM
  run_reverse_test "$session_dir" baseline "$address" "$port" "$PARALLEL_STREAMS" "$DURATION" "$TEST_WAIT_SECONDS"
  printf '0\tbaseline\t%s\t-\t-\t-\t%s\t%s\t%s\t%s\n' \
    "$PARALLEL_STREAMS" "$TEST_RESULT_MBPS" "$TEST_RESULT_RETRANS" "$TEST_RESULT_RETRANS_PERCENT" \
    "$(test_result_meets_target && echo yes || echo no)" >>"$report_file"

  if test_result_meets_target; then
    trap - INT TERM
    info "基线已经达到条件，无需修改服务器 BBR 参数"
    info "测试报告：$report_file"
    return 0
  fi

  prepare_initial_autotune_candidate
  calculate_plan
  adjust_for_existing_buffers
  ensure_bbr_available
  root_kind="$(root_qdisc_kind "$iface")"
  if ! qdisc_is_safe_to_replace "$root_kind" && (( ! FORCE )); then
    die "检测到自定义 root qdisc '${root_kind}'，自动调优拒绝覆盖；审计后可使用 --force"
  fi

  trap - INT TERM
  backup="$(create_backup "$iface")"
  info "自动调优基线备份：$backup"
  if (( AUTO_ROLLBACK_SECONDS == 0 )); then
    AUTO_ROLLBACK_SECONDS=$(( TEST_WAIT_SECONDS * (MAX_ITERATIONS + 1) + 600 ))
    (( AUTO_ROLLBACK_SECONDS > 86400 )) && AUTO_ROLLBACK_SECONDS=86400
  fi
  trap 'auto_rollback_on_error "$backup"' ERR
  trap 'auto_rollback_signal "$backup"' INT TERM
  schedule_remote_rollback "$backup"
  PERSIST=0

  for ((round=1; round<=MAX_ITERATIONS; round++)); do
    calculate_plan
    adjust_for_existing_buffers
    candidate_note="profile=${RESOLVED_PROFILE}, streams=${PARALLEL_STREAMS}, factor=${BUFFER_FACTOR}, buffer=${BUFFER_BYTES}, headroom=${HEADROOM_PERCENT}%"
    info "第 ${round}/${MAX_ITERATIONS} 轮应用服务器参数：${candidate_note}"
    apply_sysctls_runtime
    apply_qdisc_runtime "$iface"

    run_reverse_test "$session_dir" "round-${round}" "$address" "$port" "$PARALLEL_STREAMS" "$DURATION" "$TEST_WAIT_SECONDS"
    if test_result_meets_target; then
      success=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tyes\n' \
        "$round" "$RESOLVED_PROFILE" "$PARALLEL_STREAMS" "$BUFFER_FACTOR" "$HEADROOM_PERCENT" "$BUFFER_BYTES" \
        "$TEST_RESULT_MBPS" "$TEST_RESULT_RETRANS" "$TEST_RESULT_RETRANS_PERCENT" >>"$report_file"
      break
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tno\n' \
      "$round" "$RESOLVED_PROFILE" "$PARALLEL_STREAMS" "$BUFFER_FACTOR" "$HEADROOM_PERCENT" "$BUFFER_BYTES" \
      "$TEST_RESULT_MBPS" "$TEST_RESULT_RETRANS" "$TEST_RESULT_RETRANS_PERCENT" >>"$report_file"

    if ! adjust_autotune_candidate; then
      warn "已没有可继续安全自动调整的服务器参数，提前结束"
      break
    fi
  done

  if (( success == 0 )); then
    trap - ERR INT TERM
    warn "在最大轮数内未同时满足吞吐和重传条件，正在恢复服务器基线"
    warn "最后结果：${TEST_RESULT_MBPS} Mbps（要求 >= ${min_mbps} Mbps），估算重传 ${TEST_RESULT_RETRANS_PERCENT}%（要求 <= ${MAX_RETRANS_PERCENT}%），并发流 ${PARALLEL_STREAMS}"
    if (( PARALLEL_STREAMS >= 16 )) && ! test_result_retrans_high; then
      warn "16 流重传仍很低但总吞吐不足：请核对目标带宽；瓶颈很可能位于物理端口、云厂商/运营商限速或接收端，而不是服务器 TCP buffer"
    fi
    cancel_pending_for_backup "$backup"
    restore_backup_internal "$backup"
    info "测试报告：$report_file"
    return 2
  fi

  if (( PERSIST_ON_SUCCESS )); then
    info "测试达标，正在持久化最终服务器参数"
    persist_current_tuning "$iface"
  fi
  trap - ERR INT TERM
  info "自动调优达标：${TEST_RESULT_MBPS} Mbps，估算重传 ${TEST_RESULT_RETRANS_PERCENT}%，并发流 ${PARALLEL_STREAMS}"
  info "最终参数：profile=${RESOLVED_PROFILE}, factor=${BUFFER_FACTOR}, buffer=${BUFFER_BYTES}, headroom=${HEADROOM_PERCENT}%"
  if (( AUTOTUNE_MULTIFLOW )); then
    warn "本次达标依赖 ${PARALLEL_STREAMS} 个并发流；这通常表示单流受到沿途 QoS/策略限制，服务器 BBR 参数无法消除外部单流上限"
  fi
  info "测试报告：$report_file"
  warn "请另开 SSH 会话验证服务器；确认正常后执行：sudo $PROGRAM confirm"
}

apply_tuning() {
  require_linux
  require_root
  require_cmds ip tc sysctl modprobe awk mktemp
  pending_rollback_guard
  calculate_plan
  adjust_for_existing_buffers
  local iface root_kind backup
  iface="$(resolve_iface)"
  ip link show dev "$iface" >/dev/null 2>&1 || die "网卡不存在：$iface"

  ensure_bbr_available
  root_kind="$(root_qdisc_kind "$iface")"
  if ! qdisc_is_safe_to_replace "$root_kind" && (( ! FORCE )); then
    die "检测到自定义 root qdisc '${root_kind}'。为避免破坏现有 QoS，请先审计，或明确使用 --force"
  fi
  if [[ "$RESOLVED_PROFILE" == "hard-cap" ]] && awk -v r="$SHAPER_MBPS" 'BEGIN {exit !(r > 2000)}'; then
    warn "TBF 整形速率超过 2Gbps，单根 qdisc 可能成为 CPU 瓶颈；建议改用支持多队列/硬件卸载的方案"
  fi

  print_plan
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    warn "检测到当前通过 SSH 管理远程服务器；修改出口 qdisc 可能影响当前连接"
    if (( AUTO_ROLLBACK_SECONDS == 0 )); then
      warn "本次未启用 SSH 安全回滚。建议添加 --auto-rollback-seconds 300"
    fi
  fi
  confirm_apply
  backup="$(create_backup "$iface")"
  info "备份目录：$backup"
  trap 'auto_rollback_on_error "$backup"' ERR
  schedule_remote_rollback "$backup"

  apply_sysctls_runtime
  apply_qdisc_runtime "$iface"

  if (( PERSIST )); then
    have systemctl || die "运行时配置已应用，但系统没有 systemd，qdisc 无法按本脚本方式持久化；备份在 $backup"
    write_persistent_files "$iface"
    systemctl daemon-reload
    systemctl enable bbr-tcp-tuning.service >/dev/null
    systemctl restart bbr-tcp-tuning.service
  fi

  trap - ERR
  info "配置已应用。请在相同时段重复单流、8 流、16 流测试，并记录吞吐、Retr、RTT。"
  verify_tuning "$iface"
}

verify_tuning() {
  require_linux
  require_cmds sysctl tc ip
  local iface="${1:-}"
  [[ -n "$iface" ]] || iface="$(resolve_iface)"

  log "=== BBR/TCP 验证 ==="
  printf 'interface=%s\n' "$iface"
  printf 'available_cc=%s\n' "$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  printf 'active_cc=%s\n' "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf 'default_qdisc=%s\n' "$(sysctl_get net.core.default_qdisc)"
  printf 'tcp_rmem=%s\n' "$(sysctl_get net.ipv4.tcp_rmem)"
  printf 'tcp_wmem=%s\n' "$(sysctl_get net.ipv4.tcp_wmem)"
  printf 'sack=%s dsack=%s window_scaling=%s\n' \
    "$(sysctl_get net.ipv4.tcp_sack)" \
    "$(sysctl_get net.ipv4.tcp_dsack)" \
    "$(sysctl_get net.ipv4.tcp_window_scaling)"

  log ""
  log "=== qdisc 统计 ==="
  tc -s -d qdisc show dev "$iface" || true

  if have lsmod; then
    log ""
    lsmod | awk '$1=="tcp_bbr" || $1=="sch_fq" || $1=="sch_tbf" {print}' || true
  fi
  if have nstat; then
    log ""
    log "=== TCP 重传/超时计数器（累计值） ==="
    nstat -az 2>/dev/null | awk '/TcpRetransSegs|TcpExtTCPTimeouts|TcpExtTCPLoss|TcpExtTCPSackRecovery|TcpExtTCPDSACKRecv/ {print}' || true
  fi
  if have ss; then
    log ""
    log "=== 活跃 TCP 样本（最多 40 行） ==="
    ss -tin 2>/dev/null | head -40 || true
  fi
}

restore_managed_files() {
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

restore_qdisc_best_effort() {
  local backup="$1" iface="$2" kind="$3" parent leaf
  tc qdisc del dev "$iface" root 2>/dev/null || true
  case "$kind" in
    ""|noqueue|pfifo_fast)
      # 删除受管 root 后，让内核/驱动恢复默认。
      ;;
    mq)
      tc qdisc replace dev "$iface" root mq || return 0
      if [[ -r "${backup}/qdisc.txt" ]]; then
        while read -r leaf parent; do
          case "$leaf" in fq|fq_codel|pfifo_fast|sfq) tc qdisc replace dev "$iface" parent "$parent" "$leaf" 2>/dev/null || true ;; esac
        done < <(awk '{kind=$2; parent=""; for(i=1;i<=NF;i++) if($i=="parent") parent=$(i+1); if(parent ~ /^:/) print kind, parent}' "${backup}/qdisc.txt")
      fi
      ;;
    fq|fq_codel|sfq)
      tc qdisc replace dev "$iface" root "$kind" || true
      ;;
    *)
      warn "原 qdisc 类型 ${kind} 包含的参数/分类器无法通用重建；已移除本脚本 qdisc，请按 ${backup}/qdisc.txt 手工恢复"
      ;;
  esac
}

restore_backup_internal() {
  local backup="$1"
  local IFACE="" ROOT_QDISC_KIND="" SERVICE_ENABLED="unknown" SERVICE_ACTIVE="unknown"
  local iface kind key value

  # shellcheck disable=SC1090
  source "${backup}/meta.env"
  iface="$IFACE"
  kind="$ROOT_QDISC_KIND"
  [[ -n "$iface" ]] || { warn "备份中缺少 IFACE"; return 1; }

  if have systemctl; then
    systemctl disable --now bbr-tcp-tuning.service >/dev/null 2>&1 || true
  fi
  restore_managed_files "$backup"

  while IFS=$'\t' read -r key value; do
    [[ -n "$key" ]] || continue
    sysctl -w "${key}=${value}" >/dev/null || warn "无法恢复 sysctl：$key"
  done <"${backup}/sysctl.tsv"

  restore_qdisc_best_effort "$backup" "$iface" "$kind"
  if have systemctl; then
    systemctl daemon-reload || true
    if [[ -f "$SERVICE_FILE" ]]; then
      if [[ "$SERVICE_ENABLED" == "enabled" ]]; then
        systemctl enable bbr-tcp-tuning.service >/dev/null 2>&1 || warn "无法恢复服务 enabled 状态"
      else
        systemctl disable bbr-tcp-tuning.service >/dev/null 2>&1 || true
      fi
      if [[ "$SERVICE_ACTIVE" == "active" ]]; then
        systemctl start bbr-tcp-tuning.service >/dev/null 2>&1 || warn "原有同名服务恢复后未能自动启动，请检查"
      fi
    fi
  fi
}

auto_rollback_on_error() {
  local rc=$? backup="$1"
  trap - ERR
  set +e
  warn "应用过程中发生错误，正在自动恢复备份：$backup"
  cancel_pending_for_backup "$backup"
  restore_backup_internal "$backup"
  local restore_rc=$?
  if (( restore_rc != 0 )); then
    warn "自动回滚未完全成功，请使用：sudo $PROGRAM rollback --backup '$backup' --yes"
  else
    warn "自动回滚完成"
  fi
  exit "$rc"
}

auto_rollback_signal() {
  local backup="$1"
  trap - ERR INT TERM
  set +e
  [[ -n "$CURRENT_TEST_PID" ]] && kill "$CURRENT_TEST_PID" 2>/dev/null || true
  warn "收到中断信号，正在恢复服务器基线：$backup"
  cancel_pending_for_backup "$backup"
  restore_backup_internal "$backup"
  exit 130
}

rollback() {
  require_linux
  require_root
  require_cmds sysctl tc
  local backup="$BACKUP_PATH" iface kind
  [[ -n "$backup" ]] || backup="$(readlink -f "$LATEST_LINK" 2>/dev/null || true)"
  [[ -n "$backup" && -d "$backup" ]] || die "未找到可用备份；可用 --backup DIR 指定"
  [[ -r "${backup}/meta.env" && -r "${backup}/sysctl.tsv" && -r "${backup}/files.tsv" ]] || die "备份不完整：$backup"

  local IFACE="" ROOT_QDISC_KIND="" SERVICE_ENABLED="unknown" SERVICE_ACTIVE="unknown"
  # shellcheck disable=SC1090
  source "${backup}/meta.env"
  iface="$IFACE"
  kind="$ROOT_QDISC_KIND"
  [[ -n "$iface" ]] || die "备份中缺少 IFACE"

  log "将回滚备份：$backup"
  log "网卡：$iface；原 root qdisc：${kind:-default}"
  confirm_apply
  cancel_pending_for_backup "$backup"
  restore_backup_internal "$backup"
  info "回滚完成。原始 qdisc 文本快照：${backup}/qdisc.txt"
}

# ------------------------------
# 交互式向导
# ------------------------------
UI_BOLD=""
UI_DIM=""
UI_BLUE=""
UI_GREEN=""
UI_YELLOW=""
UI_RED=""
UI_RESET=""
REPLY_VALUE=""
WIZARD_ARGS=()

ui_init() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_BLUE=$'\033[34m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_RED=$'\033[31m'
    UI_RESET=$'\033[0m'
  fi
}

ui_rule() {
  printf '%s\n' "${UI_DIM}────────────────────────────────────────────────────────${UI_RESET}"
}

ui_header() {
  local title="$1"
  printf '\n%s%s%s\n' "$UI_BOLD" "$title" "$UI_RESET"
  ui_rule
}

ui_success() {
  printf '%s✔ %s%s\n' "$UI_GREEN" "$*" "$UI_RESET"
}

ui_note() {
  printf '%sℹ %s%s\n' "$UI_BLUE" "$*" "$UI_RESET"
}

ui_warning() {
  printf '%s⚠ %s%s\n' "$UI_YELLOW" "$*" "$UI_RESET"
}

ui_error() {
  printf '%s✘ %s%s\n' "$UI_RED" "$*" "$UI_RESET" >&2
}

prompt_text() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default"
  else
    printf '%s: ' "$label"
  fi
  if ! IFS= read -r value; then
    printf '\n' >&2
    return 1
  fi
  REPLY_VALUE="${value:-$default}"
}

prompt_choice() {
  local label="$1" default="$2" allowed="$3" value
  while true; do
    prompt_text "$label" "$default" || return 1
    value="$REPLY_VALUE"
    if [[ " $allowed " == *" $value "* ]]; then
      REPLY_VALUE="$value"
      return 0
    fi
    ui_error "请输入以下选项之一：$allowed"
  done
}

prompt_number() {
  local label="$1" default="$2" min="$3" max="${4:-}" value
  while true; do
    prompt_text "$label" "$default" || return 1
    value="$REPLY_VALUE"
    if is_number "$value" && awk -v v="$value" -v min="$min" -v max="$max" \
      'BEGIN { ok=(v>=min); if (max!="") ok=ok && (v<=max); exit !ok }'; then
      REPLY_VALUE="$value"
      return 0
    fi
    if [[ -n "$max" ]]; then
      ui_error "请输入 ${min}~${max} 范围内的数字"
    else
      ui_error "请输入不小于 ${min} 的数字"
    fi
  done
}

prompt_integer() {
  local label="$1" default="$2" min="$3" max="${4:-}" value value_num
  while true; do
    prompt_text "$label" "$default" || return 1
    value="$REPLY_VALUE"
    if is_integer "$value"; then
      value_num=$((10#$value))
      if (( value_num >= min )) && { [[ -z "$max" ]] || (( value_num <= max )); }; then
        REPLY_VALUE="$value_num"
        return 0
      fi
    fi
    if [[ -n "$max" ]]; then
      ui_error "请输入 ${min}~${max} 范围内的整数"
    else
      ui_error "请输入不小于 ${min} 的整数"
    fi
  done
}

prompt_yes_no() {
  local label="$1" default="${2:-n}" hint value
  [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
  while true; do
    printf '%s [%s]: ' "$label" "$hint"
    if ! IFS= read -r value; then
      printf '\n' >&2
      return 1
    fi
    value="${value:-$default}"
    case "$value" in
      y|Y|yes|YES|Yes|是) return 0 ;;
      n|N|no|NO|No|否) return 1 ;;
      *) ui_error "请输入 y 或 n" ;;
    esac
  done
}

interactive_pause() {
  printf '\n按 Enter 返回主菜单...'
  IFS= read -r _ || true
}

interactive_run_script() {
  local needs_root="$1"
  shift
  local cmd=(bash "$SCRIPT_PATH" "$@") rc

  printf '\n%s执行命令：%s bash %s' "$UI_DIM" "$UI_RESET" "$PROGRAM"
  printf ' %q' "$@"
  printf '\n\n'

  if [[ "$needs_root" == "1" && $EUID -ne 0 ]]; then
    if ! have sudo; then
      ui_error "该操作需要 root，但系统没有 sudo。请以 root 身份重新运行脚本。"
      return 1
    fi
    if sudo "${cmd[@]}"; then
      ui_success "操作完成"
      return 0
    else
      rc=$?
    fi
  else
    if "${cmd[@]}"; then
      ui_success "操作完成"
      return 0
    else
      rc=$?
    fi
  fi
  if [[ "${1:-}" == "autotune" && "$rc" == "2" ]]; then
    ui_warning "自动调优未达到设定目标，服务器基线已恢复；这通常表示瓶颈位于运营商 QoS、物理链路或外部限速器"
    return 0
  fi
  ui_error "命令执行失败，退出码：$rc"
  return "$rc"
}

interactive_iface_prompt() {
  local detected="auto"
  if [[ "$(uname -s)" == "Linux" ]] && have ip; then
    detected="$(IFACE=auto resolve_iface 2>/dev/null || printf 'auto')"
    printf '当前网卡：\n'
    ip -br link show 2>/dev/null | sed 's/^/  /' || true
    printf '\n自动识别出口网卡：%s\n' "$detected"
  fi
  prompt_text "出口网卡（输入 auto 表示自动识别）" "auto" || return 1
}

interactive_collect_tuning() {
  local choice profile symptom="normal" scenario_label hard_cap="0"
  local bandwidth cap="" rtt loss iface headroom="95" factor="1.35" max_mib="128"
  local default_bw="1000" default_rtt="50" default_loss="0"
  local allow_shrink="0" force="0"

  ui_header "链路场景选择"
  ui_note "参数应填写本地客户端到这台远程服务器的实测结果。"
  ui_note "RTT 在本地客户端测量；iperf3 -R 也在本地客户端执行。"
  printf '
'
  cat <<'EOF_SCENARIOS'
  1) 自动判断       根据症状、RTT 和丢包率选择策略
  2) 短/中距通用    常规线路，使用 BBR + fq
  3) 网关硬限速     固定速率封顶、重传很多，使用 TBF + fq
  4) 单流 QoS       单连接受限，总吞吐依靠业务层并发
  5) 跨洋长肥管道   RTT 高、BDP 大、单流爬升慢
  6) 随机丢包弱网   高峰期随机丢包或明显抖动
EOF_SCENARIOS
  prompt_choice "请选择场景" "1" "1 2 3 4 5 6" || return 1
  choice="$REPLY_VALUE"

  case "$choice" in
    1)
      profile="auto"
      scenario_label="自动判断"
      cat <<'EOF_SYMPTOMS'

已知的主要症状：
  1) 暂不确定
  2) 固定速率硬封顶
  3) 单流明显低于多流
  4) RTT >= 100ms、爬升慢
  5) 随机丢包/抖动
EOF_SYMPTOMS
      prompt_choice "请选择症状" "1" "1 2 3 4 5" || return 1
      case "$REPLY_VALUE" in
        1) symptom="normal" ;;
        2) symptom="hard-cap"; hard_cap="1"; default_bw="200"; default_rtt="30" ;;
        3) symptom="single-flow-qos"; default_bw="500"; default_rtt="100" ;;
        4) symptom="lfn"; default_bw="1000"; default_rtt="180" ;;
        5) symptom="random-loss"; default_bw="500"; default_rtt="150"; default_loss="3" ;;
      esac
      ;;
    2) profile="balanced"; scenario_label="短/中距通用"; default_bw="500"; default_rtt="30" ;;
    3) profile="hard-cap"; scenario_label="网关硬限速"; hard_cap="1"; default_bw="200"; default_rtt="30" ;;
    4) profile="qos"; scenario_label="单流 QoS"; default_bw="500"; default_rtt="100" ;;
    5) profile="lfn"; scenario_label="跨洋长肥管道"; default_bw="1000"; default_rtt="180" ;;
    6) profile="lossy"; scenario_label="随机丢包弱网"; default_bw="500"; default_rtt="150"; default_loss="3" ;;
  esac

  ui_header "链路参数"
  printf '当前场景：%s\n\n' "$scenario_label"
  if [[ "$hard_cap" == "1" ]]; then
    prompt_number "宿主机/网关硬上限（Mbps）" "$default_bw" "1" || return 1
    cap="$REPLY_VALUE"
    prompt_number "用于 BDP 计算的目标带宽（Mbps）" "$cap" "1" || return 1
    bandwidth="$REPLY_VALUE"
  else
    prompt_number "目标总带宽（Mbps）" "$default_bw" "1" || return 1
    bandwidth="$REPLY_VALUE"
  fi
  prompt_number "基准 RTT（ms）" "$default_rtt" "0.1" || return 1
  rtt="$REPLY_VALUE"
  prompt_number "基准丢包率（%）" "$default_loss" "0" "100" || return 1
  loss="$REPLY_VALUE"
  interactive_iface_prompt || return 1
  iface="$REPLY_VALUE"
  [[ -n "$iface" ]] || iface="auto"

  if [[ "$hard_cap" == "1" ]]; then
    prompt_number "整形比例（硬上限的百分比）" "95" "1" "99.9" || return 1
    headroom="$REPLY_VALUE"
  fi

  if prompt_yes_no "配置高级选项" "n"; then
    prompt_number "BDP 缓冲系数" "1.35" "1" "4" || return 1
    factor="$REPLY_VALUE"
    prompt_integer "自动缓冲区上限（MiB）" "128" "2" "4096" || return 1
    max_mib="$REPLY_VALUE"
    if prompt_yes_no "允许降低系统现有 socket buffer 上限" "n"; then
      allow_shrink="1"
    fi
    if prompt_yes_no "允许覆盖自定义 root qdisc" "n"; then
      force="1"
    fi
  fi

  WIZARD_ARGS=(
    --profile "$profile"
    --symptom "$symptom"
    --bandwidth-mbps "$bandwidth"
    --rtt-ms "$rtt"
    --loss-percent "$loss"
    --iface "$iface"
    --headroom-percent "$headroom"
    --buffer-factor "$factor"
    --buffer-max-mib "$max_mib"
  )
  [[ -n "$cap" ]] && WIZARD_ARGS+=(--cap-mbps "$cap")
  [[ "$allow_shrink" == "1" ]] && WIZARD_ARGS+=(--allow-buffer-shrink)
  [[ "$force" == "1" ]] && WIZARD_ARGS+=(--force)
  return 0
}

interactive_tuning_wizard() {
  local mode="$1" rollback_seconds="300"
  local preview_args=()
  interactive_collect_tuning || return 0
  [[ "$mode" != "persistent" ]] && preview_args+=(--runtime-only)

  ui_header "方案预览"
  if ! interactive_run_script 0 plan "${WIZARD_ARGS[@]}" "${preview_args[@]}"; then
    return 0
  fi

  case "$mode" in
    plan)
      ui_note "本次只生成方案，没有修改远程服务器。"
      ;;
    runtime)
      ui_warning "临时应用会修改远程服务器的全局 TCP 参数和出口 qdisc。"
      prompt_integer "SSH 安全自动回滚等待时间（秒）" "300" "30" "86400" || return 0
      rollback_seconds="$REPLY_VALUE"
      ui_note "应用后请完成测速；确认 SSH 正常后在主菜单选择“确认配置并取消自动回滚”。"
      if prompt_yes_no "确认临时应用上述方案" "n"; then
        interactive_run_script 1 apply "${WIZARD_ARGS[@]}" --runtime-only \
          --auto-rollback-seconds "$rollback_seconds" --yes || true
      else
        ui_note "已取消应用。"
      fi
      ;;
    persistent)
      ui_warning "持久化应用会写入远程服务器 /etc 并启用 systemd 服务。"
      prompt_integer "SSH 安全自动回滚等待时间（秒）" "300" "30" "86400" || return 0
      rollback_seconds="$REPLY_VALUE"
      ui_note "确认 SSH 与业务正常后，必须在主菜单取消自动回滚。"
      if prompt_yes_no "确认持久化应用上述方案" "n"; then
        interactive_run_script 1 apply "${WIZARD_ARGS[@]}" \
          --auto-rollback-seconds "$rollback_seconds" --yes || true
      else
        ui_note "已取消应用。"
      fi
      ;;
  esac
}

interactive_probe_wizard() {
  local target ping_count iface address
  local args=()
  ui_header "远程服务器环境探测"
  ui_note "这里只检测服务器本机状态；不会从服务器反向连接你的本地客户端。"
  interactive_iface_prompt || return 0
  iface="$REPLY_VALUE"
  args+=(--iface "${iface:-auto}")

  address=""
  if [[ "$(uname -s)" == "Linux" ]] && have ip; then
    address="$(guess_server_address 2>/dev/null || true)"
  fi
  prompt_text "服务器公网 IP/域名（用于生成客户端命令，可留空）" "$address" || return 0
  [[ -n "$REPLY_VALUE" ]] && args+=(--server-address "$REPLY_VALUE")

  if prompt_yes_no "是否从服务器 Ping 一个外部目标检查出口" "n"; then
    prompt_text "外部目标 IP/域名" "1.1.1.1" || return 0
    target="$REPLY_VALUE"
    prompt_integer "Ping 次数" "10" "1" "1000" || return 0
    ping_count="$REPLY_VALUE"
    args+=(--target "$target" --ping-count "$ping_count")
  fi
  interactive_run_script 1 probe "${args[@]}" || true
}

interactive_iperf_wizard() {
  local choice address default_address=""
  ui_header "远程服务器 iperf3 测速服务"
  cat <<'EOF_IPERF_MENU'
  1) 自动安装并启动临时 iperf3 服务端（随机空闲端口）
  2) 查看状态和本地客户端命令
  3) 停止临时 iperf3 服务端
  0) 返回
EOF_IPERF_MENU
  prompt_choice "请选择操作" "1" "0 1 2 3" || return 0
  choice="$REPLY_VALUE"
  [[ "$choice" == "0" ]] && return 0

  if [[ "$(uname -s)" == "Linux" ]] && have ip; then
    default_address="$(guess_server_address 2>/dev/null || true)"
  fi
  if [[ "$choice" != "3" ]]; then
    prompt_text "服务器公网 IP/域名（用于生成客户端命令）" "$default_address" || return 0
    address="$REPLY_VALUE"
    [[ -n "$address" ]] || address="<服务器公网IP或域名>"
  fi

  case "$choice" in
    1)
      ui_note "若未安装 iperf3，脚本将使用服务器包管理器自动安装。"
      ui_note "服务启动时会在 20000~59999 中随机选择一个未占用端口。"
      interactive_run_script 1 iperf-start --iperf-port 0 --server-address "$address" || true
      ;;
    2)
      interactive_run_script 0 iperf-status --server-address "$address" || true
      ;;
    3)
      interactive_run_script 1 iperf-stop || true
      ;;
  esac
}

interactive_autotune_wizard() {
  local address="" default_address="" streams duration target_util max_retrans max_rounds wait_seconds rollback_seconds
  local extra_args=()
  ui_header "服务器 BBR 自动闭环调优"
  ui_note "脚本只修改远程服务器；本地电脑只需按提示运行 iperf3 命令。"
  ui_note "每轮结果由服务器端 iperf3 JSON 自动读取，不需要手工抄写测速值。"
  interactive_collect_tuning || return 0

  if [[ "$(uname -s)" == "Linux" ]] && have ip; then
    default_address="$(guess_server_address 2>/dev/null || true)"
  fi
  prompt_text "服务器公网 IP/域名" "$default_address" || return 0
  address="$REPLY_VALUE"
  [[ -n "$address" ]] || { ui_error "服务器公网 IP/域名不能为空"; return 0; }
  prompt_integer "起始测试并发流数量（不足时自动尝试 8/16 流）" "1" "1" "64" || return 0
  streams="$REPLY_VALUE"
  prompt_integer "每轮测试时长（秒）" "15" "3" "300" || return 0
  duration="$REPLY_VALUE"
  prompt_number "达标吞吐占目标带宽百分比" "90" "1" "100" || return 0
  target_util="$REPLY_VALUE"
  prompt_number "允许的最大估算重传比例（%）" "1" "0" "100" || return 0
  max_retrans="$REPLY_VALUE"
  prompt_integer "最大自动调参轮数" "4" "1" "10" || return 0
  max_rounds="$REPLY_VALUE"
  prompt_integer "每轮等待本地测试的最长时间（秒）" "300" "30" "3600" || return 0
  wait_seconds="$REPLY_VALUE"
  prompt_integer "SSH 安全自动回滚总等待时间（秒）" "3600" "300" "86400" || return 0
  rollback_seconds="$REPLY_VALUE"
  if prompt_yes_no "达标后持久化最终服务器参数" "n"; then
    extra_args+=(--persist-on-success)
  fi

  ui_warning "随机端口需要云安全组/服务器防火墙放行 20000~59999，或按显示的端口临时放行。"
  if ! prompt_yes_no "确认开始自动闭环调优" "n"; then
    ui_note "已取消。"
    return 0
  fi

  interactive_run_script 1 autotune "${WIZARD_ARGS[@]}" \
    --server-address "$address" \
    --parallel "$streams" \
    --duration "$duration" \
    --target-utilization "$target_util" \
    --max-retrans-percent "$max_retrans" \
    --max-iterations "$max_rounds" \
    --test-wait-seconds "$wait_seconds" \
    --auto-rollback-seconds "$rollback_seconds" \
    "${extra_args[@]}" || true
}

interactive_confirm_wizard() {
  ui_header "确认远程配置"
  ui_note "只有确认 SSH、业务和测速结果正常后，才应取消安全自动回滚。"
  if prompt_yes_no "确认保留当前配置并取消自动回滚" "n"; then
    interactive_run_script 1 confirm || true
  else
    ui_note "未取消自动回滚。到期后服务器会恢复应用前配置。"
  fi
}

interactive_verify_wizard() {
  local iface
  ui_header "验证当前配置"
  interactive_iface_prompt || return 0
  iface="$REPLY_VALUE"
  interactive_run_script 0 verify --iface "${iface:-auto}" || true
}

interactive_rollback_wizard() {
  local backup latest=""
  ui_header "回滚调优配置"
  if [[ -L "$LATEST_LINK" ]]; then
    latest="$(readlink "$LATEST_LINK" 2>/dev/null || true)"
  fi
  if [[ -d "$BACKUP_ROOT" ]]; then
    printf '最近的备份目录：\n'
    find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r | head -5 | sed 's/^/  /' || true
    printf '\n'
  fi
  if [[ -n "$latest" ]]; then
    printf 'latest 指向：%s\n' "$latest"
  else
    ui_note "当前用户无法读取 latest，留空后仍可由 sudo 查找最近备份。"
  fi
  prompt_text "指定备份目录（留空使用 latest）" "" || return 0
  backup="$REPLY_VALUE"
  ui_warning "回滚会恢复受管 sysctl 文件和 qdisc；复杂自定义 qdisc 只能尽力恢复。"
  if ! prompt_yes_no "确认执行回滚" "n"; then
    ui_note "已取消回滚。"
    return 0
  fi
  if [[ -n "$backup" ]]; then
    interactive_run_script 1 rollback --backup "$backup" --yes || true
  else
    interactive_run_script 1 rollback --yes || true
  fi
}

interactive_main() {
  [[ -t 0 && -t 1 ]] || die "交互模式需要终端；自动化环境请使用 probe/plan/apply/autotune/verify/rollback 子命令"
  require_linux
  ui_init

  while true; do
    ui_header "远程服务器 BBR TCP 调优向导 v${VERSION}"
    printf '运行环境：%s / %s    当前用户：%s\n' "$(uname -s)" "$(uname -r)" "$(id -un 2>/dev/null || printf unknown)"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      printf 'SSH 会话：%s\n' "$SSH_CONNECTION"
    fi
    printf '\n'
    cat <<'EOF_MENU'
  1) 检测服务器并自动安装 iperf3
  2) 管理服务器端 iperf3 测速服务（随机端口）
  3) 自动闭环测试并调优服务器 BBR（推荐）
  4) 根据客户端数据生成方案（不修改服务器）
  5) 手动临时应用方案
  6) 手动持久化应用方案
  7) 确认配置并取消自动回滚
  8) 验证服务器当前配置
  9) 立即回滚配置
  10) 查看命令行帮助
  0) 退出
EOF_MENU
    prompt_choice "请选择操作" "1" "0 1 2 3 4 5 6 7 8 9 10" || { printf '\n'; return 0; }
    case "$REPLY_VALUE" in
      0) printf '\n再见。\n'; return 0 ;;
      1) interactive_probe_wizard; interactive_pause ;;
      2) interactive_iperf_wizard; interactive_pause ;;
      3) interactive_autotune_wizard; interactive_pause ;;
      4) interactive_tuning_wizard plan; interactive_pause ;;
      5) interactive_tuning_wizard runtime; interactive_pause ;;
      6) interactive_tuning_wizard persistent; interactive_pause ;;
      7) interactive_confirm_wizard; interactive_pause ;;
      8) interactive_verify_wizard; interactive_pause ;;
      9) interactive_rollback_wizard; interactive_pause ;;
      10) usage; interactive_pause ;;
    esac
  done
}

main() {
  parse_args "$@"
  validate_common_options
  case "$COMMAND" in
    interactive|menu|wizard) interactive_main ;;
    probe) probe ;;
    plan) print_plan ;;
    apply) apply_tuning ;;
    autotune) autotune_session ;;
    iperf-start) iperf_server_start ;;
    iperf-status) iperf_server_status ;;
    iperf-stop) iperf_server_stop ;;
    confirm) cancel_pending_rollback ;;
    verify) verify_tuning ;;
    rollback) rollback ;;
    help) usage ;;
    *) die "未知命令：${COMMAND}（可用：interactive/probe/plan/apply/autotune/iperf-start/iperf-status/iperf-stop/confirm/verify/rollback）" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
