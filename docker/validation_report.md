# Docker 样例执行报告

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
