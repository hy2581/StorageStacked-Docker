# StorageStacked Docker 交付仓库

这个仓库提供 StorageStacked 的可复现 Docker 交付方式。对接方克隆仓库后，通过一个镜像获得固定版本的 gem5、CoralNPU、Vortex、mem_sim 和项目编译产物，然后直接运行 CPU/mem_sim、XPU 和 LLM 访存样例。

## 快速开始

环境只需要 Linux x86-64、Docker Engine 和 Docker Compose v2。首次构建会从锁定版本下载外部依赖并编译完整镜像：

```bash
git clone https://github.com/fmq03/StorageStacked-Docker.git
cd StorageStacked-Docker
docker compose build
```

构建完成后运行三组入口：

```bash
./docker/run.sh memsim
./docker/run.sh xpu
./docker/run.sh llm --hidden-size 32 --layers 1 --context-tokens 4 --decode-tokens 1 --request-bytes 64
```

结果默认写到 `results/docker/`。完整的运行参数、XPU 参数修改方式、LLM 访存算子复现命令和结果核对表见：

- [Docker 运行说明](docker/README.md)
- [复现与参数操作指南](docker/REPRODUCTION.md)
- [样例执行报告](docker/validation_report.md)

## 常用命令

```bash
# 构建
./docker/run.sh build

# CPU / mem_sim 七组样例
./docker/run.sh memsim

# NPU、GPU、三源和慢速内存四组样例
./docker/run.sh xpu

# LLM 访存算子
./docker/run.sh llm \
  --hidden-size 64 --layers 2 \
  --context-tokens 16 --decode-tokens 2 \
  --request-bytes 64

# 一次执行 CPU 和 XPU
./docker/run.sh all
```

## XPU 参数

XPU 参数通过 Compose 环境变量修改，默认配置直接对应报告中的验收样例：

```bash
XPU_NUM_CPUS=8 \
XPU_MEMSIM_SCALE=2 \
XPU_SLOW_MEMSIM_SCALE=8 \
XPU_REPLAY=1 \
./docker/run.sh xpu
```

参数含义和可复现实例见 [复现与参数操作指南](docker/REPRODUCTION.md#3-修改-xpu-参数并复现)。

## 镜像交付

联网机器构建后可以导出镜像，目标机器导入后直接运行：

```bash
docker save storagestacked:local | gzip > storagestacked-local.tar.gz
docker load < storagestacked-local.tar.gz
./docker/run.sh memsim
```

Dockerfile 使用 `env/sources.lock.json` 中的固定提交获取外部源码，项目普通源码与运行脚本随本仓库分发，便于按同一版本复现。
