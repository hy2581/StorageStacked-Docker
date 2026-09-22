# StorageStacked Docker 交付仓库

克隆本仓库后，使用 `./run.sh` 完成环境准备和样例运行。固定版本的 gem5、CoralNPU、
Vortex、mem_sim、编译器和运行依赖均在 Docker 镜像中准备，宿主机无需另装模型工具链。

## 快速开始

先准备 **Linux x86-64（或 Windows 的 WSL2 Linux 环境）、Git、Docker Engine 和
Compose v2**，确保当前终端能执行 `docker info` 和 `docker compose version`。
Docker 安装可参考[官方说明](https://docs.docker.com/engine/install/ubuntu/)。
建议运行 Docker 的 Linux 环境具备 32 GiB 内存、100 GiB 可用磁盘；
无需物理 GPU、Vivado 或宿主机 SystemC。

然后只需三条命令（Windows 用户在 WSL2 终端执行）：

```bash
git clone https://github.com/hy2581/StorageStacked-Docker.git
cd StorageStacked-Docker
./run.sh setup
```

`setup` 自动检查 Docker、下载三份锁定的外部源码、安装依赖、编译完整镜像、检查设备库，
最后运行 **CPU / 在线 mem_sim 七组闭环验收**。终端出现 `初始化成功` 表示这些步骤均通过。
GPU/NPU 库的加载检查包含在初始化中，完整计算验收另运行 `./run.sh xpu`。

**首次准备需要联网，下载和编译可能需要数十分钟到数小时。**需要能访问 Docker Hub、Ubuntu 软件源、
GitHub、conda-forge 和 Bazel 依赖站点；后续运行复用镜像。网络受限时使用下文的离线镜像方式。
失败时先处理终端显示的错误，再重跑同一条命令；已完成的镜像层会复用，失败不会显示初始化成功。

## 日常使用

以下命令均在仓库根目录执行：

| 命令 | 内容 |
|---|---|
| `./run.sh memsim` | CPU、AXI256、UCIe、在线 mem_sim 七组样例 |
| `./run.sh xpu` | NPU、GPU、Host/GPU/NPU 三源及慢速内存四组计算验收 |
| `./run.sh llm` | 小规模 LLM 合成访存样例，默认 533 条请求；不运行真实 LLM 数值计算 |
| `./run.sh all` | 顺序运行 CPU 和 XPU 套件，不含 LLM |
| `./run.sh view` | 在浏览器中查看结果，打开 <http://localhost:8000>；Ctrl+C 停止 |
| `./run.sh check` | 检查镜像内源码版本、编译产物、动态库加载和 SystemC 依赖 |
| `./run.sh doctor` | 检查 Docker 环境 |

结果保存在宿主机 `results/docker/`，每次运行新建带时间戳的目录，保留汇总、日志、
AXI 波形和 Flit 记录。首次验收位于 `setup-*/check/` 和 `setup-*/memsim/`；
CPU/XPU 看 `summary.json`，LLM 看 `summary.md`。运行 `view` 后选择结果目录中的
`trace_view.html`（链路）或 `memsim_view.html`（内存时序）；交接结果时复制整个目录，
保留所有 `*_data/` 目录及 `view_store.js`。

可选配置：

```bash
# 指定结果保存位置；查看时使用相同的 SS_RESULTS_DIR
SS_RESULTS_DIR="$HOME/storagestacked-results" ./run.sh xpu
SS_RESULTS_DIR="$HOME/storagestacked-results" SS_VIEW_PORT=8080 ./run.sh view

# 更新仓库源码后，重新构建并验收
./run.sh setup
```

启动脚本会在镜像不存在时自动构建；镜像已存在时直接使用。更新源码后需要主动运行
`./run.sh setup`，也可用 `./run.sh build` 仅构建。旧入口 `./docker/run.sh` 继续兼容。

详细参数、排错和实验数据见：

- [Docker 运行说明](docker/README.md)
- [复现与参数操作指南](docker/REPRODUCTION.md)
- [样例执行报告](docker/validation_report.md)

## 离线镜像交付

交付方在联网机器完成 `./run.sh setup` 后导出镜像，并连同本仓库一起交付：

```bash
mkdir -p dist
docker save storagestacked:local | gzip > dist/storagestacked-local.tar.gz
```

客户在仓库根目录导入，然后直接检查和运行：

```bash
docker load < /path/to/storagestacked-local.tar.gz
./run.sh check
./run.sh memsim
./run.sh view
```

加载好的镜像已包含源码、依赖和编译产物，样例可离线运行。离线机器无需运行 `setup`，
因为该命令始终请求构建。镜像和大体积结果不随 Git 分发。

## 整体设计、构建与实验文档

以下文档对应当前 AXI256/UCIe/在线 mem_sim 闭环版本。`gem5_new/docs/` 中标为历史的
9 月 8 日资料记录旧离线流程，不作为当前整机的构建和架构依据。

| 阅读目的 | 文档 |
|---|---|
| 层级结构、模块职责、请求/响应、统一时间和反压 | [仿真器详细架构](docs/architecture.md) |
| 四个组件的源码准备、Docker/原生编译、产物与排错 | [构建与运行全流程](docs/build-run.md) |
| 实验设计、实测数据、指标定义、性能现象与优化方向 | [实验结果与分析](docs/experiments.md) |
| Host 调度、GPU/NPU 启动、缓冲区交接与完整协同链路 | [多设备协同机制](docs/multi-device.md) |
| 新设备的环境、ABI、gem5/存储链对接、调试与交付 | [新增 XPU 接入流程](docs/xpu-integration.md) |

历史所称“四个外部源码”中，mem_sim 现已随本仓库维护；需要另外获取的外部树为
gem5、CoralNPU、Vortex。Docker 构建自动获取，原生开发的逐项命令见上述构建文档。

Dockerfile 的三个 revision 参数与 `env/sources.lock.json` 保持一致，构建时再次检查实际
源码版本。项目普通源码与运行脚本随本仓库分发，便于按同一版本复现。
