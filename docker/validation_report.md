# Docker 样例执行报告

本页保留 2026-09-18/21 的交付记录，并在末尾记录 9 月 22 日的客户入口验证。
2026-09-22 按当前源码复核的完整条件、
逐项指标、CPU 时间反馈、XPU 对照及 LLM 结论边界见
[实验结果与分析](../docs/experiments.md)。构建与四组件源码准备见
[构建全流程](../docs/build-run.md)。历史结果目录不随 Git 分发。

执行日期：2026-09-18、2026-09-21
执行镜像：`storagestacked:local`
结果目录：`results/docker-image-smoke/`

## CPU / mem_sim 样例

| 样例 | 状态 | 事务数 | AXI 握手数 | 结果 |
|---|---:|---:|---:|---|
| directed | PASS | 17 | 766 | AXI、UCIe、mem_sim、VCD 校验通过 |
| replay | PASS | 17 | 766 | 重放路径通过；正向重放 22、反向重放 43、CRC 错误 35 均被处理 |
| shallow | PASS | 17 | 766 | 浅队列压力通过 |
| held | PASS | 17 | 766 | 响应保持压力通过 |
| period_3ns | PASS | 17 | 766 | 3 ns 周期样例通过 |
| cpu | PASS | 452 | 1,162 | CPU 访存程序和链路校验通过 |
| cpu_slow | PASS | 452 | 1,162 | 慢速内存比例样例通过 |

CPU / mem_sim 总结：7/7 样例通过；原生测试 19 项通过；在线 C ABI、数据损坏检查、AoU 负向检查、链路负向检查和 AXI256 检查通过。完整汇总见 `memsim-final2/summary.json`。

正式 runtime 层复验结果保存在 `results/docker-formal-runtime/memsim-final/summary.json`，同样为 7/7 通过。

## XPU 样例

| 样例 | 状态 | 事务数 | AXI 握手数 | 结果 |
|---|---:|---:|---:|---|
| npu | PASS | 320 | 832 | NPU 计算与链路校验通过 |
| gpu | PASS | 9,455 | 28,378 | GPU vecadd 计算与链路校验通过 |
| three | PASS | 9,737 | 29,096 | 三源联合样例通过 |
| three_slow | PASS | 9,737 | 29,096 | 三源慢速内存样例通过 |

XPU 总结：4/4 样例通过；汇总见 `xpu-final/summary.json`，波形审计见 `xpu-final/wave_audit/summary.json`。

正式 runtime 层复验结果保存在 `results/docker-formal-runtime/xpu-final/summary.json`，同样为 4/4 通过。

参数覆盖复验：使用 `XPU_NUM_CPUS=6`、`XPU_MEMSIM_SCALE=1`、`XPU_SLOW_MEMSIM_SCALE=4`、`XPU_MAX_TICKS=20000000000000`、`XPU_REPLAY=0` 运行四组 XPU 样例，`npu/gpu/three/three_slow` 均 PASS，握手数为 `832/28,378/29,096/29,096`；汇总见 `results/docker-formal-runtime/xpu-parameterized/summary.json`。

## 合成访存样例

执行参数：`--hidden-size 32 --layers 1 --context-tokens 4 --decode-tokens 1 --request-bytes 64`。

结果：生成 533 条请求、34,112 B；manifest / mapping / HostResponse 数量为 533 / 533 / 533；完成 530 次读事务和 536 次写事务，`data_errors=0`、`status=ok` 533。结果目录为 `llm-20260918T102429Z/`。

该样例使用固定到达的合成访存流，输出用于检查请求数量、字节守恒、读写类型和时序统计。

## 入口检查

- `storagestacked help`：通过。
- `docker compose config`：通过。
- Compose 方式的最小合成访存样例：通过，生成 136 条请求并完成 134 次读事务、138 次写事务，`data_errors=0`。

## 2026-09-22 客户入口验证

本轮新增根目录 `run.sh`、首次初始化、镜像产物检查和 HTTP 查看入口。
以下运行复核使用已验证的模型镜像 `sha256:88850a99680adb5c7b2e1789fadd271810070e3d077b647420febf2eebe58c4f`，
只读挂载当前客户脚本；它证明新入口能够驱动现有编译产物，不代替干净源码重建的结论。
CPU 和 LLM 验证时容器网络为 `none`。

