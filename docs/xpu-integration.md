# 从零接入新的 XPU

目标是让新设备与 Host/Vortex/CoralNPU 使用同一 gem5 调度器，以及
`timing DMA → HetAxiMonitor → 原生 TLM → AXI256 → UCIe → 在线 mem_sim`
请求/响应路径。本文用 `myxpu` 举例；**仓库尚无 MyXPU 实现**，带此名称的路径、ABI 与
参数均为需要新增的内容，不能直接当作现有命令运行。现有三设备不变的架构见
[architecture.md](architecture.md)，构建基线见 [build-run.md](build-run.md)。

## 1. 写明接入契约并准备环境

先按构建指南跑通原 CPU/XPU 套件，再为设备新增一份契约说明，至少填全下表：

| 项目 | 要作出的具体选择 |
|---|---|
| 来源与执行模型 | 固定上游提交、递归依赖、许可证、工具链；C++ 模型或 RTL→Verilator 库 |
| 功能边界 | 本地 TCM/SRAM 的范围；哪些访存必须出设备并通过在线存储链 |
| 地址 | 设备位宽、Host VA/PA、设备地址→系统地址变换、PIO 与数据窗口、越界处理 |
| 事务 | 最大长度、对齐、burst、mask、ID/token、最大在途数、顺序与错误状态 |
| 时间 | 设备频率、一次 step 的含义、请求接管点与完成点；初始化是否计入测量 |
| 控制 | reset/load/start/busy/done/error，超时、重复启动是否支持 |
| Host API | 寄存器或队列、提交/完成事件、缓冲区生命周期、所需线程上下文数 |
| 可观测性 | requestor 名、新来源 ID、来源 trace、设备周期与等待计数 |

第一版先实现确定性小 kernel、单拍读写、部分 mask 和有限在途数。未支持的原子、
一致性、checkpoint、reset/restart 等能力明确拒绝，不能静默当作普通读写执行。

环境使用现有 `SS_DEPS_ROOT`；单独设置 `MYXPU_HOME`、`MYXPU_BUILD`，不复用系统路径
变量。若是新的外部源码，把固定 revision 加入 `env/sources.lock.json`，同时增加
Dockerfile 获取步骤；新的工具包记录到 `env/xpu-artifacts.lock.json` 或适当的专用锁，
并在 `bootstrap_xpu.sh` 获取。只有 JSON 改动不能自动安装设备源码或工具。

新代码建议按以下结构组织，构建产物留在 build 目录：

```text
gem5_new/myxpuint/                      # 新增：库 ABI、模型适配、安装脚本、测试 kernel
gem5_new/gem5int/src/dev/myxpu/          # 新增：gem5 封装的唯一维护源
    MyXPU.py
    SConscript
    myxpu_dev.hh
    myxpu_dev.cc
gem5_new/workloads/myxpu_shared/         # 新增：Host↔设备数据测试
gem5_axi/configs/run_myxpu.py            # 新增：复用当前在线链路的组装配置
env/run_myxpu.sh                        # 新增：逐级运行和检查
env/verify_myxpu.py                     # 新增：明确的独立验收条件
```

## 2. 先完成可独立运行的模型库

参考 [CoralNPU C ABI](../gem5_new/coralnpuint/coralnpu_gem5.h) 的不透明句柄方式，
隔离私有 C++ 类型和 RTL 生成物。建议的新接口如下；这不是现有两设备 ABI 的统一声明：

```text
create / destroy / abi_version / build_info
load_program / start / tick_once / status
set_timing_backend(issue_read, issue_write, context)
complete_read(token, bytes, response) / complete_write(token, response)
```

明确 issue 的返回语义：拒收不改变状态，重试不产生第二笔请求；接管后持有独立上下文，
直到 completion。token 在存活事务间唯一，AXI ID 允许复用时还需 sequence，不能仅靠 ID
索引全部历史事务。写数据/mask 要复制或保证存活；读回内存的所有权与有效期必须固定。

`tick_once` 必须有界返回。等待内存期间，库不能调用 `while (pending) tick()`、启动后台
墙钟线程或执行自己的 `sc_start()`。RTL 使用原生 C++ 仿真方式或与 gem5 内核兼容的封装，
**不链接第二套 SystemC**。初始化时的本地 ELF 写入可以单独定义为非计时阶段；外存功能
预置不能绕过在线链路偷偷写另一份 RAM。

用 `nm -D --defined-only`、`readelf -d` 核对导出/依赖，增加真正的 dlopen smoke：
create→load→tick→外访存回调→注入响应→检查结果→destroy。只看 `.so` 文件存在不足以
证明可用。异步 ABI 必须测试延迟返回、拒收、错误响应和重复创建销毁。

## 3. 实现 gem5 SimObject、控制和 timing DMA

