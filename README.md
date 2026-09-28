# bbr-tune：远程服务器 TCP / BBR 自动寻优工具

`bbr-tune` 用于在远程 Linux 服务器上自动测试并选择 TCP/BBR 参数。当前版本为 `2.3.0`。

它适合以下服务器：

- 网络代理、转发和中继服务器；
- 跨境、跨洋和高 RTT 链路；
- 希望兼顾单连接速度与多连接聚合吞吐的服务器；
- 需要保留测试日志、调优报告和安全回滚能力的环境。

脚本只修改远程服务器。你的本地电脑只运行服务器显示的 `iperf3` 测速命令，不会修改本地 TCP 参数。

---

## 一键安装并启动

在远程服务器执行：

```bash
curl -fsSL https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash
```

安装完成后会直接打开交互界面。

如果服务器没有 `curl`，可以使用：

```bash
wget -qO- https://raw.githubusercontent.com/dingding229/bbr-tune/main/install.sh | sudo bash
```

一键脚本会完成以下操作：

1. 检查 Linux 和 root 权限；
2. 补齐 `iproute2`、`procps`、`kmod` 等基础依赖；
3. 下载并检查最新的 `bbr-tune.sh`；
4. 安装到 `/usr/local/sbin/bbr-tune`；
5. 创建命令入口 `/usr/local/bin/bbr-tune`；
6. 启动交互式调优界面。

以后重新进入工具，只需执行：

```bash
sudo bbr-tune
```

同一条一键安装命令也可用于更新到最新版。

### 只安装，不立即启动

下载仓库后执行：

```bash
git clone https://github.com/dingding229/bbr-tune.git
cd bbr-tune
sudo ./install.sh --install-only
```

然后手动启动：

```bash
sudo bbr-tune
```

---

## 交互菜单

```text
╔══════════════════════════════════════════════════════════════╗
║        远程服务器 TCP / BBR 自动寻优工具 v2.3.0             ║
╚══════════════════════════════════════════════════════════════╝

  1) 自动测试并选择最优 TCP 参数
  2) 查看当前 TCP / BBR 状态
  3) 查看历史测试与对比记录
  4) 确认保留当前参数
  5) 恢复调优前参数
  6) 使用说明
  0) 退出
```

第一次使用选择 `1`，然后根据界面填写：

- 期望端到端下载带宽；
- 服务器公网 IP 或域名；
- 多连接测试并发数，默认 `8`；
- 每次测试持续时间，默认 `15` 秒；
- 目标带宽利用率，默认 `90%`；
- 最大估算重传率，默认 `1%`；
- 是否将最终参数写入开机配置。

---

## 目标带宽应该填写什么

测试方向固定为：

```text
远程服务器 ───── 下载流量 ─────> 本地电脑
```

因此，目标带宽表示这条端到端下载链路期望达到的上限。建议填写以下限制中的最小值：

```text
min(
  云服务器或宿主机出站带宽上限,
  服务器物理端口上限,
  本地下载带宽上限,
  已知的中间链路上限
)
```

示例：

| 服务器出站上限 | 本地下载上限 | 建议填写 |
|---:|---:|---:|
| 200 Mbps | 1000 Mbps | 200 Mbps |
| 1000 Mbps | 500 Mbps | 500 Mbps |
| 1000 Mbps | 1000 Mbps，但跨境路径约 300 Mbps | 300 Mbps |

目标带宽只用于计算 BDP、判断达标状态和生成评分，不会在任一端实施限速。

---

## 本地电脑需要做什么

每次测试开始时，服务器会启动一个随机未占用端口，并显示本地命令。

单连接示例：

```bash
iperf3 -c <服务器IP> -p 43817 -R -P 1 -t 15 -i 1
```

多连接示例：

```bash
iperf3 -c <服务器IP> -p 43817 -R -P 8 -t 15 -i 1
```

你只需要在本地电脑依次执行服务器显示的命令。

本地电脑不会发生以下变化：

- 不修改 TCP 参数；
- 不修改拥塞控制算法；
- 不修改 qdisc；
- 不修改路由或防火墙；
- 不自动安装软件。

如果本地没有 `iperf3`，需要自行安装客户端。服务器缺少 `iperf3` 时，主程序会自动安装。

---

## 自动寻优流程

### 1. 建立调优前基线

工具首先分别测试：

- 单连接：固定使用 `-P 1`；
- 多连接：默认使用 `-P 8`，也可以在界面中修改。

同时从 iperf3 JSON、Linux TCP socket 或 ICMP ping 自动测量端到端 RTT。

### 2. 计算 BDP 和缓存范围

```text
BDP = 目标带宽 × RTT ÷ 8
```

候选缓存从接近一个 BDP 的值开始增长。

### 3. 持续扩大缓存

工具不会限制候选数量，而是持续倍增缓存并重复测试单连接和多连接性能。

### 4. 检测性能边界

如果综合评分明显下降，或者单连接、多连接中的任一项低于基线保护线，则认为已经接近或超过性能边界。

### 5. 回退精调

检测到回落后，工具会在最后一个安全值和越界值之间进行二分搜索，精调到 `1 MiB` 粒度。

### 6. 最终复核

最优候选会重新执行一组单连接和多连接测试。复核退化时，服务器自动恢复调优前配置。

---

## 单连接和多连接如何平衡

工具不会只追求多连接总速度。

每个候选都必须满足：

```text
候选单连接吞吐 ≥ 调优前单连接吞吐 × 95%
候选多连接吞吐 ≥ 调优前多连接吞吐 × 95%
```

