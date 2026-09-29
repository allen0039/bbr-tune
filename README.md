# bbr-tune：按实测规则选择 TCP / BBR 参数

版本 **2.7.1**。在远程 Linux 代理服务器运行；本地电脑只执行屏幕给出的 `iperf3` 命令，不修改本地网络参数。

本版本提供 **均衡、速度优先、稳定优先、低重传优先** 四种方案。它们是不同的**实测选优策略**，不是四份固定 sysctl 清单，也不改变 BBR 算法内部增益。每种方案都测试单连接和多连接。

> 选出的配置是当前时段、当前路径、已测试候选中的优选结果，不保证全局最优，也不能突破服务器带宽、本地下载带宽或路径瓶颈。

## 一键安装 / 更新

在**远程服务器**执行：

```bash
curl -fsSL https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash
```

只安装，不立即打开菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash -s -- --install-only
```

安装入口是 `/usr/local/sbin/bbr-tune`，命令链接是 `/usr/local/bin/bbr-tune`；配套内核管理文件为 `/usr/local/sbin/bbr-tune-kernel`，安装时校验两者版本一致。再次启动：

```bash
sudo bbr-tune
```

菜单选择 `1` 后，先选择方案，再填写带宽、服务器地址、并发数、测试时长和目标门槛。服务器缺少 `iperf3` 或 JSON/统计解析需要的 `python3` 时会自动安装；不会为本地电脑安装软件。

## BBRv3 内核：使用 Actions-bbr-v3 预编译标准版

菜单 **7** 为独立的内核管理入口。TCP 自动寻优**不会自行安装、切换或重启内核**。本项目已经取消服务器本机编译功能，只使用 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 发布的 x86_64 **标准版** BBRv3 内核。

### 使用边界

- 只从 GitHub Releases 下载 `linux-image`、`linux-headers` 和对应配置文件。
- **不执行上游项目的 `install.sh`**，因此不会导入上游的 sysctl、队列、测速、模块黑名单、快捷命令或内核清理逻辑。
- 不安装带 `-max` 的激进吞吐版。上游说明 Max 版修改 Startup、ProbeBW、cwnd、loss/ECN 等内部行为，不建议日常生产使用；本工具的速度/稳定/重传偏好继续通过运行时实测评分实现。
- 不提供 `bbr-tune kernel build`，也不安装编译工具链、创建构建用户或在服务器保存内核源码。
- 不添加第三方 APT 源，不安装自动跟随更新的元包。每次升级均重新解析 Release、校验、试启动并人工确认。

### Release 选择与完整性检查

安装时从 GitHub API 获取 Release 列表，只接受格式为 `x86_64-X.Y.Z` 的非草稿、非预发布标准版，并选择最高三段稳定版本。最新标准版必须同时包含且仅包含一组可识别的：

```text
linux-image-X.Y.Z-joeyblog-bbrv3_*.deb
linux-headers-X.Y.Z-joeyblog-bbrv3_*.deb
x86_64-X.Y.Z.config
```

对每个文件执行以下检查：

1. 下载地址必须属于该仓库、该 Release 标签；
2. GitHub Release API 必须提供合理的文件大小和 `sha256:` 摘要；
3. 下载后的大小和 SHA-256 必须与 API 元数据完全一致；
4. image 和 headers 的 deb 包名、版本、架构必须一致并匹配 Release 标签；
5. 发布配置必须启用 `CONFIG_TCP_CONG_BBR=y` 和 `CONFIG_NET_SCH_FQ=y`；
6. Release 不能落后于 kernel.org 同系列当前稳定/LTS 修订，也不能属于 RC、EOL 或未列出系列；
7. 安装后再次检查 `/boot/config-*`、内核文件、initramfs、modules 和 `tcp_bbr` 模块版本。

工具会先下载体积较小的 Release 配置文件，再检查目标内核是否已经存在：

- image、headers、`vmlinuz`、initramfs、modules、发布配置和 `tcp_bbr` v3 元数据全部匹配时，不覆盖、不重复安装，也不再次下载大型 deb；工具会将该内核安全纳入 `trial` / `verify` / `accept` / `fallback` 流程。
- 同名内核残缺、软件包版本不符、配置不一致或无法确认 BBRv3 时，拒绝覆盖并在会话目录生成 `existing-target.tsv` 诊断表。
- 如果 Release 目标就是当前运行内核，工具不会伪造“旧内核”回退基线；应先确认现有启动与恢复策略，再决定是否管理该内核。

GitHub 提供的 SHA-256 可以证明下载内容与当时的 Release 元数据一致，**不等同于 Debian/Ubuntu 发行版签名，也不能证明第三方构建不存在恶意或缺陷**。Release 标签解析出的 Git 提交、所选 Release JSON、资产 URL、API 摘要和本地 SHA-256 都会保留在会话日志中。

### 支持范围与风险限制

自动安装仅覆盖 **Debian 12/13、Ubuntu 24.04/26.04、amd64、标准 GRUB2**。其他发行版、ARM、systemd-boot、外部引导内核等环境只提供检测。

以下情况停止自动安装：

- 容器；
- Secure Boot 启用或状态无法确认；
- 存在 DKMS 模块；
- ZFS、网络根文件系统或未验证的根文件系统；
- LVM、RAID 或特殊 `/boot` 设备；
- 缺少旧内核、initramfs 或唯一可识别的 GRUB 启动项；
- dpkg 存在未完成操作；
- `/boot` 少于 512 MiB 或根文件系统少于 2 GiB 可用空间；
- 存在尚未确认的 TCP 调优会话或未完成的内核试用流程。

这些检查不能保证第三方通用内核适配所有云平台。安装前必须具备云控制台或救援访问能力。

### 推荐流程

全部命令都在**远程服务器**执行：

```bash
# 只读评估，不下载、不安装
sudo bbr-tune kernel plan

