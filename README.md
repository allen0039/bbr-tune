# bbr-tune：远程代理服务器 TCP / BBR 自动寻优工具

`bbr-tune` 是一个只在**远程 Linux 服务器**执行的交互式 TCP/BBR 调优工具，当前版本为 **2.4.0**。

它通过本地电脑发起的反向 `iperf3` 测试，自动测量 RTT，分别评估单连接和多连接吞吐，持续扩大 TCP 缓存直至检测到性能边界，再回退精调并应用本次测试中的综合最优参数。

适用场景：

- 网络代理、转发、中继和下载服务器；
- 跨境、跨洋、高 RTT 或存在随机丢包的链路；
- 需要同时兼顾单连接速度与多连接聚合吞吐的服务器；
- 需要完整测试日志、调优前后对比和安全回滚的环境。

> 本地电脑只执行界面给出的 `iperf3` 客户端命令。脚本不会修改本地 TCP 参数、路由、qdisc 或防火墙。

---

## 一键安装并启动

在远程服务器执行：

```bash
curl -fsSL https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash
```

没有 `curl` 时可使用：

```bash
wget -qO- https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash
```

安装脚本会自动：

1. 检查 Linux 与 root 权限；
2. 安装 `iproute2`、`procps`、`kmod` 等运行依赖；
3. 下载并校验最新主程序；
4. 安装到 `/usr/local/sbin/bbr-tune`；
5. 创建 `/usr/local/bin/bbr-tune` 命令入口；
6. 打开交互界面。

以后直接运行：

```bash
sudo bbr-tune
```

只安装或更新、不立即打开界面：

```bash
curl -fsSL https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash -s -- --install-only
```

---

## 交互界面

```text
╔══════════════════════════════════════════════════════════════╗
║        远程服务器 TCP / BBR 自动寻优工具 v2.4.0             ║
╚══════════════════════════════════════════════════════════════╝

  1) 自动测试并选择最优 TCP 参数
  2) 查看当前 TCP / BBR 状态
  3) 查看历史测试与对比记录
  4) 确认保留当前参数
  5) 恢复调优前参数
  6) 使用说明
  0) 退出
```

首次使用选择 `1`，依次填写：

- 期望端到端下载带宽；
- 服务器公网 IP 或域名；
- 多连接评估并发数，默认 `8`；
- 每轮测试时长，默认 `15` 秒；
- 目标带宽利用率，默认 `90%`；
- 最大估算重传率，默认 `1%`；
- 是否将实测最优参数写入开机配置。

每轮等待本地连接固定为 `300` 秒，安全回滚固定为 `3600` 秒，无需手动填写。

---

## 目标带宽如何填写

测试方向固定为：

```text
远程服务器 ───── 下载流量 ─────> 本地电脑
```

目标带宽是该端到端下载方向的期望上限，建议填写下列限制中的最小值：

```text
min(
  服务器或宿主机出站带宽上限,
  服务器物理端口上限,
  本地下载带宽上限,
  已知中间链路上限
)
```

| 服务器出站上限 | 本地下载上限 | 建议目标 |
|---:|---:|---:|
| 200 Mbps | 1000 Mbps | 200 Mbps |
| 1000 Mbps | 500 Mbps | 500 Mbps |
| 1000 Mbps | 1000 Mbps，路径约 300 Mbps | 300 Mbps |

该数值只用于 BDP 计算、评分和达标判断，不会对服务器或本地电脑实施限速。

---

## 本地电脑如何参与测试

服务器会为每一轮测试随机选择一个未占用的 TCP 端口，确认 `iperf3` 已进入监听状态后再显示客户端命令。

单连接示例：

```bash
iperf3 -4 -c <服务器IPv4地址> -p 43817 -R -P 1 -t 15 -i 1
```

多连接示例：

```bash
iperf3 -4 -c <服务器IPv4地址> -p 43817 -R -P 8 -t 15 -i 1
```

在本地电脑按服务器界面提示依次执行即可。服务器缺少 `iperf3` 时会自动安装；本地缺少客户端时需要自行安装。

### 连接被拒绝

2.3.1 及以上版本具备监听监督机制：端口扫描、无效连接或不完整握手不会永久消耗一次性 `iperf3` 服务，监听器会自动重新启动。

如果仍出现 `Connection refused`，请检查：

1. 客户端命令中的公网地址是否正确；
2. 云安全组是否允许界面显示的随机 TCP 端口；
3. 服务器防火墙是否允许该端口；
4. 本地网络是否限制高位端口；
5. IPv4 地址使用 `-4`，IPv6 地址使用 `-6`。

工具不会自动修改云安全组或防火墙。

---

## 自动寻优流程

### 1. 建立调优前基线

依次测试：

- 单连接：固定 `-P 1`；
- 多连接：默认 `-P 8`，可在界面中调整。

首轮测试会从 `iperf3` JSON、Linux TCP socket 或 ICMP 备用测量中自动取得 RTT。

### 2. 计算 BDP 与内存边界

