# 远程服务器 TCP / BBR 自动寻优工具

`bbr-tune.sh` 是一个运行在 **远程 Linux 服务器** 上的 TCP/BBR 自动测试与参数寻优脚本。

脚本只调整服务器端最核心的 TCP 参数：

- `net.ipv4.tcp_congestion_control = bbr`
- `net.core.default_qdisc = fq`
- `net.core.rmem_max` / `net.core.wmem_max`
- `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem`
- `tcp_moderate_rcvbuf`、SACK、DSACK、窗口缩放

已移除手动场景 Profile、固定 TBF 方案、独立 iperf3 服务管理、手工计划生成等非核心流程。现在的主流程是：**基线测试 → 内存感知候选生成 → 多轮实测 → 性能平台判断 → 最优候选复测 → 前后对比与日志留存**。

> 本地电脑只运行脚本显示的 `iperf3 -c ... -R` 命令。脚本不会修改本地电脑的 TCP、路由、qdisc、防火墙或软件包。

## 一、核心特性

### 1. 自动测试并选择实测最优值

脚本不再遇到第一个达标参数就结束，而是：

1. 测试服务器调优前性能；
2. 单流低重传但吞吐不足时，自动继续测试 8 流和 16 流；
3. 根据 BDP 和服务器可用内存生成多组 TCP 缓存候选；
4. 逐组应用并等待本地反向测速；
5. 综合吞吐、重传率和达标情况计算候选分数；
6. 连续两个更大缓存没有改善时判定进入性能平台；
7. 重新应用并复测最优候选；
8. 如果复测低于调优前基线，自动恢复原参数。

### 2. 按服务器内存计算缓存上限

不再使用固定的 `128 MiB` 上限。脚本读取：

- `/proc/meminfo` 的物理内存和可用内存；
- cgroup v1/v2 内存限制；
- 链路 BDP；
- 用户设置的目标带宽和 RTT。

默认单连接 TCP 缓存预算约为：

```text
min(有效总内存 / 64, 当前可用内存 / 16, 256 MiB)
```

随后向下取 2 的幂，并保持至少 `4 MiB`。因此缓存预算会随服务器规格变化，例如：

| 有效内存 | 典型自动上限 |
|---:|---:|
| 256 MiB | 4 MiB |
| 1 GiB | 16 MiB |
| 2 GiB | 32 MiB |
| 4 GiB | 64 MiB |
| 8 GiB | 128 MiB |
| 16 GiB 及以上 | 最高 256 MiB，同时受可用内存约束 |

候选值按 BDP 的 `1.0、1.5、2.0、3.0、4.0` 倍生成，向上取 2 的幂，并受上述内存预算限制。重复候选会自动去除。

### 3. 完整运行日志和时间段对比

每次运行创建独立会话目录：

```text
/var/lib/bbr-tcp-tuning/sessions/<时间戳-PID>/
```

其中包括：

```text
run.log                 屏幕输出和测试运行日志
results.tsv             每一轮的参数、吞吐、Retr、重传率和评分
comparison.txt          调优前后详细对比
system-before.txt       调优前 sysctl、qdisc、TCP 计数器
system-after.txt        调优后 sysctl、qdisc、TCP 计数器
before-*.json           调优前原始 iperf3 JSON
candidate-*.json        每个候选的原始 iperf3 JSON
final-*.json            最优候选复测 JSON
*.err                    对应测试的错误输出
```

跨时间段汇总保存在：

```text
/var/lib/bbr-tcp-tuning/history.tsv
```

可通过菜单或命令查看：

```bash
./bbr-tune.sh history
```

## 二、安装与运行

在服务器上执行：

```bash
git clone https://github.com/dingding229/bbr-tune.git
cd bbr-tune
chmod +x bbr-tune.sh
sudo ./bbr-tune.sh
```

如果服务器没有 `iperf3`，脚本会使用以下包管理器之一自动安装：

```text
apt-get / dnf / yum / zypper / apk / pacman
```

不会额外安装 `jq`。解析测试结果时优先使用服务器已有的 Python 3；没有 Python 3 时使用内置 `awk` 解析器。

## 三、精简后的交互界面

```text
╔══════════════════════════════════════════════════════════════╗
║        远程服务器 TCP / BBR 自动寻优工具 v2.0.0             ║
╚══════════════════════════════════════════════════════════════╝

  1) 自动测试并选择最优 TCP 参数
  2) 查看当前 TCP / BBR 状态
  3) 查看历史测试与对比记录
  4) 确认保留当前参数
  5) 恢复调优前参数
  6) 使用说明
  0) 退出
```

交互界面只保留自动寻优、状态、历史、确认和回滚等核心操作。

