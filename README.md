# 远程服务器 BBR / TCP 交互调优脚本

`bbr-tune.sh` 必须上传并运行在需要调优的 **远程 Linux 服务器** 上。脚本在服务器侧管理 BBR、TCP socket buffer、出口 qdisc、备份与回滚；本地电脑只执行脚本打印的 `ping` 和 `iperf3 -c ... -R` 命令。

> 脚本不会修改本地电脑的 sysctl、拥塞算法、路由、qdisc、防火墙或软件包。

## 功能概览

- 缺少 `iperf3` 时，使用服务器包管理器自动安装；
- 每次测速自动在 `20000～59999` 中选择未占用的随机 TCP 端口；
- 本地客户端执行反向测速，服务器端自动读取 `iperf3` JSON 结果；
- 根据吞吐和估算重传比例多轮调整服务器参数；
- 达标后保留最终运行时参数，可选择持久化；
- 达不到条件、执行出错或收到中断时恢复调优前基线；
- 修改出口 qdisc 前建立 SSH 安全回滚任务。

## 一、运行位置和测速方向

| 位置 | 命令 | 作用 |
|---|---|---|
| 远程服务器 | `sudo ./bbr-tune.sh` | 交互检测、自动调优、持久化和回滚 |
| 远程服务器 | `iperf3 -s -1 -J -p <随机端口>` | 由脚本自动启动的一次性测试服务 |
| 本地客户端 | `ping <服务器IP>` | 测量端到端 RTT |
| 本地客户端 | `iperf3 -c <服务器IP> -p <随机端口> -R ...` | 测量服务器到本地的回程吞吐 |

服务器不会反向运行 `iperf3 -c` 连接本地电脑，因此不要求本地电脑具有公网地址。

## 二、安装与启动

在本地电脑把脚本上传到服务器：

```bash
scp bbr-tune.sh root@<服务器IP>:/root/
ssh root@<服务器IP>
chmod +x /root/bbr-tune.sh
sudo /root/bbr-tune.sh
```

也可以从 GitHub 下载：

```bash
git clone https://github.com/dingding229/bbr-tune.git
cd bbr-tune
sudo ./bbr-tune.sh
```

支持的 `iperf3` 自动安装包管理器：`apt-get`、`dnf`、`yum`、`zypper`、`apk`、`pacman`。自动闭环解析优先使用服务器已有的 Python 3，没有 Python 3 时使用脚本内置的 `awk` 解析器，不会额外安装 `jq`。

## 三、交互菜单

```text
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
```

## 四、推荐：自动闭环调优

### 1. 先在本地测量 RTT

```bash
ping -c 20 <服务器IP>
```

### 2. 在远程服务器启动自动调优

交互菜单选择 `3`，或直接执行：

```bash
sudo ./bbr-tune.sh autotune \
  --profile auto \
  --bandwidth-mbps 1000 \
  --rtt-ms 180 \
  --parallel 8 \
  --duration 15 \
  --target-utilization 90 \
  --max-retrans-percent 1 \
  --max-iterations 4 \
  --test-wait-seconds 300 \
  --auto-rollback-seconds 3600 \
  --server-address <服务器公网IP或域名>
```

脚本会自动：

1. 检查并安装服务器端 `iperf3`；
2. 选择一个未占用的随机端口；
3. 启动基线测试服务并打印本地客户端命令；
4. 由服务器读取测试结果；
5. 如果基线已经达标，不修改任何 TCP/BBR 参数；
6. 如果未达标，备份服务器基线并建立自动回滚；
7. 应用一组服务器参数，等待下一轮本地测试；
8. 达标则停止，未达标则继续调整，最多执行指定轮数；
9. 所有候选方案都不达标时自动恢复原始服务器配置。

每一轮都需要在 **本地电脑** 执行服务器屏幕上新打印的命令，例如：

```bash
iperf3 -c <服务器IP> -p 43817 -R -P 8 -t 15 -i 1
```

脚本只会显示命令，不会在本地电脑运行或安装任何东西。

### 3. 自动调整规则

每轮同时检查：

```text
吞吐 >= 目标带宽 × target-utilization
估算重传比例 <= max-retrans-percent
```

估算重传比例使用服务器发送端统计：

```text
Retr × 1448 / 发送字节数 × 100%
```

自动策略：

- **重传超标**：启用或收紧服务器出口 TBF 预整形，并在其下使用 `fq`；
- **重传已受控但吞吐不足**：按 `1.35 → 2.0 → 3.0 → 4.0` 提高 BDP 缓冲系数；
- **整形安全下限**：至少保留目标利用率上方约 2 个百分点，避免为了降重传而必然破坏吞吐目标；
- **无安全调整空间**：提前停止并恢复服务器基线。

