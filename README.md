# 远程服务器 TCP / BBR 自动寻优工具

`bbr-tune.sh` 是一个运行在 **远程 Linux 服务器** 上的交互式 TCP/BBR 自动测试与参数寻优脚本。

脚本只修改服务器端最核心的 TCP 参数：

- `net.ipv4.tcp_congestion_control = bbr`
- `net.core.default_qdisc = fq`
- `net.core.rmem_max` / `net.core.wmem_max`
- `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem`
- `tcp_moderate_rcvbuf`、SACK、DSACK、TCP 窗口缩放

> 本地电脑只运行脚本显示的 `iperf3 -c ... -R` 命令。脚本不会修改本地电脑的 TCP、路由、qdisc、防火墙、系统参数或软件包。

## 一、目标带宽到底填什么

测试方向固定为：

```text
远程服务器  ─────下载流量─────>  本地电脑
```

因此 `目标带宽 Mbps` 指 **这条端到端下载链路期望达到的上限**，不是只看服务器网卡，也不是只看本地宽带套餐。

建议填写下面几个上限中的较小值：

```text
min(
  云服务器或宿主机出站限速,
  服务器物理端口上限,
  本地电脑下载带宽上限,
  已知的中间链路上限
)
```

示例：

- 服务器出站限制 `200 Mbps`，本地下载 `1000 Mbps`：填写 `200`。
- 服务器端口 `1000 Mbps`，本地下载 `500 Mbps`：填写 `500`。
- 两端都是千兆，但已知跨境线路通常只有 `300 Mbps`：可填写 `300`。

这个数值只用于计算 BDP、达标门槛和候选评分，不会对本地网络做任何设置。

## 二、自动寻优流程

版本 `2.1.0` 的流程如下：

1. 检查服务器依赖，缺少 `iperf3` 时自动安装。
2. 从 `20000～59999` 选择一个未占用的随机 TCP 端口。
3. 保存服务器调优前的 TCP、qdisc 和内存状态。
4. 运行调优前反向测速。
5. 从 iperf3 JSON 或服务器 TCP socket 自动取得本地与服务器之间的 RTT；必要时使用 ICMP ping 作为备用来源。
6. 单流低重传但吞吐不足时，自动继续测试 8 流和 16 流，识别单流 QoS。
7. 根据目标带宽、实测 RTT 和服务器总内存计算 BDP 与 TCP 缓存安全上限。
8. 从接近一个 BDP 的缓存开始倍增测试，不设置人工候选数量上限。
9. 当更大缓存导致评分明显回落时，判定已越过性能边界。
10. 在最后一个最优值与越界值之间二分回退，持续精调到 `1 MiB` 粒度。
11. 重新应用实测分数最高的参数并进行最终复测。
12. 若最终复测低于调优前基线，自动恢复原参数。
13. 输出通俗的前后对比，并保留全部日志供不同时段比较。

候选数量没有固定的 `4`、`6` 等上限。实际测试轮数由 BDP、总内存预算以及性能边界共同决定。

## 三、RTT 自动测量

不再要求手工填写 RTT，也不再需要先在本地运行 ping。

首轮 iperf3 测试期间，脚本按以下顺序自动获取 RTT：

1. iperf3 JSON 的 TCP `mean_rtt`；
2. Linux `ss -tin` 的实时 TCP socket RTT；
3. 对已识别客户端地址执行 ICMP ping 作为备用。

最终采用的 RTT 数值和来源会显示在屏幕、`results.tsv` 和 `comparison.txt` 中。

## 四、按服务器总内存计算缓存

缓存预算 **不使用当前可用内存决定**。脚本使用：

```text
分档总内存 = min(服务器物理总内存, cgroup 总内存上限)
TCP 单连接缓存预算 ≈ 分档总内存 / 64
```

结果向下取 2 的幂，最低 `4 MiB`，绝对安全上限为 `1024 MiB`。

| 分档总内存 | TCP 缓存预算 |
|---:|---:|
| 256 MiB | 4 MiB |
| 512 MiB | 8 MiB |
| 1 GiB | 16 MiB |
| 2 GiB | 32 MiB |
| 4 GiB | 64 MiB |
| 8 GiB | 128 MiB |
| 16 GiB | 256 MiB |
| 32 GiB | 512 MiB |
| 64 GiB 及以上 | 最高 1024 MiB |

`MemAvailable` 仍会写入日志，便于排查服务器负载，但不会参与缓存上限计算。

这些 sysctl 数值是 TCP 自动调节可以使用的上限，并不代表脚本启动后立即为每个连接分配同等大小的物理内存。

## 五、安装与运行

在远程服务器执行：

```bash
git clone https://github.com/dingding229/bbr-tune.git
cd bbr-tune
chmod +x bbr-tune.sh
sudo ./bbr-tune.sh
```

交互菜单：

```text
╔══════════════════════════════════════════════════════════════╗
║        远程服务器 TCP / BBR 自动寻优工具 v2.1.0             ║
╚══════════════════════════════════════════════════════════════╝

  1) 自动测试并选择最优 TCP 参数
  2) 查看当前 TCP / BBR 状态
  3) 查看历史测试与对比记录
  4) 确认保留当前参数
  5) 恢复调优前参数
  6) 使用说明
  0) 退出
```

命令行方式：

```bash
sudo ./bbr-tune.sh autotune \
  --bandwidth-mbps 1000 \
  --server-address <服务器公网IP或域名> \
  --parallel 1 \
  --duration 15 \
  --target-utilization 90 \
  --max-retrans-percent 1
```