## 四、命令行自动寻优

先在本地测量 RTT：

```bash
ping -c 20 <服务器IP>
```

然后在远程服务器执行：

```bash
sudo ./bbr-tune.sh autotune \
  --bandwidth-mbps 1000 \
  --rtt-ms 180 \
  --server-address <服务器公网IP或域名> \
  --parallel 1 \
  --duration 15 \
  --max-candidates 4 \
  --target-utilization 90 \
  --max-retrans-percent 1 \
  --wait-seconds 300 \
  --auto-rollback-seconds 3600
```

每轮服务器会显示一个随机端口和本地测试命令，例如：

```bash
iperf3 -c <服务器IP> -p 43817 -R -P 1 -t 15 -i 1
```

如果检测到低重传、低单流吞吐，后续命令会自动变为：

```bash
iperf3 -c <服务器IP> -p 43817 -R -P 8 -t 15 -i 1
iperf3 -c <服务器IP> -p 43817 -R -P 16 -t 15 -i 1
```

脚本测试时每 5 秒显示等待/运行状态；测试完成后输出每秒吞吐和 Retr 区间日志，以及本轮汇总结果。

## 五、最优参数判定

每轮计算：

```text
最低达标吞吐 = 目标带宽 × target-utilization
估算重传比例 = Retr × 1448 / 发送字节数 × 100%
```

评分优先级：

1. 同时满足吞吐和重传阈值的候选优先；
2. 未达标候选按吞吐完成度评分；
3. 超过重传阈值会扣分；
4. 连续两个更大缓存没有提升时停止扩大缓存；
5. 最优候选必须再次复测；
6. 复测低于原始基线时恢复原参数。

默认最多测试 4 个不同候选，可使用：

```bash
--max-candidates 1..6
```

增加候选数意味着需要在本地执行更多轮 iperf3 命令。

## 六、调优前后详细对比

结束后屏幕和 `comparison.txt` 会显示：

- 内核和出口网卡；
- 服务器总内存、可用内存、cgroup 内存上限；
- 自动计算的 TCP 缓存预算；
- BDP；
- 调优前后拥塞算法；
- 调优前后 qdisc；
- 调优前后 `tcp_rmem` / `tcp_wmem`；
- 调优前后全局缓存上限；
- 调优前后吞吐；
- 调优前后 Retr 和估算重传比例；
- 吞吐变化百分比；
- 重传比例变化；
- 最优 BDP 系数；
- 是否检测到单流 QoS 特征；
- 原始日志及结果文件位置。

## 七、持久化、确认和回滚

默认只保留当前运行时最优参数。需要同时写入开机配置时增加：

```bash
--persist
```

持久化文件：

```text
/etc/sysctl.d/99-bbr-tcp-tuning.conf
/etc/modules-load.d/bbr-tcp-tuning.conf
/etc/default/bbr-tcp-tuning
/usr/local/sbin/bbr-tcp-qdisc
/etc/systemd/system/bbr-tcp-tuning.service
```

每次开始修改前都会备份原配置并建立安全回滚。测试完成后请另开一个 SSH 会话检查服务器，然后执行：

```bash
sudo ./bbr-tune.sh confirm
```

立即恢复调优前参数：

```bash
sudo ./bbr-tune.sh rollback --yes
```

如果脚本异常退出、测试超时或被中断，会立即尝试恢复原参数；安全计时器仍作为第二层保护。

## 八、安全说明

1. 脚本必须在远程 Linux 服务器运行。
2. 脚本不会修改本地电脑。
3. 随机测试端口范围为 `20000～59999`，脚本不会自动修改防火墙或云安全组。
4. 如安全组不能开放该范围，需要在测试时临时允许屏幕显示的端口。
5. 检测到自定义 root qdisc 时默认拒绝覆盖；确认可以覆盖后才能使用 `--force`。
6. 自定义复杂 qdisc 的 class/filter 无法通用重建，使用 `--force` 前应自行备份。
7. 不应在执行 `confirm` 前移动或删除脚本，否则安全回滚任务可能找不到脚本。
8. 单流 QoS、物理线路上限、接收端性能及运营商策略无法仅靠服务器 TCP 参数消除。

## 九、开发测试

```bash
bash -n bbr-tune.sh
bash tests/test-plan.sh
bash tests/test-autotune-logic.sh
bash tests/test-remote-logic.sh
```

当前单元测试覆盖：

- 内存感知缓存预算；
- BDP 和候选参数生成；
- iperf3 自动安装；
- Python/awk JSON 解析；
- 吞吐、重传和评分判断；
- 1/8/16 流测试递进；
- 随机端口和端口占用检测；
- 安全回滚标记；
- 调优前后对比文件。