参考当前 [CoralNPU 封装](../gem5_new/gem5int/src/dev/coralnpu/) 或
[Vortex 封装](../gem5_new/gem5int/src/dev/vortex/)，新增 `DmaDevice` 子类：

1. `MyXPU.py` 声明动态库、kernel、PIO 范围、时钟、在途上限及开关；`SConscript`
   注册 SimObject/C++ 文件/DebugFlag。类型名、`cxx_class`、头文件路径必须一致。
2. C++ 加载必需 ABI 符号并检查版本；PIO 给出准确 `getAddrRanges()` 和寄存器行为。
   无 kernel、busy 时重复 start、非法 offset 都要有明确状态或错误。
3. 用 `EventFunctionWrapper` 按 `clockEdge(Cycles(1))` 调度设备。空闲不忙等；完成后
   停止该设备周期事件。多设备配置中由 Host 决定退出，不能在单个设备 done 时结束整机。
4. issue 时建立持久上下文 `{token, id, sequence, address, bytes, data, mask}`，通过
   `DmaPort` 发 timing 请求；DmaPort 可按 cache line 拆包，原事务直到全部子包返回才完成。
5. DMA completion 返回后把真实字节/状态交回库，按设备时钟规则产生可观察完成。
   保持所声明的同 ID/不同 ID 顺序；错误必须进入设备状态或明确终止，不能无条件回 OKAY。

需要部分写时复用 [dma_byte_enable.patch](../gem5_new/gem5int/patches/dma_byte_enable.patch)
支持的 mask 接口。不要为每个部分写额外生成读改写，改变请求流和冲突语义。
若选择直接使用 RequestPort，则 `sendTimingReq=false` 后保留原 packet，等待
`recvReqRetry()` 再发；响应反压、sender state、buffer 生命周期也由适配器负责。

## 4. 地址规划与在线链路接线

新增来源 ID 可选 3，保留已有 host=0、vortex=1、coralnpu=2。修改
`gem5_new/addrmap.json` 的 sources、regions/accessors/trace_windows 后执行：

```bash
make -C gem5_new addrmap
make -C gem5_new check-addrmap
```

同步 Host 头文件、kernel 常量及 `gem5_new/gem5int/configs/het/het_system.py` 的显式常量。
例如可评估 `0x40000000` 作为新 PIO 页，但需检查地址图、Host 页池、其他 PIO 和实际
responder 的范围；示例地址不是已分配资源。共享数据应处于设备真实可寻址区域，不能
把 CoralNPU 地址位宽改大以规避硬件限制。

在新的在线配置中复用 `run_xpu.py` 的系统组装方式，接线形态为：

```python
# 待实现配置片段；需先新增 MyXPU 类和参数。
system.myxpu.pio = system.membus.mem_side_ports
system.myxpu.dma = system.membus.cpu_side_ports
# 所有目标数据请求继续经过既有 het_monitor → bridge → axi。
# instantiate 后把已分配的 PIO/数据窗口映射给 Host，cacheable=False。
```

若复用已有目标区，分配不与原 workload 重叠的子区；若增加新窗口，必须同时更新
bridge 的 `addr_ranges`、`AxiDemo.base/size`、Host 的 `Process.map()` 和内存容量/通道数。
mem_sim 桥用 `address-base` 作本地地址，容量必须覆盖整个窗口；不能只在 `system.mem_ranges`
中添加地址，或额外接一个 SimpleMemory 让新设备旁路 UCIe。新配置在 instantiate 前设置
1 fs 全局时间，并显式选择 `backend='aou', memory_backend='memsim'`。

## 5. 扩展来源观察与数据校验

当前 monitor 按名称先匹配 CoralNPU，再匹配 Vortex，其余归 Host。新设备即使接通也
可能被静默记为 Host，必须修改下面所有关联点：

| 修改位置 | 必须完成的内容 |
|---|---|
| `HetAxiMonitor.py` | `trace_myxpu`、requestor pattern 参数 |
| `het_axi_monitor.hh/.cc` | Source 枚举、writer、分类、source ID 映射、初始化/关闭/统计 |
| monitor 的 ID 分配 | 当前 `liveIds`、`nextIds` 是长度 3 的数组，扩成支持新增来源；不能只加枚举 |
| 地址生成物与 Python 工具 | 新名称/ID、区域归属、过滤、统计、validate/merge/convert 的来源假设 |
| 在线配置 | 只启用需要的统一 writer，设备内部 tap 默认关闭，避免重复记录 |
| `verify_myxpu.py` | 独立检查新来源非零、Host 未被污染、请求/字节/响应守恒、全局 1 fs |
| `record_xpu.py` 或新增记录器 | 新设备库/kernel、工具、外部版本、加载依赖和 SystemC 唯一性 |

统一 monitor 的记录仍标 `interconnect/SYNTH`；真实 AXI 波形由下游原生信号层提供。
HETTrace 不含原始 WDATA/RDATA，不能替代独立字节记分板。新增设备后现有三源专用验收器
仍保留原合同，不应简单删掉“必须恰好三源”的断言以让四源结果蒙混通过。