自动调优默认只修改当前运行时。希望达标后写入持久化配置时，增加：

```bash
--persist-on-success
```

### 4. 确认或回滚

达标后，先另开一个 SSH 会话验证登录和业务，再确认保留：

```bash
sudo ./bbr-tune.sh confirm
```

如需立即恢复：

```bash
sudo ./bbr-tune.sh rollback --yes
```

未执行 `confirm` 时，安全计时器到期会自动回滚。

## 五、单独管理 iperf3 服务

启动时自动安装 `iperf3`，并自动选择随机空闲端口：

```bash
sudo ./bbr-tune.sh iperf-start \
  --iperf-port 0 \
  --server-address <服务器公网IP或域名>
```

查看实际端口和本地客户端命令：

```bash
./bbr-tune.sh iperf-status \
  --server-address <服务器公网IP或域名>
```

停止服务：

```bash
sudo ./bbr-tune.sh iperf-stop
```

也可以显式指定端口，但默认和推荐值是 `0`，代表自动随机端口。

## 六、场景模型

| Profile | 场景 | 服务器动作 |
|---|---|---|
| `auto` | 让脚本按 RTT 和实测结果判断 | 自动选择以下方案并在必要时切换预整形 |
| `balanced` | 短/中 RTT 常规线路 | BBR + fq |
| `hard-cap` | 宿主机、网关或端口硬限速 | TBF 预整形 + fq |
| `qos` | 单流明显低于多流 | BBR + fq；测试和业务使用并发流 |
| `lfn` | 跨洋高 RTT、大 BDP | 扩大 socket buffer 上限 + fq |
| `lossy` | 随机丢包和抖动 | BBR + fq + SACK/DSACK |

BDP 计算：

```text
BDP_bytes = bandwidth_mbps × 1,000,000 × RTT_ms / 1000 / 8
buffer = BDP_bytes × buffer_factor
```

推荐缓冲值向上取 2 的幂次 MiB，默认限制为 `2～128 MiB`。除非显式使用 `--allow-buffer-shrink`，脚本不会把服务器已有的更大全局 buffer 上限调低。

## 七、结果、持久化与文件

每次自动调优结果保存在：

```text
/var/lib/bbr-tcp-tuning/autotune/<时间戳>/results.tsv
```

每轮原始 `iperf3` JSON 和错误输出也保存在该目录。

持久化配置包括：

```text
/etc/sysctl.d/99-bbr-tcp-tuning.conf
/etc/modules-load.d/bbr-tcp-tuning.conf
/etc/default/bbr-tcp-tuning
/usr/local/sbin/bbr-tcp-qdisc
/etc/systemd/system/bbr-tcp-tuning.service
/var/lib/bbr-tcp-tuning/backups/<时间戳>/
```

## 八、安全边界

1. 脚本只在远程服务器修改 TCP/BBR/qdisc；不会修改本地客户端。
2. 脚本会自动安装服务器端 `iperf3`，但不会自动修改服务器防火墙或云安全组。
3. 随机端口来自 `20000～59999`。必须在云安全组/防火墙中允许显示的端口；也可临时允许该范围后再收紧。
4. 修改出口 qdisc 可能影响 SSH，因此自动调优在修改前创建备份并启动安全回滚。
5. 检测到 `cake`、`htb`、`netem`、`mqprio`、`taprio` 等自定义 root qdisc 时，默认拒绝覆盖；审计后可显式使用 `--force`。
6. 通用回滚无法完整重建任意复杂的 class/filter 树，原始 `tc -s -d qdisc` 输出会保存在备份目录。
7. 自动回滚依赖脚本文件在计时结束前保持原路径，请勿在确认前移动或删除脚本。
8. 自动调优是工程化试探，不保证所有跨境线路都能达到目标；运营商单流 QoS、物理丢包和云厂商 policer 仍可能成为外部上限。

## 九、开发测试

```bash
bash -n bbr-tune.sh
bash tests/test-plan.sh
bash tests/test-remote-logic.sh
bash tests/test-autotune-logic.sh
```

测试覆盖 BDP 方案、远程角色方向、SSH 回滚标记、iperf JSON 解析、达标判断、自动调整规则和随机端口选择。真正的 `tc`、`sysctl`、systemd 和发行版包管理器行为仍需在 Linux 测试机验证。
