# 实验设计、结果分析与优化方向

本页把在线 CPU/XPU 功能与时间反馈、协议压力测试、离线合成 LLM 访存分开分析。
执行命令和各阶段输出见[构建全流程](build-run.md)，系统边界见[架构](architecture.md)。
历史执行清单仍保留在 [Docker 样例报告](../docker/validation_report.md)。

## 1. 证据来源和复现条件

本页的 2026-09-22 实验批次使用当时本机已有的 `storagestacked:local` 镜像，独立输出根为
`results/docs-review-20260922/`，运行时使用 `--network none`。本轮没有重新执行
Docker 全量编译，也没有新增第四种 XPU 或完成另一台机器的构建验收。

本轮在线总验收为 **CPU/mem_sim 7/7、XPU 4/4 通过**，两套件各自的 19 项原生测试、
C ABI、数据/链路、完整波形和时间反馈检查通过。LLM 为 533 条请求的投影/响应审计通过，
其命令/DFI 验证仍为 NOT_RUN，详见第 5 节。

工作区基线为 `a35d9e66948df405155cbeeb0f0e67cb8ac5b235`，镜像内 Git revision 是构建时
建立的源码快照，两者不能仅按 revision 字符串判断等价。逐文件比对了 351 个已跟踪的
实现/配置文件，349 个与镜像相同；差异只有 `docker/entrypoint.sh` 和 `docker/run.sh`。
运行时将当前 entrypoint 挂到实际执行路径，未使用镜像内旧 run.sh。完整来源记录保留在
`results/docs-review-20260922/provenance.json`，工具/库清单在两套件的 `environment/`。

以下是本次复现方式；再次运行须换一个尚不存在的目录，避免覆盖证据：

```bash
mkdir -p results/review-logs
set -o pipefail
docker run --rm --network none \
  -v "$PWD/results:/results" \
  -v "$PWD/docker/entrypoint.sh:/usr/local/bin/storagestacked:ro" \
  storagestacked:local all /results/docs-review-new \
  2>&1 | tee results/review-logs/online.log

docker run --rm --network none \
  -v "$PWD/results:/results" \
  -v "$PWD/docker/entrypoint.sh:/usr/local/bin/storagestacked:ro" \
  storagestacked:local llm /results/docs-review-new/llm \
  --hidden-size 32 --layers 1 --context-tokens 4 --decode-tokens 1 --request-bytes 64 \
  2>&1 | tee results/review-logs/llm.log
```

全量重建镜像后可直接使用 `./docker/run.sh all` 和 `llm`。与上述数据比较时固定源码、
设备库、workload、时钟、队列、人为 stalls/replay、CPU 上下文数和统计窗口。
不要将跨构建变化归因为某一个存储参数。

## 2. 实验矩阵与判定方式

| 组别 | 目的/变化 | 必须同时成立的证据 |
|---|---|---|
| 原生与 C ABI | mem_sim 内部行为及接口契约 | 19 项原生测试、掩码数据、队列满重试、重复 ID/边界拒绝、高地址不别名 |
| directed | 17 笔父请求，非对齐/4 KiB/长包/mask/越界 | 独立字节检查、两笔预期 DECERR、五通道 VCD、两端 Flit、DRAM/DFI |
| replay | 双平面并注入确定性 Flit 错误 | CRC/replay 被实际触发、最终数据正确、无乱序/丢重 |
| shallow / held | 缩浅入口；进一步限槽并保持响应 | submit/response stalls 非零且请求最终完成 |
| period_3ns | AXI 周期 2→3 ns | 时间一致、协议/数据正确；不预设整机延迟严格按 1.5 倍增长 |
| cpu / cpu_slow | 同一 CPU 程序，内存 scale 1→4 | 同指令数/同 452 笔访问；完成增量等于逐请求延迟差之和 |
| npu / gpu | 单设备 Host 控制 | 实际计算、PIO/DMA、对应来源、在线数据/时间与波形 |
| three / three_slow | 三源协同，内存 scale 1→4 | 两设备结果正确，来源守恒，Host/设备完成变慢，实际访问语义保持 |
| llm | 固定合成三源访存形状 | manifest/mapping/HostResponse 请求及字节守恒、状态/因果审计 |

前八行依赖在线存储响应；LLM 是离线固定到达流。进程退出或文件存在不是总 PASS：
在线套件必须有总 `summary.json.passed=true` 和 `wave_audit/summary.json`，用例的
`check_summary`、`aou_check_summary`、`memsim_check`、`memsim_core` 均通过。
LLM 当前日志中的 `Command=not_run; DFI=not_run` 仍记为 **NOT_RUN**，不升级为命令/DFI 通过。

