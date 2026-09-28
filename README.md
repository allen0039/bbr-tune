# 远程服务器 BBR / TCP 交互调优脚本

`bbr-tune.sh` 应当上传并运行在需要调优的 **远程 Linux 服务器** 上。它负责检查和修改服务器的 `sysctl`、BBR 与出口 qdisc，并可在服务器上启动临时 `iperf3 -s`。

本地电脑只负责：

- Ping 远程服务器并测量端到端 RTT；
- 使用 `iperf3 -c <服务器> -R` 测量服务器到本地的回程吞吐；
- 通过 SSH 操作服务器上的脚本。

## 一、角色与方向

| 位置 | 应执行的命令 | 作用 |
|---|---|---|
| 远程服务器 | `sudo ./bbr-tune.sh` | 交互调优、qdisc、sysctl、备份和回滚 |
| 远程服务器 | `iperf3 -s -p 5201` | 等待本地客户端连接；脚本可代为启动 |
| 本地客户端 | `ping <服务器IP>` | 测量本地到服务器的端到端 RTT |
| 本地客户端 | `iperf3 -c <服务器IP> -R` | 测量服务器向本地发送的回程性能 |

脚本不会从服务器执行 `iperf3 -c` 去连接本地电脑，因为多数本地客户端位于 NAT 或防火墙后面，这个方向通常不成立。

## 二、上传到服务器

在本地电脑执行：

```bash
scp bbr-tune.sh root@<服务器IP>:/root/
```

或者使用普通 SSH 用户：

```bash
scp bbr-tune.sh <用户>@<服务器IP>:~/
ssh <用户>@<服务器IP>
chmod +x ~/bbr-tune.sh
sudo ~/bbr-tune.sh
```

直接在服务器运行脚本，不带参数即进入交互菜单：

```bash
sudo ./bbr-tune.sh
```

## 三、远程服务器交互菜单

```text
1) 检测远程服务器环境
2) 管理服务器端 iperf3 测速服务
3) 根据客户端实测数据生成方案（不修改服务器）
4) 临时应用方案（带 SSH 自动回滚）
5) 持久化应用方案（带 SSH 自动回滚）
6) 确认配置并取消自动回滚
7) 验证服务器当前配置
8) 立即回滚配置
9) 查看命令行帮助
0) 退出
```

## 四、正确的完整操作流程

### 第一步：检查服务器

SSH 登录服务器并运行：

```bash
sudo ./bbr-tune.sh
```

选择菜单 `1`。脚本会检查：

- Linux 内核和可用拥塞算法；
- 默认出口网卡与路由；
- 当前 BBR、`tcp_rmem`、`tcp_wmem`；
- 当前 qdisc；
- TCP 重传、超时和丢包累计计数；
- 当前 SSH 会话信息。

### 第二步：在服务器启动 iperf3

选择菜单 `2 → 1`，输入监听端口，默认为 `5201`。

等效命令为：

```bash
sudo ./bbr-tune.sh iperf-start \
  --iperf-port 5201 \
  --server-address <服务器公网IP或域名>
```

脚本只启动临时服务，不自动修改防火墙。需要同时确认：

- 云厂商安全组允许 TCP 5201；
- 服务器防火墙允许 TCP 5201；
- `iperf3` 已安装。

查看状态和客户端命令：

```bash
./bbr-tune.sh iperf-status \
  --server-address <服务器公网IP或域名>
```

停止临时服务：

```bash
sudo ./bbr-tune.sh iperf-stop
```

### 第三步：在本地客户端测速

以下命令全部在 **本地电脑** 执行，不是在服务器执行：

```bash
ping -c 20 <服务器IP>
```

单流回程：

```bash
iperf3 -c <服务器IP> -p 5201 -R -t 20 -i 1
```

8 流回程：

```bash
iperf3 -c <服务器IP> -p 5201 -R -P 8 -t 20 -i 1
```

16 流回程：

