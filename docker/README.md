# Docker 运行方式

这个封装把固定版本的 gem5、CoralNPU、Vortex、mem_sim 和项目工具环境放进镜像。对接方不需要在宿主机安装 GCC、Python、Bazel、Vortex 工具链，也不需要手动初始化三个外部子模块。

## 前提

- Linux x86-64 主机，已安装 Docker Engine 和 Docker Compose v2；
- 首次构建需要访问 GitHub、conda-forge 和 Bazel 依赖下载站点；
- 首次构建会下载并编译完整工具链，建议至少 16 GiB 内存、60 GiB 可用磁盘；
- 首次构建时间较长；gem5、CoralNPU 和依赖层编译或复制时终端可能长时间没有新输出，请不要中途退出；
- 不需要物理 GPU、`/dev/kvm` 或宿主机 SystemC。

## 构建镜像

在仓库根目录执行：

```bash
docker compose build
```

如果对接方不熟悉 Compose，也可以使用仓库自带的短命令：

```bash
./docker/run.sh build
```

Dockerfile 会在构建阶段根据 `env/sources.lock.json` 克隆三个外部仓库的固定提交，然后执行现有的 `bootstrap_xpu.sh` 和 `build_xpu.sh`。构建完成后，运行阶段不再访问网络，也不需要重新编译。

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

对应的短命令是 `./docker/run.sh memsim`、`./docker/run.sh xpu`、`./docker/run.sh llm ...` 和 `./docker/run.sh all`。

结果默认写到宿主机的 `results/docker/`。如需指定目录：

```bash
SS_RESULTS_DIR=/data/storagestacked-results \
  docker compose run --rm storagestacked xpu
```

每次运行使用新的结果子目录；目录中保留 `summary.json`、运行日志、AXI 五通道 VCD、Flit/链路记录和 mem_sim 时序文件。

## 进入容器排查

```bash
docker compose run --rm storagestacked shell
```

容器内固定使用 `/opt/StorageStacked` 作为源码目录、`/opt/deps` 作为工具环境、`/results` 作为结果挂载点。XPU 入口会自动为 Vortex 工具链预加载匹配的 C++ 运行库，避免宿主机 GLIBC 版本差异影响环境审计。

## 交付建议

对接方拿到仓库后只需要执行一次 `docker compose build`，之后使用上面的 `docker compose run` 命令。若希望完全离线交付，应在可联网机器先构建并导出镜像：

```bash
docker save storagestacked:local | gzip > storagestacked-local.tar.gz
```

目标机器导入后直接运行 `docker compose run` 即可，不再需要 GitHub、conda-forge 或 Bazel 网络访问。

参数修改、LLM 访存算子复现和结果核对见[复现与参数操作指南](REPRODUCTION.md)。
已执行样例和结果汇总见[样例执行报告](validation_report.md)。