```text
BDP = 目标带宽 × RTT ÷ 8
```

候选缓存从接近一个 BDP 的值开始。单 socket 搜索上限由服务器有效总内存决定，不再固定为 128 MiB。

### 3. 倍增探索

工具持续扩大缓存，并为每个候选分别执行单连接与多连接测试。候选数量不设置人工上限，搜索只受计算出的内存技术上限和性能边界约束。

### 4. 越界检测与回退精调

综合评分明显下降时，工具认为已经越过性能边界，并在当前最优值与回落值之间执行二分精调，最终收敛到 `1 MiB` 粒度。

### 5. 最佳努力选择

候选排序遵循：

1. 同时保持单连接与多连接基线能力的候选优先；
2. 同等级候选按单连接/多连接调和评分排序；
3. 即使所有候选都没有达到设定的绝对带宽门槛，也会采用本次会话中实测综合表现最优的候选，而不是直接恢复基线。

只有测试失败、关键 TCP 参数无法应用、异常退出或用户主动回滚时，才恢复调优前配置。

### 6. 最终复核

选定候选会再次进行单连接和多连接测试。复核结果、绝对门槛状态和基线保护状态都会写入报告；未达到绝对目标时标记为“最佳努力结果”。

---

## 单连接与多连接平衡模型

单连接和多连接分别计算质量分，随后使用调和均值生成综合评分。该模型会主动惩罚：

- 多连接提升、单连接明显下降；
- 单连接提升、多连接聚合吞吐明显下降；
- 吞吐提高但重传率显著恶化。

基线保护线默认是：

```text
候选单连接吞吐 ≥ 调优前单连接吞吐 × 95%
候选多连接吞吐 ≥ 调优前多连接吞吐 × 95%
```

保护线用于候选优先级排序，不再作为“完全不应用任何候选”的绝对阻断条件。

---

## 内存与 TCP 缓存策略

工具按**有效总内存**计算预算：

```text
有效总内存 = min(服务器物理总内存, cgroup 总内存上限)
TCP 聚合内存预算 = 有效总内存 × 2 / 3
```

`net.ipv4.tcp_mem`：

```text
low      = 有效总内存 × 1 / 3
pressure = 有效总内存 × 1 / 2
high     = 有效总内存 × 2 / 3
```

单 socket 缓存搜索上限：

```text
min(TCP 聚合内存预算, 2047 MiB)
```

`2047 MiB` 用于规避常见内核中字节型 sysctl 的有符号整数边界。TCP 聚合预算仍可大于该数值。

`vm.min_free_kbytes` 使用动态值：

```text
有效总内存 × 1%，并限制在 8 MiB～256 MiB
```

| 有效总内存 | TCP 聚合预算 | 单 socket 上限 | min_free_kbytes |
|---:|---:|---:|---:|
| 256 MiB | 170 MiB | 170 MiB | 8 MiB |
| 1 GiB | 682 MiB | 682 MiB | 10 MiB |
| 4 GiB | 2730 MiB | 2047 MiB | 40 MiB |
| 8 GiB | 5461 MiB | 2047 MiB | 81 MiB |
| 16 GiB | 10922 MiB | 2047 MiB | 163 MiB |
| 64 GiB | 43690 MiB | 2047 MiB | 256 MiB |

这些是内核可使用的上限，不代表启动后立即占用对应物理内存。

> `2/3` 策略面向专用代理服务器。若服务器还运行数据库、构建任务或其他高内存业务，应先评估整体内存需求。

---

## 服务器参数配置范围

2.4.0 扩展为专用代理服务器增强配置，主要包括：

### 内核与虚拟内存

```text
kernel.pid_max
kernel.panic
kernel.sysrq
kernel.core_pattern
kernel.printk
kernel.numa_balancing
kernel.sched_autogroup_enabled
vm.swappiness
vm.dirty_ratio
vm.dirty_background_ratio
vm.panic_on_oom
vm.overcommit_memory
vm.min_free_kbytes
```

### 网络核心与 TCP

```text
net.core.default_qdisc
net.core.netdev_max_backlog
net.core.rmem_max / wmem_max
net.core.rmem_default / wmem_default
net.core.somaxconn
net.core.optmem_max
net.ipv4.tcp_fastopen
net.ipv4.tcp_timestamps
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_max_tw_buckets
net.ipv4.tcp_sack / tcp_dsack / tcp_fack
net.ipv4.tcp_rmem / tcp_wmem / tcp_mem
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_congestion_control
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_window_scaling
net.ipv4.tcp_adv_win_scale
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_max_orphans
net.ipv4.tcp_synack_retries / tcp_syn_retries
net.ipv4.tcp_abort_on_overflow
net.ipv4.tcp_stdurg
net.ipv4.tcp_rfc1337
net.ipv4.tcp_syncookies
```

### IPv4、邻居表和接口策略

