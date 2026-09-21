# 复现与参数操作指南

本文给出对接方从镜像构建到样例复现的完整命令。所有命令在仓库根目录执行，结果会写入宿主机的 `results/docker/`。

## 1. 构建并确认入口

```bash
docker compose build
docker compose run --rm storagestacked help
```

也可以使用短命令：

```bash
./docker/run.sh build
./docker/run.sh help
```

## 2. 复现 CPU / mem_sim 样例

```bash
./docker/run.sh memsim
```

该命令依次执行 directed、replay、shallow、held、period_3ns、cpu 和 cpu_slow 七组样例。完成后，在最新的 `results/docker/memsim-*` 目录中查看：

| 文件 | 内容 |
|---|---|
| `summary.json` | 七组样例的通过状态和统计 |
| `*/run.log` | 每组样例的运行日志 |
| `*/verification.log` | AXI、链路、mem_sim 和数据校验日志 |
| `*/axi.vcd`、`*/flit*.log` | AXI 五通道波形与两端 Flit 时间记录 |

## 3. 修改 XPU 参数并复现

XPU 入口把参数映射到 `gem5_axi/configs/run_xpu.py`，默认值对应基线验收样例。可以在不修改源码的情况下通过 Compose 环境变量覆盖：

| 环境变量 | 默认值 | 作用 |
|---|---:|---|
| `XPU_NUM_CPUS` | `4` | gem5 主机 CPU 上下文数量 |
| `XPU_MEMSIM_SCALE` | `1` | npu、gpu、three 三组的内存时间比例 |
| `XPU_SLOW_MEMSIM_SCALE` | `4` | three_slow 组的内存时间比例 |
| `XPU_MAX_TICKS` | `20000000000000` | 单个 gem5 样例最大 tick 数 |
| `XPU_REPLAY` | `0` | 置为 `1` 时启用链路 replay 参数 |

例如，使用 8 个主机 CPU 上下文、把普通 XPU 样例放慢为 2 倍、把慢速对照组设为 8 倍，并打开 replay：

```bash
XPU_NUM_CPUS=8 \
XPU_MEMSIM_SCALE=2 \
XPU_SLOW_MEMSIM_SCALE=8 \
XPU_MAX_TICKS=30000000000000 \
XPU_REPLAY=1 \
SS_RESULTS_DIR="$PWD/results/docker/xpu-parameter-sweep" \
./docker/run.sh xpu
```

也可以只临时覆盖一次 Compose 运行：

```bash
docker compose run --rm \
  -e XPU_NUM_CPUS=6 \
  -e XPU_MEMSIM_SCALE=3 \
  storagestacked xpu /results/xpu-scale-3
```

完成后查看 `summary.json` 和 `wave_audit/summary.json`。报告中的 `npu`、`gpu`、`three`、`three_slow` 对应四个固定工作负载，修改参数后仍按相同目录结构生成结果，方便横向比较。

## 4. 复现 LLM 访存算子

LLM 入口生成确定性的 decoder 访存流，再执行 HETTrace 校验、mem_sim 映射和 HBM 时序。默认流量包含三类角色：主机权重/令牌交互、CoralNPU 权重与激活、Vortex KV-cache 扫描与更新。

### 最小可复现实例

```bash
./docker/run.sh llm \
  --hidden-size 32 \
  --layers 1 \
  --context-tokens 4 \
  --decode-tokens 1 \
  --request-bytes 64
```

这组参数适合首次运行。若要固定结果目录，先保证该目录为空：

```bash
docker compose run --rm storagestacked llm /results/llm-small \
  --hidden-size 32 \
  --layers 1 \
  --context-tokens 4 \
  --decode-tokens 1 \
  --request-bytes 64 \
  --arrival-step 500 \
  --layer-gap 20000
```

### 参数表

| 参数 | 示例 | 调整内容 |
|---|---:|---|
| `--hidden-size` | `32` / `128` | 隐藏维度，影响权重和激活规模 |
| `--layers` | `1` / `4` | Transformer layer 数量 |
| `--context-tokens` | `4` / `128` | KV-cache 的上下文 token 数 |
| `--decode-tokens` | `1` / `8` | 生成阶段 token 数 |
| `--ffn-multiplier` | `4` | FFN 中间维度为 hidden size 的倍数 |
| `--weight-bytes` | `1` | 每个权重元素的字节数 |
| `--kv-element-bytes` | `2` | KV-cache 元素字节数 |
| `--request-bytes` | `64` | 单条访存请求大小，使用不超过 64 的 2 次幂 |
| `--arrival-step` | `500` | 同一源相邻请求的间隔，单位为 HETTrace tick |
| `--layer-gap` | `20000` | 相邻 layer 发射窗口间隔，单位为 HETTrace tick |

### 两组可直接复现的配置

小规模检查：

```bash
./docker/run.sh llm \
  --hidden-size 16 --layers 1 \
  --context-tokens 2 --decode-tokens 1 \
  --request-bytes 64 --arrival-step 500 --layer-gap 20000
```

多 layer 压力：

```bash
./docker/run.sh llm \
  --hidden-size 64 --layers 2 \
  --context-tokens 16 --decode-tokens 2 \
  --ffn-multiplier 4 --weight-bytes 1 --kv-element-bytes 2 \
  --request-bytes 64 --arrival-step 500 --layer-gap 20000
```

### 结果核对

每次运行的目录包含：

| 文件 | 用途 |
|---|---|
| `traces/benchmark.json` | 本次参数、地址布局和各源请求统计 |
| `traces/host.hettrace` | 主机访存流 |
| `traces/coralnpu.hettrace` | NPU 权重/激活访存流 |
| `traces/vortex.hettrace` | GPU KV-cache 访存流 |
| `validate.txt`、`stats.txt` | HETTrace 结构和窗口统计 |
| `mem_sim.map.csv` | 访存请求到 mem_sim 的映射 |
| `hbm_sim.responses.csv` | 外部内存响应记录 |
| `summary.md` | 请求、字节、读写和延迟摘要 |

重点核对 `summary.md` 中的三项守恒关系：manifest / mapping / HostResponse 请求数相等，manifest / mapping 字节数相等，响应状态为 `ok`。相同参数和空结果目录会得到相同的请求规模，便于对比不同 XPU 或内存参数。

## 5. 一次运行全部样例

```bash
./docker/run.sh all
```

结果分别位于最新的 `results/docker/all-*/memsim/` 和 `results/docker/all-*/xpu/`。如果需要把结果写入指定位置：

```bash
SS_RESULTS_DIR=/data/storagestacked-results ./docker/run.sh all
```

## 6. 交付镜像

联网机器完成构建后可以导出镜像，交付方只需导入即可运行：

```bash
docker save storagestacked:local | gzip > storagestacked-local.tar.gz
docker load < storagestacked-local.tar.gz
./docker/run.sh memsim
```

镜像内已经包含编译产物和锁定版本依赖；运行样例时只需挂载结果目录。
