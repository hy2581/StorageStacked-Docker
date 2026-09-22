# Docker 运行方式

这个封装把固定版本的 gem5、CoralNPU、Vortex、mem_sim 和项目工具环境放进镜像。对接方不需要在宿主机安装 GCC、Python、Bazel、Vortex 工具链，也不需要手动初始化三个外部子模块。

## 前提

- Linux x86-64 主机，已安装 Docker Engine 和 Docker Compose v2；
- 首次构建需要访问 GitHub、conda-forge 和 Bazel 依赖下载站点；
- 首次构建会下载工具链并编译模型，建议为 Linux/Docker 环境预留 32 GiB 内存、100 GiB 可用磁盘；WSL2/Docker Desktop 需确认虚拟机实际可用资源；
- 首次构建时间较长；gem5、CoralNPU 和依赖层编译或复制时终端可能长时间没有新输出，请不要中途退出；
- 不需要物理 GPU、`/dev/kvm` 或宿主机 SystemC。

## 构建镜像

客户首次使用，在仓库根目录执行：

```bash
./run.sh setup
```

它依次检查 Docker、构建镜像、检查已安装产物并运行 CPU/mem_sim 七组闭环验收。
任一步失败均返回非零状态，不打印 `初始化成功`。XPU 库能加载不代表计算验收通过，
完整 GPU/NPU 样例使用 `./run.sh xpu`。仅检查 Docker 用 `./run.sh doctor`。

只构建、不执行样例时使用：

```bash
./run.sh build
```

Dockerfile 会按三个 revision 参数克隆外部仓库的固定提交，再由
`env/check_sources.py` 核对其与 `env/sources.lock.json` 一致，然后执行
`bootstrap_xpu.sh` 和 `build_xpu.sh`。构建完成后，样例运行不需要重新下载依赖或完整编译
模型；CPU 验收入口仍会编译小型 Host 测试程序。
Dockerfile 将源码/编译层与根目录 README、客户启动脚本和 `docs/` 的复制分开，
只修改这些使用说明或入口时可复用昂贵的模型编译层。

四个组件的源码准备命令、各编译阶段和产物位置见[构建与运行全流程](../docs/build-run.md)。
整体设计、设备协同和新增设备分别见[架构](../docs/architecture.md)、
[协同机制](../docs/multi-device.md)、[XPU 接入](../docs/xpu-integration.md)。

编译并发数可调整：

```bash
AXI_JOBS=8 docker compose build
```

## 运行样例

```bash
# CPU、AXI、UCIe 和在线 mem_sim 样例
docker compose run --rm storagestacked memsim

# NPU、GPU、三源和慢速内存样例
docker compose run --rm storagestacked xpu

# 小规模合成访存样例；也可以继续传递 generate_trace.py 参数
docker compose run --rm storagestacked llm \
  --hidden-size 64 --layers 1 --context-tokens 16 --decode-tokens 2

# 依次运行 CPU 和 XPU 两组
docker compose run --rm storagestacked all
```

对应的短命令是 `./run.sh memsim`、`./run.sh xpu`、`./run.sh llm ...` 和 `./run.sh all`。
无参数的 `./run.sh llm` 默认使用 hidden-size=32、layers=1、context-tokens=4、
decode-tokens=1、request-bytes=64，产生 533 条合成请求；显式参数可覆盖默认值。
根目录入口可以从任意工作目录调用，旧 `./docker/run.sh` 保持兼容。

结果默认写到宿主机的 `results/docker/`。如需指定目录：

```bash
SS_RESULTS_DIR=/data/storagestacked-results \
  docker compose run --rm storagestacked xpu
```

每次运行使用新的结果子目录；目录中保留 `summary.json`、运行日志、AXI 五通道 VCD、Flit/链路记录和 mem_sim 时序文件。

在浏览器查看 HTML：

```bash
./run.sh view
# 若 8000 已占用：SS_VIEW_PORT=8080 ./run.sh view
```

打开 `http://localhost:8000/`，服务只绑定本机环回地址，Ctrl+C 停止。
如果运行样例时配置过 `SS_RESULTS_DIR`，查看时也要传入同一变量。
Python HTTP 服务来自镜像，宿主机无需安装 Python。交接需复制整个结果目录，
保留 HTML 对应的 `_data` 目录和 `view_store.js`。

若在远程服务器运行，在自己的电脑上先执行 `ssh -L 8000:127.0.0.1:8000 用户名@服务器`，
再在该 SSH 终端中进入仓库运行 `./run.sh view`，本机浏览器打开同一个
`http://localhost:8000/` 即可。更换端口时相应调整转发端口和 `SS_VIEW_PORT`。

## 常见问题

| 提示/现象 | 处理 |
|---|---|
| Docker 服务不可用或无权访问 | 启动 Docker，并让当前用户能够执行 `docker info` 后重试 |
| 缺少 Compose v2 | 按 Docker 官方安装说明安装 Compose 插件；本入口不使用旧 `docker-compose` |
| 平台不是 Linux x86-64 | 使用 x86-64 Linux 主机或 WSL2 的 Linux Docker 环境 |
| 下载超时/连接失败 | 检查 Docker Hub、Ubuntu、GitHub 和依赖站点的网络；网络受限时加载交付方准备的完整镜像 |
| 编译进程被系统杀死 | 检查内存/磁盘；`AXI_JOBS=2 ./run.sh setup` 可减少 gem5/mem_sim 并发，Vortex/Bazel 并发另见构建文档 |
| 更新源码后行为没有变化 | 执行 `./run.sh setup` 重建并验收；日常样例命令复用已有镜像 |
| 手动指定的结果目录已存在 | 换一个新目录；入口拒绝覆盖旧结果 |

Compose 会把当前终端的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`NO_PROXY`
传给构建步骤（兼容小写变量）。如果 Linux 宿主机代理仅监听 `127.0.0.1`，可执行：

```bash
SS_BUILD_NETWORK=host ./run.sh setup
```

Docker 服务须与代理位于同一台 Linux 主机。Docker Hub 基础镜像的下载仍由 Docker
服务负责，它的代理需在 Docker 自身配置；WSL2/Docker Desktop 按对应平台配置网络。
这些代理不写入运行镜像，交付样例无需代理。

维护入口回归：`python3 docker/test_runner.py`，使用假 Docker 验证失败传播、环境检查、
参数转发和镜像复用；实际模型正确性由 CPU/XPU 套件另行确认。

## 进入容器排查

```bash
docker compose run --rm storagestacked shell
```

容器内固定使用 `/opt/StorageStacked` 作为源码目录、`/opt/deps` 作为工具环境、`/results` 作为结果挂载点。XPU 入口会自动为 Vortex 工具链预加载匹配的 C++ 运行库，避免宿主机 GLIBC 版本差异影响环境审计。

## 交付建议

对接方首次执行 `./run.sh setup`，之后使用上述短命令。若希望完全离线交付，
应在可联网机器先构建并验收，然后导出镜像：

```bash
mkdir -p dist
docker save storagestacked:local | gzip > dist/storagestacked-local.tar.gz
```

目标机器执行 `docker load < storagestacked-local.tar.gz` 后运行 `./run.sh check`、
`./run.sh memsim` / `./run.sh xpu`。已有镜像时入口不请求拉取，不再需要 GitHub、
conda-forge 或 Bazel 网络访问。离线机器不运行会请求构建的 `setup`。

参数修改、LLM 访存算子复现和结果核对见[复现与参数操作指南](REPRODUCTION.md)。
已执行样例和结果汇总见[样例执行报告](validation_report.md)。