```text
net.ipv4.ip_local_port_range
net.ipv4.ip_no_pmtu_disc
net.ipv4.route.gc_timeout
net.ipv4.neigh.default.gc_stale_time
net.ipv4.neigh.default.gc_thresh1 / 2 / 3
net.ipv4.icmp_echo_ignore_broadcasts
net.ipv4.icmp_ignore_bogus_error_responses
net.ipv4.conf.*.rp_filter
net.ipv4.conf.*.arp_announce
net.ipv4.conf.*.arp_ignore
```

不存在的内核参数会自动跳过；容器或宿主机拒绝写入的非关键参数会保留原值并记录警告。BBR 与四项关键 TCP 缓存上限必须成功生效，否则立即安全回滚。

### 队列调度器

工具优先使用 `CAKE`：

```text
BBR + CAKE
```

内核未提供 `sch_cake` 或网卡无法应用 CAKE 时，自动回退为：

```text
BBR + fq
```

运行时 qdisc 与 `net.core.default_qdisc`、模块加载和 systemd 持久化配置保持一致。

### 重要风险说明

- `kernel.panic=1` 与 `vm.panic_on_oom=1` 会在内核严重故障或 OOM 时触发快速恢复策略；
- `rp_filter=1`、`arp_ignore=1`、`arp_announce=2` 可能影响多网卡、策略路由、透明代理、隧道或非对称路由；
- 调优前会完整备份这些参数，异常时自动恢复；仍建议保留云平台控制台或带外管理通道。

---

## 日志与调优前后对比

每次会话使用独立目录：

```text
/var/lib/bbr-tcp-tuning/sessions/<时间戳-PID>/
```

| 文件 | 内容 |
|---|---|
| `run.log` | 完整运行日志与实时测试过程 |
| `results.tsv` | 每轮单连接、多连接结构化数据 |
| `comparison.txt` | 格式化专业评估报告 |
| `sysctl-comparison.tsv` | 全部受管参数的调优前后值与状态 |
| `system-before.txt` | 调优前系统、参数、qdisc 和 TCP 计数器 |
| `system-after.txt` | 调优后系统、参数、qdisc 和 TCP 计数器 |
| `before-*.json` | 基线 `iperf3` 原始结果 |
| `candidate-*.json` | 候选测试原始结果 |
| `final-*.json` | 最终复核原始结果 |
| `*.rtt-samples` | TCP RTT 采样 |
| `*.err` | 对应轮次错误输出 |

`comparison.txt` 包含：

1. 执行结论与最佳努力状态；
2. 评估方法和选择原则；
3. 测试环境；
4. 内存与缓存策略；
5. 单连接、多连接吞吐和重传对比；
6. 核心 TCP 参数对比；
7. 所有受管 sysctl 的完整前后对比；
8. 最优候选；
9. 逐轮测试明细；
10. 审计文件位置。

跨时段汇总：

```text
/var/lib/bbr-tcp-tuning/history.tsv
```

查看历史：

```bash
bbr-tune history
```

---

## 安全回滚

- 调优前备份全部受管 sysctl、qdisc 和持久化文件；
- 每轮使用 `20000～59999` 范围内的随机未占用端口；
- 参数首次修改后启动 `3600` 秒自动回滚；
- 测试失败、关键参数应用失败、异常退出或中断时立即恢复；
- 检测到无法安全重建的自定义 root qdisc 时默认拒绝覆盖；
- 新会话会清理上一会话遗留的安全回滚状态，并以当前配置重新建立基线。

确认服务器和 SSH 正常后执行：

```bash
sudo bbr-tune confirm
```

立即恢复最近一次调优前配置：

```bash
sudo bbr-tune rollback --yes
```

---

## 常用命令

```bash
# 交互界面
sudo bbr-tune

# 当前状态
bbr-tune status

# 历史结果
bbr-tune history

# 命令行直接寻优
sudo bbr-tune autotune \
  --bandwidth-mbps 1000 \
  --server-address <服务器公网IP或域名> \
  --parallel 8 \
  --duration 15 \
  --target-utilization 90 \
  --max-retrans-percent 1 \
  --persist
```

如果出口使用自定义 root qdisc，审计确认后可添加 `--force`。该选项允许覆盖现有 qdisc，不会绕过参数备份和安全回滚。

---

## 支持环境

主程序只支持 Linux，自动依赖安装支持：

```text
apt-get
dnf
yum
zypper
apk
pacman
```

内核必须支持 BBR；CAKE 不可用时自动使用 `fq`。

手动运行仓库版本：

```bash
git clone https://github.com/dingding229/bbr-tune.git
cd bbr-tune
chmod +x install.sh bbr-tune.sh
sudo ./install.sh
```

---

## 开发测试

```bash
bash -n install.sh
bash -n bbr-tune.sh
bash tests/test-install.sh
bash tests/test-plan.sh
bash tests/test-autotune-logic.sh
bash tests/test-remote-logic.sh
```

测试覆盖一键安装、内存预算、动态 `min_free_kbytes`、扩展 sysctl 配置、CAKE/fq 选择、BDP 候选生成、单/多连接均衡评分、未达标最佳努力选择、监听监督、RTT 与重传解析、完整回滚、报告和历史记录。