单连接和多连接分别计算质量分，再使用调和均值生成综合评分。调和均值会惩罚以下情况：

- 多连接吞吐提升，但单连接明显下降；
- 单连接提升，但多连接聚合吞吐明显下降；
- 吞吐提高，但重传率大幅恶化。

最终选择的是当前测试时段下，单连接和多连接表现最均衡的参数，而不是某一项的单独最高值。

---

## TCP 内存策略

该工具面向专用网络代理服务器，采用较积极的 TCP 聚合内存预算：

```text
有效总内存 = min(服务器物理总内存, cgroup 总内存上限)
TCP 聚合内存预算 = 有效总内存 × 2 / 3
```

`net.ipv4.tcp_mem` 设置为：

```text
low      = 有效总内存 × 1 / 3
pressure = 有效总内存 × 1 / 2
high     = 有效总内存 × 2 / 3
```

单 socket 缓存搜索上限为：

```text
min(TCP 聚合内存预算, 2047 MiB)
```

`2047 MiB` 用于规避常见 Linux 内核中字节型 sysctl 的有符号整数上限。系统级 TCP 聚合预算仍可高于该值。

| 有效总内存 | TCP 聚合预算 | 单 socket 搜索上限 |
|---:|---:|---:|
| 256 MiB | 170 MiB | 170 MiB |
| 1 GiB | 682 MiB | 682 MiB |
| 2 GiB | 1365 MiB | 1365 MiB |
| 4 GiB | 2730 MiB | 2047 MiB |
| 8 GiB | 5461 MiB | 2047 MiB |
| 16 GiB | 10922 MiB | 2047 MiB |

这些数值是内核 TCP 自动内存管理可使用的上限，不代表启动后立即分配对应数量的物理内存。

> `2/3` 内存策略适合专用代理服务器。如果服务器还运行数据库、编译任务或其他高内存业务，请先评估整体内存需求。

---

## 实际修改的服务器参数

```text
net.ipv4.tcp_congestion_control
net.core.default_qdisc
net.core.rmem_max
net.core.wmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_mem
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_sack
net.ipv4.tcp_dsack
net.ipv4.tcp_window_scaling
```

主程序不会修改本地电脑，也不会自动修改云安全组或服务器防火墙。

---

## 测试报告和日志

每次运行都会创建独立目录：

```text
/var/lib/bbr-tcp-tuning/sessions/<时间戳-PID>/
```

主要文件：

```text
run.log                 完整运行日志
results.tsv             每轮结构化测试数据
comparison.txt          格式化的 TCP/BBR 参数评估报告
system-before.txt       调优前系统状态
system-after.txt        调优后系统状态
before-*.json           基线 iperf3 原始数据
candidate-*.json        候选参数 iperf3 原始数据
final-*.json            最终复核原始数据
*.rtt-samples           TCP RTT 采样
*.err                   测试错误输出
```

`comparison.txt` 使用适合 SSH 终端阅读的分段格式，不依赖 Markdown 表格渲染，内容包括：

1. 执行结论；
2. 评估方法；
3. 测试环境；
4. 内存和缓存策略；
5. 单连接与多连接性能对比；
6. 内核参数对比；
7. 最优候选；
8. 逐轮测试明细；
9. 审计文件位置。

跨时段汇总记录：

```text
/var/lib/bbr-tcp-tuning/history.tsv
```

查看历史记录：

```bash
bbr-tune history
```

---

## 常用命令

### 启动交互界面

```bash
sudo bbr-tune
```

### 查看当前状态

```bash
bbr-tune status
```

### 查看历史记录

```bash
bbr-tune history
```

### 确认保留参数

调优完成后，请通过另一个 SSH 会话确认服务器网络正常，然后执行：

```bash
sudo bbr-tune confirm
```

### 立即恢复调优前参数

```bash
sudo bbr-tune rollback --yes
```

### 命令行直接启动寻优

```bash
sudo bbr-tune autotune \
  --bandwidth-mbps 1000 \
  --server-address <服务器公网IP或域名> \
  --parallel 8 \
  --duration 15 \
  --target-utilization 90 \
  --max-retrans-percent 1 \
  --persist
```

---

## 安全机制

- 每次测试使用 `20000～59999` 范围内的随机未占用端口；
- 每次等待本地连接最多 `300` 秒；
- 参数应用后保留 `3600` 秒安全回滚窗口；
- 异常退出、测试超时或中断时立即尝试恢复原配置；
- 最终复核低于保护条件时自动恢复原配置；
- 检测到复杂自定义 root qdisc 时默认拒绝覆盖；
- 新会话会取消上一会话遗留的回滚计时器，并以当前配置重新建立基线。

脚本不会自动开放云安全组或服务器防火墙。测试前请允许界面显示的随机 TCP 端口。

---

## 支持的服务器系统

主程序仅支持 Linux。依赖安装支持以下包管理器：

```text
apt-get
dnf
yum
zypper
apk
pacman
```

服务器内核必须支持 BBR 和 `fq`。

---

## 手动运行仓库版本

如果不希望安装到系统目录：

```bash
git clone https://github.com/dingding229/bbr-tune.git
cd bbr-tune
chmod +x bbr-tune.sh
sudo ./bbr-tune.sh
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

测试覆盖：

- 一键安装和命令入口；
- 内存预算与 `tcp_mem` 阈值；
- BDP 和候选缓存生成；
- 单连接、多连接基线保护；
- 均衡评分与性能边界回退；
- iperf3 自动安装；
- JSON、RTT 和重传解析；
- 随机端口检测；
- 安全回滚；
- 格式化评估报告和历史记录。