```bash
iperf3 -c <服务器IP> -p 5201 -R -P 16 -t 20 -i 1
```

记录：

- RTT；
- 单流吞吐；
- 8 流、16 流总吞吐；
- `Retr`；
- 是否存在固定速率封顶；
- 0～2 秒是否出现激进突发和大量重传。

### 第四步：把客户端结果输入服务器脚本

回到服务器的交互菜单，选择 `3`，输入本地客户端测得的：

- 目标或端口带宽；
- RTT；
- 丢包率；
- 症状类型；
- 已知网关硬限速值。

脚本根据 BDP 生成方案，但不修改服务器。

### 第五步：临时应用并启用 SSH 安全回滚

选择菜单 `4`。默认会设置 300 秒自动回滚计时器：

```text
应用调优
  ↓
启动 300 秒安全计时器
  ↓
如果 SSH 断开或没有确认
  ↓
自动恢复应用前的 sysctl 与 qdisc
```

命令行等效方式：

```bash
sudo ./bbr-tune.sh apply \
  --profile hard-cap \
  --cap-mbps 200 \
  --bandwidth-mbps 200 \
  --rtt-ms 30 \
  --runtime-only \
  --auto-rollback-seconds 300 \
  --yes
```

应用后建议：

1. 不要关闭原 SSH 窗口；
2. 另开一个 SSH 窗口，确认服务器仍能连接；
3. 在本地客户端重新运行单流、8 流和 16 测速；
4. 如果配置有效，回到服务器菜单选择 `6`；
5. 如果连接中断，不做确认，等待计时器自动回滚。

确认并保留配置：

```bash
sudo ./bbr-tune.sh confirm
```

### 第六步：持久化

临时 A/B 测试确认有效后，先执行回滚恢复原始基线，再选择菜单 `5` 做持久化应用。

持久化文件包括：

```text
/etc/sysctl.d/99-bbr-tcp-tuning.conf
/etc/modules-load.d/bbr-tcp-tuning.conf
/etc/default/bbr-tcp-tuning
/usr/local/sbin/bbr-tcp-qdisc
/etc/systemd/system/bbr-tcp-tuning.service
/var/lib/bbr-tcp-tuning/backups/<时间戳>/
```

持久化应用同样默认启用 SSH 安全回滚，验证成功后必须选择菜单 `6` 确认。

## 五、场景模型

| Profile | 场景 | 服务器动作 |
|---|---|---|
| `balanced` | 短/中 RTT 常规线路 | BBR + fq |
| `hard-cap` | 宿主机、网关或端口硬限速 | TBF 预整形 + fq |
| `qos` | 单流明显低于多流 | BBR + fq；业务层使用并发流 |
| `lfn` | 跨洋高 RTT、大 BDP | 扩大 socket buffer 上限 + fq |
| `lossy` | 随机丢包和抖动 | BBR + fq + SACK/DSACK |

BDP 计算：

```text
BDP_bytes = bandwidth_mbps × 1,000,000 × RTT_ms / 1000 / 8
buffer = BDP_bytes × 1.35
```

计算结果向上取 2 的幂次 MiB，默认限制为 `2～128 MiB`。脚本默认不会降低系统已有的更大 buffer 上限。

## 六、安全边界

1. 修改服务器出口 qdisc 可能影响当前 SSH 连接，因此交互应用默认启用自动回滚。
2. 计时器在修改 qdisc **之前**建立，确保连接在修改时中断仍能恢复。
3. 同一时间只允许存在一个未确认的调优任务。
4. 检测到 `cake`、`htb`、`netem`、`mqprio`、`taprio` 等自定义 root qdisc 时，默认拒绝覆盖。
5. 脚本不会自动开放云安全组或防火墙端口。
6. 通用回滚不能完整重建任意复杂的 class/filter 树；原始 `tc -s -d qdisc` 输出会保存在备份目录。
7. 自动回滚依赖脚本文件在计时结束前仍位于原路径，不要在确认前移动或删除脚本。