## 6. 安装、构建与 Docker 对接

| 当前入口 | 新设备需要增加的动作 |
|---|---|
| `env/activate.sh` | 导出 MYXPU 源码/构建/库路径；避免额外全局库污染 |
| `env/bootstrap_xpu.sh` | 获取锁定工具与原始缓存；声明 `SS_OFFLINE=1` 行为 |
| `gem5_new/myxpuint/install.sh`（新增） | 幂等安装外部适配补丁，不清理已有用户改动 |
| `gem5_new/gem5int/install_devices.sh` | 将 `dev/myxpu` 加入复制集合；编辑维护源，不手工长期维护 gem5 副本 |
| `env/build_xpu.sh` | 在统一 gem5 构建前安装新设备、编译模型库/kernel/Host workload，记录失败 |
| `env/build.sh` | 已会调用 install_devices 和统一 SCons；若新增 EXTRAS 或链接依赖则同步修改 |
| `Dockerfile` | 获取额外外部源、依赖锁与构建步骤；runtime 层包含产物 |
| `docker/entrypoint.sh`、`docker/run.sh`、`docker-compose.yml` | 新运行入口或显式设备开关、必要参数转发、结果挂载；不隐式替换既有验收 |
| `env/dependency_bundle.py` | 若继续支持依赖包交付，扩展源/缓存清单和恢复验证 |

安装后用 `bash env/build_xpu.sh` 构建设备和系统；只改 gem5 适配源时可用
`bash env/build.sh` 刷新复制与重编，但不能靠它重建设备模型库。
新设备脚本完成前，不在用户说明中声称已有 `./docker/run.sh myxpu` 命令。

## 7. 分级调试与验收

每一级都使用新的结果目录。失败时保存日志并停留在该级定位：

| 阶段 | 输入 | 通过标准 |
|---|---|---|
| A. 库 smoke | 本地小程序+可控延迟的内存回调 | ABI/加载正确，非零输入结果正确，未收到 completion 时不会退休 |
| B. 单设备在线 | 少量读写+真实 TLM/AXI/UCIe/mem_sim | 无旁路内存；真实响应、VCD、Flit、数据和子请求对应 |
| C. Host↔新设备 | Host 写入→启动→设备处理→Host 读回 | 所有权交接、状态/事件、超时与精确结果均可验证 |
| D. 压力/边界 | mask、非对齐、跨 4 KiB、长包、ID 复用、有限队列 | 支持的请求正确拆分；拒收/反压不丢不重；不支持的组合明确拒绝 |
| E. 反向对照 | 错地址、故意损坏数据、错误响应 | 独立检查器确实失败，错误不能被固定返回值掩盖 |
| F. 时间反馈 | 固定计算，放大内存 scale | 输出一致、外存等待和有关完成时间增加；按源核对访问语义 |
| G. 系统回归 | 既有 CPU 7 组、XPU 4 组、新四源/协同组 | 原功能不回退；新来源及原来源均可正确分类和审计 |

现有可直接执行的检查入口：

```bash
bash env/run_memsim.sh results/myxpu-regression-memsim
bash env/run_xpu.sh results/myxpu-regression-xpu
make -C gem5_new check-addrmap
```

新套件按 `env/run_xpu.sh` 的顺序复用 `check.py`、`check_aou.py`、`inspect_link.py`、
`check_memsim.py`、`audit_wave.py`，再增加设备功能/来源/时间反馈验收。
若扩大事务语义（例如同时同址读写、内存写合并/读转发），现有检查器未覆盖的部分必须
另建正确的 oracle，不能仅关闭断言。建议同时核对末尾在途数为零、error 传播与数据缓冲
释放；声明 restart/checkpoint 支持前还需相应状态恢复测试。

定位顺序：库加载/端口连接→PIO start→DMA issue/retry→AXI 握手→两端 Flit→内存
submit/complete→AXI R/B→设备 completion→Host 结果。最后一个已有证据的阶段就是继续
排查的起点；有 trace 文件但无数据检查，不能记作接入成功。

## 8. 验证上线与交付

这里“上线”指设备进入统一仿真框架并具备可重复构建、启用和回归方式，不指物理芯片部署。
交付契约、代码/补丁、锁定依赖、地址生成物、入口参数、workload、检查器和结果说明；
完整波形/日志放独立结果目录，记录源码/镜像、输入、实际参数和限制。

验收状态明确区分 PASS、FAIL、NOT_RUN；仅库构建成功不得升级为系统 PASS。
新路径应能关闭，以便恢复原三设备配置。先在干净环境构建，再运行旧套件和新套件，最后
才按团队流程合并和发布；远端 push 仍需要用户明确授权。本文补齐流程，不代表已实现
或验收第四种设备。