# 下载并校验 Actions-bbr-v3 最新标准版，然后安装；不重启
sudo bbr-tune kernel install

# 仅设置下一次启动试用新内核；仍不执行 reboot
sudo bbr-tune kernel trial
```

然后自行安排维护窗口重启。安装完成并不代表新内核已经运行。

重启后：

```bash
# 必须同时匹配记录的目标内核，且运行时 tcp_bbr version=3
sudo bbr-tune kernel verify

# 检查 SSH、网卡、存储和代理业务后，设为长期默认
sudo bbr-tune kernel accept

# 重新建立单连接、多连接基线并选择运行时 TCP 参数
sudo bbr-tune
```

如需回到旧内核：

```bash
sudo bbr-tune kernel fallback   # 安排下一次启动旧内核，不立即重启
sudo bbr-tune kernel status
```

非交互安装必须同时明确提供恢复能力确认：

```bash
sudo bbr-tune kernel install --yes --console-available
```

`verify` 只验证内核和 BBRv3 能力，不修改 TCP sysctl。`confirm` / `rollback` 管理 TCP 参数，`accept` / `fallback` 管理内核启动项，两者不是同一个回滚机制。

审计目录：

```text
/var/lib/bbr-tcp-tuning/kernels/<时间戳-PID>/
```

其中包括 `run.log`、`state.json`、`releases.json`、`selected-release.json`、`tag-ref.json`、`release-assets.tsv`、`release.config`、`existing-target.tsv` 和 GRUB 修改前快照。仅在需要首次安装时才会另外保留 `packages.sha256` 与下载的 image/headers 包。不会自动删除旧内核，也不会自动执行服务器重启。

## 如何选择方案

| 方案 | 命令值 | 吞吐 / 稳定 / 低重传权重 | 选择倾向 |
|---|---|---|---|
| 均衡（默认） | `balanced` | 70 / 15 / 15 | 综合下载性能 |
| 速度优先 | `speed` | 90 / 5 / 5 | 更高吞吐，但不忽略稳定性和重传 |
| 稳定优先 | `stable` | 40 / 45 / 15 | 更小吞吐波动、更小负载 RTT 增长 |
| 低重传优先 | `retrans` | 45 / 10 / 45 | 更低估算重传，同时保留吞吐要求 |

**所有方案都优先选择单连接与多连接吞吐分别达到各自基线 95% 的候选。** 因此不会为了多连接总速度，直接忽略单连接退化。若没有候选满足该保护线，仍从有效候选中按所选方案评分选择，并明确报告退化风险。

相同链路下，多种方案选中同一组参数是正常结果；不会为了使方案不同而人为更改参数。

CLI 示例（按需把 `stable` 换成其他方案）：

```bash
sudo bbr-tune autotune \
  --strategy stable \
  --bandwidth-mbps 500 \
  --server-address <服务器公网IP或域名> \
  --parallel 8 \
  --duration 15 \
  --repeats 2 \
  --target-utilization 90 \
  --max-retrans-percent 1 \
  --persist