| 验证项 | 本轮结果 |
|---|---|
| `python3 docker/test_runner.py` | 14 项通过；覆盖 Docker/Compose 缺失、服务/架构异常、构建与验收失败传播、镜像复用、参数转发和查看端口 |
| 纯仓库文件副本 | 444 个文件，不含外部源码、依赖、编译产物或结果；`doctor` 和入口回归通过 |
| 镜像内 `setup` 阶段 | 库/源码检查通过，CPU 七组通过，原生测试 19/19 通过；AXI、Flit、数据与负向校验通过 |
| 默认 `./run.sh llm` | 533 请求，34,112 B，全部响应 `ok` |
| 覆盖 `--hidden-size 16 --context-tokens 2` | 136 请求，8,704 B，全部响应 `ok`；确认显式参数覆盖默认值 |
| `./run.sh view` | 环回地址端口 18080；目录、两份 HTML、`view_store.js` 和 44 个数据分块共 48 个资源返回 HTTP 200；Ctrl+C 正常退出 |
| 拒绝覆盖 | 对已存在的检查目录返回非零退出码，保留已有结果 |

运行输出位于本地 `results/docker/customer-20260922/`，测试及资源记录在
`build/customer/`；这些大体积/机器相关文件不随 Git 分发。
LLM 仍为合成访存；本轮入口复核不重新声称完成 GPU/NPU 数值计算验收，完整 XPU
数据与范围见上述[实验分析](../docs/experiments.md)。

### 同日完成：源码构建与客户副本初始化

随后从仓库源码重新获取三棵锁定外部树及依赖，编译 Vortex、CoralNPU、mem_sim 和
gem5，生成了完整运行镜像。模型构建阶段 `build_xpu.sh` 耗时约 87.7 分钟
（含该阶段的 Bazel 依赖获取，不含此前工具环境准备和之后的镜像导出），因此 README
将首次构建说明为可能需要数十分钟到数小时。测试使用本机已有的 Ubuntu 20.04 基础镜像，
未复用旧 StorageStacked 镜像中的模型编译产物。

在上述 444 文件客户副本中执行 `./run.sh setup`，指定独立结果目录和候选镜像，
并以 `SS_BUILD_NETWORK=host` 连接本机已有代理；19 个已完成的镜像步骤命中缓存，
其中包括完整模型编译层。最终整条 `setup` 命令 **退出码为 0**，打印 `初始化成功`。

| 验证项 | 最终结果 |
|---|---|
| 镜像 | `sha256:23d4b931df5227c8388f6fd997b5649431b23b4c487d95a88aec0dfbb51ce5aa`，约 23.94 GB；已设为本机 `storagestacked:local` |
| 初始化检查 | 三份外部源码锁定版本、gem5 启动、三类动态库加载、XPU 产物与 SystemC 审计通过 |
| CPU / mem_sim | 7/7 样例、19/19 原生测试、在线 API、波形、Flit、数据和负向检查通过 |
| 默认 LLM | 533 条响应全部 `ok`，34,112 B；仍只验证合成访存 |
| 默认镜像 `view` | 48 个资源均返回 HTTP 200，含两份 HTML 和 44 个分块；Ctrl+C 退出码 0 |
| XPU 产物对照 | GPU/NPU 模型库、Host runtime、两个 kernel 与三个 Host 程序共 9 项 SHA256 均与此前验收镜像一致；本阶段未重复执行四组 XPU 计算 |
| 代理 | 仅用于构建，运行镜像环境中没有代理变量 |

本轮输出位于 `results/docker/customer-source-20260922/`，其中
`setup-20260922T070441673038322Z/` 保存最终初始化结果。来源、产物哈希和命令日志在
`build/customer/source-verification.json` 及同目录日志中。

开发期间首次长构建的 Docker 镜像已生成，但运行中的宿主脚本曾被修改，收尾返回了
127；该次外层命令不计为初始化通过。以上最终结论来自保持文件不变的客户副本实测，
编译与运行的完整调用正常返回 0。源码构建仍有可选功能和编译器警告，日志完整保留；
本次通过不表示已逐条清除所有编译告警。