## 3. CPU/协议压力实测

来源：`memsim/summary.json`、各例 `protocol_summary.json`、`transactions.csv`。
七组总验收、原生 19 项、C ABI、波形及负向检查通过。时间均为模拟时间。

| 用例 | 父请求 | AXI 五通道握手 | 内存子请求 | 结束时间 ns | 提交阻塞次数 | 响应保持/阻塞次数 |
|---|---:|---:|---:|---:|---:|---:|
| directed | 17 | 766 | 176 | 4,067 | 1,599 | 0 |
| replay | 17 | 766 | 176 | 4,087 | 1,603 | 0 |
| shallow | 17 | 766 | 176 | 4,961 | 6,635 | 0 |
| held | 17 | 766 | 176 | 5,529 | 5,983 | 4,800 |
| period_3ns | 17 | 766 | 176 | 4,960 | 1,605 | 0 |
| cpu | 452 | 1,162 | 452 | 106,550 | 0 | 0 |
| cpu_slow | 452 | 1,162 | 452 | 122,836 | 0 | 0 |

### 3.1 计数守恒不能写成“所有层数字都相等”

directed 的 17 笔父请求拆成 **24 个 AXI burst**，其中两笔 burst 越界，不提交内存；
合法部分拆成 176 个原生子请求，产生 91 个 WR、85 个 RD。766 次握手包含 AW/W/B/AR/R，
数据拍为 728。它们分别统计父请求、协议分段、数据拍和原生粒度，数值不同是预期行为。
合法子请求 submitted=returned=176，命令和 DFI 检查错误均为 0；两笔 DECERR 是定向
测试的预期错误，不是可忽略的随机错误。

replay 触发正向重放 22 次、反向 43 次、CRC 错误 35 次，最终数据和顺序检查通过。
它同时改变了平面数与注错开关，因此 4,067→4,087 ns 不能单独作为“每次重传成本”的测量。

### 3.2 队列、保持和时钟的影响

shallow 将 `memsim_queue` 从 4 降到 1，结束时间增加 **21.98%**，提交阻塞从 1,599
增至 6,635，符合较小缓冲削弱并发吸收能力的表现。父事务平均往返延迟从 921.16 增至
1,195.63 ns；其中准入等待均值从 80.16 增至 140.04 ns，说明影响会向上游传播。

held 在 queue=1 的基础上还把 burst 槽限为 1，并加入 200 个内存 tick 的响应保持。
其结束时间比 shallow 再增加 **11.45%**。每次 tick 为 0.25 ns，故配置的额外保持为
50 ns/burst；4,800 次响应等待与 24×200 一致。此组同时改槽数和保持，不能把总增量
全部归到某一个参数。提交阻塞比 shallow 少也不表示更快：更严的上游节流减少了尝试次数。

AXI 周期增至 3 ns 后总结束时间只增 **21.96%**。链路、原生内存及其他等待并非都按
AXI 周期缩放，故不能预期整例恰好增加 50%。这些是小规模协议压力结果，不是饱和带宽测量。

### 3.3 CPU 闭环反馈与局部延迟波动

两组均执行 4,326 条模拟指令、452 笔目标访问，地址/方向/字节/状态逐笔一致。
内存 period 从 250,000 fs 变为 1,000,000 fs，Host 结束时间增加 **16,286 ns（15.28%）**，
严格等于 452 笔 `end_resp_tick-begin_tick` 延迟差之和，证明下游响应反馈到了 CPU 执行。

| 父事务往返指标 | cpu | cpu_slow |
|---|---:|---:|
| mean，ns | 53.73 | 89.76 |
| p95，ns（nearest-rank） | 87 | 97 |
| max，ns | 269 | 1,103 |
| 准入→末 AXI 响应均值，ns | 52.59 | 88.62 |

440 笔变慢，12 笔变快；逐笔差值最小 -172 ns、最大 1,056 ns。
放大内存时间映射会改变请求相对刷新/行状态的到达相位，不意味着每笔请求必须更慢。
实测 REFpb 为 3,492→1,004、ACT 为 30→11，确认两组内部调度轨迹不同；将某一笔
下降具体归因于某次刷新还需逐请求关联命令，当前不作该强断言。
`memsim_core.cycles` 为 426,200→122,836，也不能读成慢组更快：必须分别乘以
0.25 ns 和 1 ns，才得到对应 Host 结束时间。