可选增加 `--persist`，在最终复测通过后写入开机配置：

```bash
sudo ./bbr-tune.sh autotune \
  --bandwidth-mbps 1000 \
  --server-address <服务器公网IP或域名> \
  --persist
```

### 固定安全默认值

以下两项使用脚本安全默认值，不在交互界面中询问，也没有命令行设置项：

```text
每轮等待本地连接：300 秒
安全自动回滚窗口：3600 秒
```

每轮服务器会显示本地应执行的命令，例如：

```bash
iperf3 -c <服务器IP> -p 43817 -R -P 1 -t 15 -i 1
```

脚本每 5 秒显示等待或运行状态，测试完成后显示逐秒吞吐、Retr、总吞吐、重传率、RTT 和是否达标。

## 六、依赖与兼容性

缺少 `iperf3` 时，脚本会在服务器使用以下包管理器之一自动安装：

```text
apt-get / dnf / yum / zypper / apk / pacman
```

不会在本地电脑安装任何内容，也不会额外安装 `jq`。JSON 解析优先使用服务器已有的 Python 3；没有 Python 3 时使用内置 `awk` 解析器。

服务器内核必须支持 BBR 和 `fq`。脚本仅支持 Linux，建议使用 Bash 4 或更高版本。

## 七、日志和通俗对比

每次运行创建独立目录：

```text
/var/lib/bbr-tcp-tuning/sessions/<时间戳-PID>/
```

主要文件：

```text
run.log                 完整屏幕输出与运行日志
results.tsv             每轮参数、RTT、吞吐、Retr、重传率、评分
comparison.txt          通俗的调优前后对比和逐轮表格
system-before.txt       调优前 sysctl、qdisc、TCP 计数器
system-after.txt        调优后 sysctl、qdisc、TCP 计数器
before-*.json           调优前原始 iperf3 JSON
candidate-*.json        候选参数原始 iperf3 JSON
final-*.json            最优参数复测 JSON
*.rtt-samples           测试期间采集的 TCP RTT
*.err                   对应测试的错误输出
```

`comparison.txt` 会直接说明：

- 下载速度提高、下降还是基本不变；
- 重传率改善、恶化还是基本不变；
- 是否检测到缓存过大导致的性能回落；
- 调优前后使用的算法、队列和缓存；
- 最终是否保留新参数或恢复原参数；
- 每个候选的测试结果。

跨时间段汇总保存在：

```text
/var/lib/bbr-tcp-tuning/history.tsv
```

查看格式化历史：

```bash
./bbr-tune.sh history
```

## 八、最优参数判定

每轮计算：

```text
最低达标吞吐 = 目标带宽 × target-utilization
估算重传率 = Retr × 1448 / 发送字节数 × 100%
```

评分原则：

1. 同时满足吞吐和重传阈值的候选优先；
2. 吞吐越接近目标，评分越高；
3. 超过重传阈值会扣分；
4. 相比当前最优分数明显下降时，认定缓存已越过性能边界；
5. 越界后自动退回并在区间内二分精调；
6. 选中的最优候选必须再次复测；
7. 最终复测低于原始基线时恢复原配置。

网络存在随机波动，所谓“最优”是本次测试时段、当前客户端和当前路由下的实测最优值。建议在早晚高峰分别运行并通过历史日志比较。

## 九、持久化、确认和回滚

默认只在当前运行时应用最优参数。增加 `--persist` 后会写入：

```text
/etc/sysctl.d/99-bbr-tcp-tuning.conf
/etc/modules-load.d/bbr-tcp-tuning.conf
/etc/default/bbr-tcp-tuning
/usr/local/sbin/bbr-tcp-qdisc
/etc/systemd/system/bbr-tcp-tuning.service
```

调优完成后，请另开一个 SSH 会话确认服务器正常，并在 3600 秒内执行：

```bash
sudo ./bbr-tune.sh confirm
```

立即恢复调优前参数：

```bash
sudo ./bbr-tune.sh rollback --yes
```

脚本异常退出、测试超时或收到中断信号时，会立即尝试恢复调优前参数；独立安全计时器作为第二层保护。

## 十、安全说明

1. 脚本必须在远程 Linux 服务器运行。
2. 脚本只修改服务器 TCP/BBR 参数，不修改本地电脑。
3. 随机测试端口范围为 `20000～59999`。
4. 脚本不会修改云安全组或服务器防火墙，请临时允许屏幕显示的 TCP 端口。
5. 检测到自定义 root qdisc 时默认拒绝覆盖；明确了解风险后才使用 `--force`。
6. 自定义复杂 qdisc 的 class/filter 无法通用重建，使用 `--force` 前应自行备份。
7. 在执行 `confirm` 前不要移动或删除脚本，否则安全回滚任务可能无法找到脚本。
8. 单流 QoS、物理线路上限、本地接收性能及运营商策略无法仅靠服务器 TCP 参数消除。

## 十一、开发测试

```bash
bash -n bbr-tune.sh
bash tests/test-plan.sh
bash tests/test-autotune-logic.sh
bash tests/test-remote-logic.sh
```

测试覆盖：

- 只按总内存计算缓存预算；
- 自动 BDP 与无限制倍增候选生成；
- 性能越界判断和二分回退；
- iperf3 自动安装；
- Python/awk JSON、RTT 和客户端地址解析；
- 1/8/16 流测试递进；
- 随机端口和端口占用检测；
- 安全回滚标记；
- 格式化的调优前后对比文件。