```

`--repeats` 为每组参数、每种连接数的复测次数，默认 2，范围 1～5。默认每个候选需要执行 2 次单连接和 2 次多连接测试，本地应逐条运行服务器当前显示的命令。

## 目标带宽含义

测试方向是 **远程服务器 → 本地电脑**。填写服务器出站带宽、本地下载带宽及已知路径限制中的最小值，例如服务器出站 200 Mbps、本地下载 1000 Mbps，应填写 200。

带宽值用于 BDP 计算和达标判断，**不是流量整形速率**。不要填写一个明显超过链路条件的数字来扩大缓存。

## 参数调整规则

### 1. 先建立基线，再修改参数

先测试单连接和多连接。优先采用接收端实际收到的数据速率；反向测试的服务端 JSON 可能不提供接收端统计，或者输出“时长大于零，但接收字节数和速率均为零”的占位汇总。此时采用发送端速率，并在屏幕、测量记录和报告中说明来源；**发送端速率不等同于接收端实际有效吞吐**。此行为不只存在于旧版 iperf3。

从 TCP JSON 的最小 RTT 估算链路基础时延；没有最小 RTT 时使用均值，必要时从 socket 或 ICMP 取得备用时延。这是估计值，不等同于已排除排队时延的物理 RTT。

### 2. 根据 BDP 和 TCP 参数语义确定搜索空间

```text
BDP bytes = 目标 Mbps × 1,000,000 × RTT ms / 1,000 / 8
```

- 保留 `tcp_rmem` / `tcp_wmem` 的原最小值和默认值，仅搜索最大值；保证最小 ≤ 默认 ≤ 最大。
- 从约 1 BDP 开始，向上取整到 MiB，通常不低于 4 MiB。
- 本次上限取 **8 BDP 实验边界与内存技术上限中的较小值**；为保留原默认值和最小实验粒度，允许提高非常小的 BDP 边界。
- 8 BDP 是本工具的有限实验范围，**不是 Linux 官方最优公式**。不再将全机允许的内存量视为必须逐档耗尽的目标。
- 缓存上限不是拥塞窗口，不是实际已分配内存，也不是服务器出口速率限制器。

### 3. 扩容必须有后续测量依据

每组默认重复两次，吞吐、RTT、重传比例取中位数：

- 有显著评分提升：更新候选，继续探测；
- 连续两档无显著提升：停止扩大缓存；
- 评分回落或失去已有的双侧基线保护：在最优点与回落点之间二分精调到 1 MiB；
- 达到 BDP/内存边界：停止，不继续盲目扩容。

更新阈值为 0.25 评分点、回落阈值为 0.75 评分点，是抑制小幅测量波动的经验规则，并非统计显著性检验。不会因为达到带宽门槛就直接停止，也没有固定的候选次数上限。

### 4. 仅修改具有明确用途的 TCP 控制项

| 参数 | 用途与规则 |
|---|---|
| `tcp_congestion_control=bbr` | 确认内核支持 BBR 后使用；不伪造不存在的 BBR 内部可调参数 |
| `net.core.default_qdisc=fq`、网卡 `fq` | 为本次实验提供一致队列；不设置带宽整形 |
| `rmem_max` / `wmem_max` | 与本轮候选缓存上限同步 |
| `tcp_rmem` / `tcp_wmem` 最大值 | 按 BDP、内存预算及测试结果选优；原最小/默认值不变 |
| `tcp_mem` | 使用专用代理服务器的总内存预算，单位是页 |
| `tcp_moderate_rcvbuf=1` | 启用接收缓存自动调整 |
| `tcp_window_scaling=1` | 支持较大通告窗口 |
| `tcp_sack=1` / `tcp_dsack=1` | 保留选择确认和重复数据确认能力，不宣称可以消除链路丢包 |

每次写入都会读回验证；关键值不能准确生效就终止实验并尝试恢复备份，而不是将未应用的配置标记为有效候选。

### 5. 没有证据的参数保持原值

本版本不再自动套用以下固定设置：

- `kernel.pid_max`、`kernel.panic`、`kernel.sysrq`、`core_pattern`、调度及日志策略：不是 TCP 下载测速能确定的配置；
- `vm.panic_on_oom`、`overcommit_memory`、`min_free_kbytes`、dirty / swap 策略：不从单项吞吐推导系统内存政策；
- `rp_filter`、ARP、邻居表和端口范围：可能关系到多网卡、透明代理、隧道或路由拓扑；
- SYN / TIME_WAIT / FIN 超时、连接队列：没有监听溢出或连接压力证据，不降低重试次数、连接容量或超时；
- `tcp_fastopen`、`tcp_notsent_lowat`：涉及应用行为，不把全局固定值作为万能优化；
- `tcp_mtu_probing`：没有 PMTU 黑洞证据，不盲目启用；
- `tcp_fack` / `tcp_adv_win_scale`：不将失效或废弃选项纳入寻优；
- `tcp_pacing_ss_ratio` / `tcp_pacing_ca_ratio`：不把通用 TCP 比率误当作 BBR 的专用增益。

已有 CAKE、整形或复杂 qdisc 默认拒绝覆盖；包括 `mq` 下的自定义子队列。只有管理员审计后显式指定 `--force` 才允许继续。自定义队列参数未必可以完整自动重建，必须保留备份和控制台访问。

## 评分与测量定义

单连接与多连接吞吐各换算成目标带宽百分比（单项最高计 120），取调和均值 `S`，避免只看多连接速度。

稳定度 `V` 取两个场景中较差一侧：

```text
CV = max(有效发送区间吞吐的变异系数中位数, 多次测试吞吐的变异系数)
RTT增长 = max(本轮负载RTT / 对应基线负载RTT - 1, 0)
单侧稳定分 = 100 / (1 + CV / 20 + 4 × RTT增长)
```

每轮需要至少 3 个有效区间，排除首秒启动区间、被省略区间和过短尾部，但**保留真实的零吞吐停顿**。CV 缺失标为 `NA`，不视为零波动。稳定优先缺少 CV 或 RTT 时拒绝评价；其他方案的稳定部分不给分，并保留缺失标记。

低重传质量 `R` 也取较差一侧：

```text
参考比例 = 最大估算重传率阈值（设为0时，评分尺度使用0.05个百分点）
单侧重传质量 = 100 / (1 + 估算重传比例 / 参考比例)
总评分 = (吞吐权重 × S + 稳定权重 × V + 低重传权重 × R) / 100
```

重传比例依据发送字节、重传段数及 MSS 估算；JSON 缺少 MSS 时使用 1448 bytes 并记录来源。它**不是实际链路丢包率**，多流 MSS 不同等情况会影响估算精度。设定重传门槛为 0 时，达标判断仍严格要求所有复测的实际重传段数为 0（不依赖比例显示舍入），不会放宽为 0.05。

缺少重传统计、非 TCP、非反向测试、流数不符、时长不足、非有限数值、失败测试，不参与候选评价。

**不同方案的总评分不可直接横向比较。** 历史报告应同时看吞吐、CV、RTT、重传及方案名称。单流与多流差异只能说明性能差异，不能仅凭此断定运营商 QoS。

## 内存预算

沿用专用代理服务器的积极预算：

```text
有效总内存 = min(物理总内存, 可识别的 cgroup 总内存上限)
tcp_mem low / pressure / high = 有效总内存的 1/3、1/2、2/3（换算为页）
单 socket 内存技术上限 = min(有效总内存 × 2/3, 2047 MiB)
```

总内存不是当前可用内存。这里的 2/3 是聚合分配器高水位预算，不是每个连接预分配 2/3 内存。实际测试缓存还受 BDP 边界与测试结果约束。

预算只适用于已评估资源占用的专用代理服务器，不是对 OOM 的保证。`vm.*` 不会为此自动改写。

## 未达标如何处理

绝对带宽/重传目标用于标记“达标”，不再阻止使用候选：

1. 优先考虑保持双侧基线能力的候选；
2. 同等级候选按照所选方案评分；
3. 最优候选再次复测；未完全达标仍应用，标记 `best-effort-runtime` 或 `best-effort-persistent`；
4. 复核低于基线会如实报告，不包装为性能提升。

测试中断、失败、关键参数不能应用或无有效候选，则仍执行安全回滚。

## 本地测试与连接问题

```bash
# 以服务器当前显示的地址、随机端口、流数和时长为准
iperf3 -4 -c <服务器IPv4> -p <端口> -R -P 1 -t 15 -i 1
```

服务端确认监听后才显示命令。未完成的连接、无效 cookie 或被截断的 JSON 会被记录并重新监听，端口保持不变；连接等待仍受本轮超时约束。`Connection refused` 时，检查服务器公网地址、云安全组、服务器防火墙以及 IPv4/IPv6 参数。

### 已完成测速却反复出现 `invalid metric range`

2.6.0 将部分服务端反向结果中的接收占位汇总误判为零吞吐，并重复恢复监听。2.6.1 已修复：

- 服务端为发送角色，接收汇总的字节数、速率均为零时，允许回退到有效的发送端统计，即使接收汇总的 `seconds` 大于零。旧输出缺少角色标志时兼容相同结构。
- 不把所有零值都当成占位记录：明确的接收角色、非零接收字节却零速率，以及负值、非有限数值、缺失的必要发送指标仍会被拒绝。
- 已有完整汇总却校验失败、连接数/时长不符合本轮要求，或完整结果伴随异常进程退出时，停止本轮并列出具体字段、实际值和原始记录位置；不再当作端口扫描无限重试。正在调优时沿用安全回滚规则。
- 只有正常退出且结果有效的测量才参与选优。测试阶段会显示监听状态，以及是否检测到 TCP 连接。

升级前先用 `Ctrl+C` 正常结束旧测试并等待清理，再在服务器执行一键更新命令；之后使用新会话显示的端口重新测速。若仍发生校验错误，请提供本轮的 `.err`、`.attempt-NNN.json` 和 `.attempt-NNN.validation.log`；原始 JSON 可能包含地址等环境信息，分享前请按需脱敏。

工具不修改任何防火墙，也不会通过配置缓存来绕过网络策略。

## 报告与跨时段比较

每次会话保存在：

```text
/var/lib/bbr-tcp-tuning/sessions/<时间戳-PID>/
```

| 文件 | 用途 |
|---|---|
| `run.log` | 运行过程、参数写入前后值、监听状态和区间统计 |
| `rules.txt` | 本次方案、评分权重、BDP/内存边界及不调整项目 |
| `results.tsv` | 每组单/多连接汇总、评分、CV、实测 RTT、方案和复测次数 |
| `*.measurements.tsv` | 每次复测的吞吐、重传比例、RTT、CV、最小 RTT、重传总数、发送字节、吞吐来源、估算来源 |
| `comparison.txt` | 专业分段式调优前后对比及实际生效结果 |
| `sysctl-comparison.tsv` | 包含已改 TCP 项及未改系统策略的前后审计 |
| `system-before.txt` / `system-after.txt` | 系统、参数、qdisc、计数器快照 |
| `*-r*.json` / `*.err` / `*.rtt-samples` | 有效原始结果、汇总错误记录和 socket RTT 采样 |
| `*.attempt-NNN.json` / `*.attempt-NNN.err` | 每次未被接受的连接原始输出与标准错误，后续连接不会覆盖 |
| `*.attempt-NNN.validation.log` | 未被接受的连接校验原因、异常字段或进程退出码 |

历史索引为 `/var/lib/bbr-tcp-tuning/history.tsv`，新增方案、CV、负载 RTT 和复测次数字段。升级字段时旧索引另存为 `history.legacy-*.tsv`，原始会话目录不会删除。

```bash
bbr-tune history
bbr-tune status
```

## 安全回滚与升级注意事项

每轮固定等待连接 300 秒。首次修改前备份受管参数和持久化文件；长时间复测时，每次测量前续期固定 3600 秒回滚计时器，结束后再计时 3600 秒等待确认。

另开一个 SSH 会话检查代理业务和网络后执行：

```bash
sudo bbr-tune confirm
```

需要恢复时：

```bash
sudo bbr-tune rollback --yes
```

**从 2.4.0 升级：** 本版本不会猜测原来的系统默认值，也不会自动撤销旧版已经写入运行内核的 `kernel.*`、`vm.*` 或路由策略。如果需要恢复旧版修改，先使用相应旧会话备份回滚。新版本持久化文件只包含受管 TCP 项，原来依赖旧文件的其他设置在重启后可能不再生效，请审计后决定是否另行管理。

## 实现依据与验证

参数语义参考 Linux 内核一手资料：

- [Linux IP sysctl 文档](https://docs.kernel.org/networking/ip-sysctl.html)：缓存向量、`tcp_mem`、自动调节、应用相关参数及废弃选项。
- [Linux BBR 实现](https://github.com/torvalds/linux/blob/master/net/ipv4/tcp_bbr.c)：BBR 的带宽/最小 RTT 模型、内部增益和 pacing。
- [Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)：本工具使用其 GitHub Release 标准版 image、headers 与配置文件；不执行其安装脚本。
- [GitHub REST API Releases](https://docs.github.com/en/rest/releases/releases)：Release 元数据与资产 SHA-256 摘要来源。
- [kernel.org 发布元数据](https://www.kernel.org/releases.json)：维护中稳定/LTS 修订检查。
- [iperf3 使用说明](https://software.es.net/iperf/invoking.html)：反向测试、并发、JSON 结果。

权重、8 BDP 实验范围和停滞阈值属于本工具明确披露的工程规则，不应解释为内核官方推荐值。

本地开发测试不会写入真实 sysctl、qdisc 或防火墙：

```bash
for test in tests/test-*.sh; do bash "$test" || exit; done
```

覆盖服务端接收占位汇总、无效指标字段诊断、异常连接恢复与完整结果失败退出、安装入口、内存与 BDP 边界、四种方案排序、单/多连接保护、复测中位数与波动、输入有效性、最佳努力回退、监听恢复、参数读回验证、格式化报告及历史记录。内核测试使用模拟 GitHub Release、软件包与 GRUB 命令，覆盖标准版筛选、Max/预发布排除、资产 URL 与 SHA-256、维护状态、旧内核保护、一次性试用、版本验证、确认与恢复；不在开发机安装内核。模拟测试通过不替代远程服务器的实际下载、安装、重启和业务验证。

若已安装 iperf3，`tests/test-iperf-loopback.sh` 会使用真实 iperf3，在 `127.0.0.1` 上验证单连接/四连接反向结果被一次接受；每流限速 10 Mbps、每次 3 秒，不监听公网、不修改任何 TCP 参数。不自动安装测试依赖，缺少 iperf3 时明确跳过。此回环测试不代表远程公网链路性能验证。