本例程序/栈仍在本地主存，目标访问只有 480 B，适合反馈和正确性证明；全程耗时包含
本地工作与启动/链路开销，不用于估算 CPU 通用应用加速比或 HBM 饱和吞吐。

## 4. XPU 与三源协同实测

来源：`xpu/*/run.log`、`protocol_summary.json`、`memsim_core.json` 与各源 HETTrace。
默认 CPU 上下文数为 4，基线内存 scale=1，慢组 scale=4。
四组均通过最终 `xpu/summary.json` 验收，独立 VCD 审计为 4/4 通过，
`memory_feedback.passed=true`。

| 用例 | 父请求 | AXI 握手 | 内存子请求 | Host 结束时间 ns | NPU 周期 | GPU core 周期 |
|---|---:|---:|---:|---:|---:|---:|
| npu | 320 | 832 | 320 | 265,826 | 5,019 | — |
| gpu | 9,455 | 28,378 | 9,669 | 3,662,296 | — | 626 |
| three | 9,737 | 29,096 | 9,947 | 3,652,048.5 | 5,568 | 624 |
| three_slow | 9,737 | 29,096 | 9,947 | 3,760,866.5 | 9,715 | 1,046 |

### 4.1 内存响应对三个执行方的影响

三源慢组与基线相比，Host 增加 **108,818 ns（2.98%）**，NPU 周期增加 **74.48%**，
GPU core 周期增加 **67.63%**。CPU 总时间含初始化、runtime、局部内存与等待，设备周期
则使用各自计数窗口，因此不能期待三个比例相等，更不能都直接套用“内存×4”。

两组 NPU 均为 64 次读、64 次写；GPU core 均为 6 次读、1 次写，CP DMA 均为
40 次读、40 次写。本次请求数/字节也相同，计算结果均通过；这些不变量用于确认
比较的是同一计算，而不是慢组少做了任务。
父事务 mean 从 60.88 增至 76.20 ns、p95 从 60.5 增至 98.5 ns；内存提交阻塞
973→3,162。平均值会受少量长尾影响，高于 p95 并不矛盾。

### 4.2 来源占比与“小 kernel、大搬运”

基线 three 的 packet 观察点共记录 90,008 B：

| 来源 | 事务数 | 拍跨度字节 | 字节占比 |
|---|---:|---:|---:|
| Host | 9,360 | 74,112 | 82.34% |
| Vortex | 249 | 13,848 | 15.39% |
| CoralNPU | 128 | 2,048 | 2.28% |

Host 占事务数 **96.13%**，这组测试更能说明提交、搬运与存储闭环，不能代表大算子的
GPU/NPU 吞吐公平性。Vortex 的 249 笔是 monitor 看到的 packet，模型库中的
6+1+40+40=87 次 core/CP 请求可能被 DMA 拆包，不能按库请求数强制要求 packet 数也为 87。
NPU 算法的有效读写数据是 64×4×2=512 B，而当前 AXI seam 每次请求覆盖 16 B，
所以观察跨度为 2,048 B；写入使能字节还应按 mask 统计。

基线 Vortex 来源活动区间为 `[3,416,202, 3,594,954] ns`，NPU 为
`[3,547,070, 3,557,964] ns`，确认来源访存区间相交。前者含 CP/DMA，不是 GPU kernel
纯计算窗口；区间交叠不能替代 kernel 并行度或协同加速比测试。

验收的 NPU 任务是 64 元素 `out=in*2+1`，GPU 是 4 元素 vecadd；两者都属于功能小样例。
`gpu_cycles` 来自 Vortex core 的周期计数，`gpu_cp_cycles` 是命令处理器计数，Host 的
`exit_tick_fs` 又包含初始化、runtime、线程和结果检查，三者不能互相替代。

正式 XPU 配置固定 `outstanding=16`、`planes=2`、`memsim_queue=4`、`memsim_slots=8`，
并启用人为 `stalls=True`；含 GPU 时 mem_sim 为 8 channels，NPU 单独组为 2 channels。
因此不能从 npu 与 three 的差值直接推出“加入 GPU 的干扰成本”：通道数、Host 工作和
发射相位也变化了。现成验收还不能单独测无压力注入下的最佳性能。

Host 异步提交只保证具备并发机会，活动区间相交也不证明 kernel 全程重叠。
没有同规模串行基线和明确 ROI，本页不报告协同加速比。

## 5. 合成 LLM 访存实测与边界

参数为 `hidden_size=32,layers=1,context_tokens=4,decode_tokens=1,request_bytes=64`，
其余生成器参数取默认值；默认转换为 1,000 HETTrace tick/内存 cycle。
来源：`llm/traces/benchmark.json`、`mem_sim.map.csv`、`hbm_sim.responses.csv`、
`summary.md`、`hbm_sim.txt`。这条路径不使用在线套件的 1 fs 参数推导内存时间。

manifest / mapping / HostResponse 为 **533 / 533 / 533**，字节为 **34,112 B**，
其中上游 HostRequest 层为 265 读、268 写（这里不是仅指 Host 来源）。每条 64 B 请求
拆为两个 32 B 原生事务，所以物理统计为
530 读、536 写，共 1,066；不能将其误读为额外执行了 1,066 个应用请求。
全部 533 个响应状态 ok，`data_errors=0`，剩余请求和 pending 为 0。

| 合成来源 | 请求数 | mean，内存 cycle | p95，内存 cycle | max，内存 cycle |
|---|---:|---:|---:|---:|
| 全部 | 533 | 144.8 | 228 | 1,502 |
| Host | 266 | 154.1 | 228 | 1,403 |
| CoralNPU 角色 | 257 | 89.2 | 105 | 240 |
| Vortex 角色 | 10 | 1,330.1 | 1,502 | 1,502 |

前端提交等待均值 1.2 cycle、最大 5 cycle；计划到完成的均值 146.1 cycle。
各项先用原始样本相加再四舍五入，所以不能直接拿已舍入的 144.8+1.2 要求等于 146.1。
Vortex 角色只有 10 条请求却有明显长尾，说明整体均值会掩盖来源差异；需要结合地址/发射
窗口/队列追踪原因，不能仅凭均值宣称 GPU 更慢。另有 1 条 forwarded 响应，需与普通读区分。

该模型运行 476.75 ns，自报 71.2826 GB/s、利用率 3.4806%。这些是当前固定输入下的
内存模型统计，含 32-channel、32 B transaction、行为 PHY 和原生时间口径；与在线 XPU
的 2/8 channels、scale 和观测窗口不同，不宜横向画成同一带宽排行。

这个入口未执行命令/DFI validator（日志明确为 NOT_RUN）；零值 data/expect 也只认证
转换后的替身载荷，不认证真实 LLM 数据。不能据此报告模型精度、tokens/s、IPC 或应用
闭环加速比。在线套件的完整 AXI/Flit/命令/DFI 检查不能被移植为本离线组的 PASS。

## 6. 指标定义与可复核计算

| 指标 | 原始字段与公式 | 范围 |
|---|---|---|
| 父请求数 | `transactions.csv` 行数 | 长 Packet 可能进一步分 burst/子请求 |
| AXI 握手数 | `protocol_summary.channels.*.handshakes` 求和 | 包括地址/响应，不等于有效数据拍 |
| AXI 数据跨度 | 每拍 `2^AxSIZE`；写有效字节另按 `popcount(WSTRB)` | 不把每次窄访问一律记 32 B |
| 父事务延迟 | `(end_resp_tick-begin_tick)/10^6` ns | 包含 Master 准入，尚不等于所有源最初尝试到完成 |
| 分段延迟 | 准入 `accepted-begin`；链路 `axi_done-accepted`；返回 `end_resp-axi_done` | 三段严格相加；中段含 AXI/链路/内存及排队，不能直接叫 DRAM 延迟 |
| 测试源端到端 | `packet_lifecycle.csv` 的 `response_tick-first_attempt_tick` | 仅有该测试源记录的场景可用，包含拒收重试 |
| HETTrace 来源往返 | 同源 txn 的末 B/R tick − AW/AR tick | monitor 接受至转交响应；与 TLM 分段起点不同 |
| 内存子请求 | `memsim_bridge.csv` 的唯一 `mem_id`；submit↔complete 一一对应 | `issued_cycle` 是模型发命令时间，不是桥 submit 时间 |
| 在线子请求时间 | `complete.tick-submit.tick`；模型服务段 `(completion_cycle-issued_cycle)×period_fs` | 分清桥等待和模型命令服务；检查因果顺序 |
| LLM 提交等待/响应/总延迟 | mapping `cycle=q`，response `arrival_cycle=a,completion_cycle=c`：`a-q` / `c-a` / `c-q` | 内存 cycle，保持转换参数一致 |
| p95 | 排序后第 `ceil(0.95*N)` 个样本（从 1 开始） | 说明样本是父事务、子请求还是来源；不混合两层样本 |
| 有效吞吐 | 明确字节口径 / 明确测量窗口 | `B/ns` 数值等于十进制 GB/s；有用算法字节、拍跨度、DRAM payload 不混用 |
| 协同加速比 | 同计算量串行时间 / 协同时间 | 本轮没有相应对照，NOT_RUN |
| 仿真器宿主速度 | 模拟时长或事件数 / 宿主 wall time | 本轮没有隔离宿主负载的重复测量，不作性能结论 |

用标准库复算 CPU 表格，无需更改模型：

```bash
python3 - results/docs-review-20260922/memsim <<'PY'
import csv, json, math, statistics, sys
from pathlib import Path
root = Path(sys.argv[1])
summary = json.loads((root / 'summary.json').read_text())
assert summary['passed']
for name, case in summary['cases'].items():
    with (root / name / 'transactions.csv').open() as f:
        rows = list(csv.DictReader(f))
    lat = sorted((int(r['end_resp_tick']) - int(r['begin_tick'])) / 1e6 for r in rows)
    assert rows and len(rows) == case['transactions']
    print(name, 'N=', len(rows), 'finish_ns=', case['exit_tick_fs'] / 1e6,
          'mean_ns=', statistics.mean(lat), 'p95_ns=', lat[math.ceil(.95 * len(lat)) - 1],
          'max_ns=', max(lat))
print('CPU feedback:', summary['cpu_feedback'])
PY
```

本次完整表格复算脚本还保存在 `results/docs-review-20260922/analyze.py`，执行
`python3 results/docs-review-20260922/analyze.py` 可重新核对总验收、波形状态、原始计数与
CPU 延迟守恒，并生成同目录 `analysis.json`。启动日志为 `online-launch.log`、
`llm-launch.log`；结果目录整体保留，不随 Git 分发。

## 7. 现存问题与后续优化实验

下表为建议，未列入本轮已实现性能改进：

| 优先级 | 当前问题/证据 | 下一步实验与判定方式 |
|---|---|---|
| P0 | 旧文档的四源码/open-loop 与当前布局冲突 | 本轮补齐新入口并标记历史；后续在第二台干净机器跑源码获取→全量构建→验收，保留日志 |
| P0 | 第四源被默认分类为 Host；来源 ID 数组写死 3 | 按 [XPU 接入](xpu-integration.md)扩展来源与数组，独立检查新源和原三源计数 |
| P1 | 当前 GPU 4 元素，Host 初始化/搬运占大头 | 增加计算规模并定义初始化/计算/收尾 ROI；保留完整日志，另统计完整事务落在 ROI 的子集 |
| P1 | XPU 固定人为 stalls，缺少串行同配置对照 | 增加显式压力开关；固定 channel/时钟/库/输入，在相同计算量下比较串行与协同 |
| P1 | 全局响应 FIFO、固定 slots/queue 可能队头阻塞 | 单独扫描 queue、slots、outstanding，记录逐源 mean/p95、年龄、重试及吞吐；先保持顺序/数据正确 |
| P1 | replay 同时改变平面数，held 同时改槽数和保持 | 拆成单变量对照；固定错误种子、流量与平面数，分别统计重传和排队成本 |
| P1 | LLM 源分布小且不均衡、命令/DFI 未运行 | 固定输入扫描 context/hidden/到达间隔，分源/读写/forwarded 分组；另启用或补齐命令级检查 |
| P1 | 新 workload 可能引入同址竞争、读转发/写合并 | 当前在线检查器要求每个 child 对应 RD/WR；扩展 oracle 后再接纳新语义，不删断言掩盖缺口 |
| P2 | GPU/NPU 无直接共享、NPU 仅一次启动 | 单独实现 Host 中转依赖链或可寻址映射；增加多任务、reset/restart 与所有权测试 |
| P2 | HBM4 含 provisional 时序，DFI 为行为输出 | 用器件参数/命令参考进行校准，列校准覆盖；在此之前不承诺硬件绝对性能 |
| P2 | 全程 VCD/refresh 日志体积较大 | 先分离模型 wall time 与后处理耗时，再评估日志分块/压缩；验收仍保留要求的完整证据 |

每次优化固定其余参数并保存实际配置、输入、来源信息和完整原始结果。确定性单次样例
不生成伪造的误差条；若研究随机注错或宿主机速度，应另设种子/重复次数和统计范围。
