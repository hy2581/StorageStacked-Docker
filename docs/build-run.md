# 从源码准备到构建、运行与输出

所有命令从仓库根目录执行。默认推荐 Docker；需要改设备/模型源码时可使用下面的原生
构建流程。架构见[详细设计](architecture.md)，结果解释见[实验分析](experiments.md)。

## 1. “四个外部源码”的当前对应关系

历史独立项目需要 gem5、CoralNPU、Vortex、mem_sim 四棵源码。当前版本仍需要这四个
组件，但 **mem_sim 已并入主仓库普通目录**，无需第四次克隆。

| 组件 | 当前获取方式 | 锁定/维护位置 |
|---|---|---|
| gem5 | 官方外部源码，目录 `gem5/` | [sources.lock.json](../env/sources.lock.json)：`c8222cc67a399bfc01e8658dd14b30d5bfd634f9` |
| CoralNPU | 官方外部源码，目录 `coralnpu/` | 同一锁：`fcb74cfe79dbd184b9c53539490994e701981f80` |
| Vortex | 官方外部源码及递归依赖，目录 `vortex-gpu/vortex/` | 同一锁：`d76b7f24e658867ab57e3942d7c648c3e6af072d` |
| mem_sim | 克隆本仓库时一并取得，目录 `mem_sim/` | 版本由主仓库提交决定；导入历史见 [internal_imports.json](../env/internal_imports.json) |

`ucie-model/`、`axi2flit/`、`gem5_axi/`、`gem5_new/` 也都是普通目录。
不要在这些内部目录创建 `.git`、执行独立 clone/pull 或恢复旧的构建时补丁流程。

**仓库形态有区别：**本 Docker 交付快照保留 `.gitmodules`，但没有登记三个外部目录的
gitlink；`git submodule update --init --recursive` 单独执行不会替它们下载源码。
Dockerfile 在镜像内创建三棵外部树。原 `fmq03/StorageStacked` 主仓库有 gitlink，才适用
[原生主仓库配置指引](setup.md)中的递归 submodule 初始化。可用
`git ls-files --stage gem5 coralnpu vortex-gpu/vortex` 确认，`160000` 表示 gitlink。

## 2. 推荐：Docker 获取、构建与运行

前提是 Linux x86-64、Docker Engine、Compose v2，首次构建可联网。建议至少 32 GiB
内存和 100 GiB 可用磁盘；实际还需容纳依赖缓存、镜像与完整波形。无需物理 GPU、
Vivado/VCS 或宿主机 SystemC。

```bash
git clone https://github.com/hy2581/StorageStacked-Docker.git
cd StorageStacked-Docker
./run.sh setup
./run.sh xpu
./run.sh llm
./run.sh view
```

`setup` 执行 Docker 检查、镜像构建、产物检查和 CPU/mem_sim 七组验收；结果在
`results/docker/setup-*/`。后续样例复用镜像，更新源码后再执行 `setup`。
需要单独保留构建日志时可用：

```bash
mkdir -p results/build-logs
set -o pipefail
AXI_JOBS=6 ./run.sh build 2>&1 | tee results/build-logs/docker-build.log
./run.sh check
```

前三棵外部源码无需先下载到宿主机：`.dockerignore` 排除其本地目录，Dockerfile 按
`GEM5_REV/CORALNPU_REV/VORTEX_REV` 参数获取固定提交，再初始化递归依赖。
这些默认参数与 `env/sources.lock.json` 相同，**并非动态读取 JSON**；构建中的
`check_sources.py` 再核对实际 HEAD。维护者有意升级版本时必须同步两处并重新验收。

| 构建阶段 | 实际动作 | 输出/通过条件 |
|---|---|---|
| Docker builder 基础层 | Ubuntu 20.04、apt 基础包、复制项目源码、建立镜像内源码快照 | Git 快照与外部源码目录形成；尚未证明可运行 |
| `bootstrap_xpu.sh` | 基础锁定工具环境、私有运行库、Bazel 8.6.0、LZ4、Vortex 工具链、CMake 源码缓存 | `/opt/deps/`；末尾 `XPU 工具环境已就绪` |
| `build_xpu.sh` 前半段 | 安装 Vortex/CoralNPU 补丁；配置 RV32；编译 Ramulator、SimX、runtime、vecadd 和 Host workload | `libvortex-gem5.so`、runtime、kernel、Host ELF |
| `build_xpu.sh` NPU 阶段 | Bazel 原生 C++ 规则，禁止引入第二套 SystemC；生成库与 NPU ELF | `libcoralnpu-gem5.so`、`build/xpu/ddr_touch.elf` |
| 内部调用 `build.sh` | 核对源码；安装 gem5 bridge/设备增量；CMake/Ninja 编译 mem_sim；SCons 编译 gem5 | `mem_sim/build-unified/`、`gem5/build/AXI/gem5.opt` |
| Docker runtime 层 | 复制源码、固定工具环境及编译产物，安装 runner | `storagestacked:local`；仍需实际运行验收 |

根 README、`docs/` 和客户启动脚本在 runtime 层复制；修改这些文件可复用模型编译层。
默认 LLM 已选择小规模 533 请求样例。网络代理、离线加载和入口排错见
[Docker 操作说明](../docker/README.md#常见问题)。

gem5 构建设置 `USE_SYSTEMC=y`、`RUBY=n`、`USE_KVM=y`。KVM 是构建配置要求，
样例使用 TimingSimpleCPU，不需要 `/dev/kvm`。
`AXI_JOBS` 当前控制 gem5/mem_sim；Vortex make 为 `-j4`、Bazel 为 `--jobs=6`，
不能把 `AXI_JOBS=2` 理解为所有构建阶段都只用两个任务。

## 3. 可选：在本 Docker checkout 中逐项获取源码

仅在需要宿主机原生开发、且外部目录为空时执行。已存在的源码先检查状态，以下命令主动
拒绝覆盖非空目录；不要 reset 已安装的适配。网络、系统包前提见 [setup.md](setup.md)。

```bash
set -euo pipefail
fetch_locked_source() {
    local ss_path="$1" ss_url="$2" ss_revision
    ss_revision=$(python3 -c 'import json,sys; print(json.load(open("env/sources.lock.json"))[sys.argv[1]])' "$ss_path")
    if [[ -e "$ss_path" && ( ! -d "$ss_path" || -n "$(ls -A "$ss_path")" ) ]]; then
        printf '目录非空，请先核对本地源码和改动：%s\n' "$ss_path" >&2
        return 1
    fi
    mkdir -p "$ss_path"
    git init "$ss_path"
    git -C "$ss_path" remote add origin "$ss_url"
    git -C "$ss_path" fetch --depth=1 origin "$ss_revision"
    git -C "$ss_path" checkout --detach "$ss_revision"
    git -C "$ss_path" submodule update --init --recursive
}

# 第一项：gem5
fetch_locked_source gem5 https://github.com/gem5/gem5.git
# 第二项：CoralNPU
fetch_locked_source coralnpu https://github.com/google-coral/coralnpu.git
# 第三项：Vortex，含其递归依赖
fetch_locked_source vortex-gpu/vortex https://github.com/vortexgpgpu/vortex.git
# 第四项：mem_sim 已随主仓库取得，检查源码归属即可。
test -f mem_sim/CMakeLists.txt
test -f mem_sim/integration/online.cpp
test ! -e mem_sim/.git
git -C mem_sim rev-parse --show-toplevel

python3 env/check_sources.py
git -C gem5 submodule status --recursive
git -C coralnpu submodule status --recursive
git -C vortex-gpu/vortex submodule status --recursive
```

`check_sources.py` 应打印三个锁定 revision，以及五项 `monorepo source`。
递归 submodule 状态行不得以 `-`（未初始化）、`+`（版本偏离）或 `U`（冲突）开头。
获取失败时保留现场；先区分网络/权限与 revision 不存在，不换成上游最新版本“试过再说”。
这些外部源码供本地构建使用，不应作为普通文件整树加入 Docker 交付仓库。

## 4. 原生配置与编译

```bash
export SS_DEPS_ROOT="$HOME/.local/share/storagestacked-unified"
mkdir -p results/build-logs
set -o pipefail
bash env/bootstrap_xpu.sh 2>&1 | tee results/build-logs/bootstrap-xpu.log
AXI_JOBS=6 bash env/build_xpu.sh 2>&1 | tee results/build-logs/build-xpu.log
source env/activate.sh
test -x "$AXI_GEM5_BIN"
test -f "$MEMSIM_BUILD/libstoragestacked_memsim.so"
test -f "$VORTEX_BUILD/sim/simx/libvortex-gem5.so"
test -f "$CORALNPU_HOME/bazel-bin/gem5int/libcoralnpu-gem5.so"
test -f "$SS_ROOT/build/xpu/ddr_touch.elf"
bash env/run_memsim.sh results/acceptance-memsim-new
bash env/run_xpu.sh results/acceptance-xpu-new
```

`bootstrap_xpu/build_xpu` 已包含基础 bootstrap/build，不需重复执行。
仅运行 CPU 时可依次使用 `bootstrap.sh`、`build.sh`、`run_memsim.sh`。
上面的 `test` 只确认产物存在，动态链接、实际执行与数据正确性由后两项运行确认。

主要产物位置（Docker 中根目录为 `/opt/StorageStacked`）：

| 产物 | 路径 |
|---|---|
| gem5 统一可执行文件 | `gem5/build/AXI/gem5.opt` |
| 在线内存库 / 离线 CLI | `mem_sim/build-unified/libstoragestacked_memsim.so` / `hbm_sim` |
| GPU 模型 | `vortex-gpu/vxbuild/sim/simx/libvortex-gem5.so` |
| GPU Host runtime | `vortex-gpu/vxbuild/sw/runtime/` |
| GPU 样例 | `vortex-gpu/vxbuild/tests/regression/vecadd/vecadd`、`kernel.vxbin` |
| NPU 模型 / kernel | `coralnpu/bazel-bin/gem5int/libcoralnpu-gem5.so` / `build/xpu/ddr_touch.elf` |
| Host 样例 | `gem5_new/workloads/shared_buffer/build/host_main`、`gem5_new/workloads/three_source/build/host_main` |

外部补丁来源：`gem5_axi/patches/`、`gem5_new/gem5int/patches/`、
`gem5_new/vortexint/patches/`、`gem5_new/coralnpuint/patches/`。
修改设备时编辑项目维护源，再重新构建；不要只修改 gem5 中会被覆盖的副本。

## 5. 运行阶段、日志与输出检查

`memsim` 跑 7 组，`xpu` 跑 4 组；`all` 顺序跑这两套，**不包含 LLM**。
可用 `SS_RESULTS_DIR="$PWD/results/my-run" ./run.sh all` 改宿主输出位置。
runner 以 UTC 时间生成子目录；原生入口和显式指定的结果目录必须尚不存在。

XPU 参数、LLM 参数和完整命令见 [Docker 复现指南](../docker/REPRODUCTION.md)。
手工调用 gem5 时，`--listener-mode=off` 必须在配置脚本前；完整在线 CPU 链路显式
选 `--backend aou --memory-backend memsim`，不能沿用 `run.py` 的 RAM 默认值。

| 输出 | 对应信息与验收作用 |
|---|---|
| 套件 `environment/manifest.json`、`xpu_manifest.json` | 源码/工具/产物来源；镜像内主仓库 revision 可能是 Docker 创建的源码快照 |
| `native-test-plan.json`、`native-tests.log`、`api/api_check.json` | mem_sim 原生测试、C ABI、队列重试与数据契约 |
| 用例 `run.log`、`config.ini`、`config.json`、`stats.txt` | 实际配置、workload 结果、设备周期与 gem5 结束 tick |
| `transactions.csv`、`axi_events.csv`、`axi_wave.vcd` | 父事务阶段时间、真实五通道握手与信号保持 |
| `aou_events.csv`、`ucie_soc.csv`、`ucie_mem.csv`、`ucie_flits.csv` | AoU 对应关系、两端完整 Flit、CRC/replay |
| `memsim_config.json`、`memsim_bridge.csv`、`memsim_core.json` | 原生周期映射、子请求 issue/complete、排空与计数 |
| `memsim_commands.csv`、`memsim_dfi*.csv`、`memsim_image.csv` | DRAM 命令、DFI 轨迹及最终数据证据 |
| `hettrace/` | 按来源的 packet 投影及 `validation.txt` |
| 用例 `*_summary.json`、`memsim_check.json`；套件 `wave_audit/summary.json`、`summary.json` | 独立数据、链路、波形、时间反馈验收；总 `passed=true` 才是套件通过 |
| `trace_view.html`、`memsim_view.html`、各自数据目录、`view_store.js` | 按需加载的可视化，交接需完整复制用例目录 |

XPU 会打印“运行用例→仿真结束，开始数据与链路校验→计算与链路校验通过”，各组后还有
波形审计和总体验收。`run.log` 中程序通过或 gem5 退出码为 0 都不能替代总体验收。
XPU 的校验过程还写 `verification.log`；CPU 套件主要将检查器输出写终端，需保存启动日志。

```bash
python3 -m http.server 8000 --bind 127.0.0.1 --directory results
```

浏览器从 `http://localhost:8000/` 进入相应用例的 HTML。缺少数据分块或从 WSL 文件路径
直接打开时，优先核对整个用例目录并使用 HTTP。

## 6. 常见问题与交付边界

| 现象 | 定位与处理 |
|---|---|
| 外部目录为空 / revision 不一致 | 区分 Docker 与原主仓库布局；按第 3 节获取或核对锁定源码，不清理本地适配 |
| Bazel/CMake 正在下载或失败 | 查看对应构建日志、锁定缓存和网络；`SS_OFFLINE=1` 只约束 bootstrap |
| `Disabling HDF5 support` | 可选 HDF5 输出未启用；当前验收使用 CSV、JSON、VCD，不依赖它，仍需检查构建退出码和实际验收结果 |
| 内存不足、编译进程被杀 | 降低对应阶段并行度并复用该次构建对象；注意部分并行参数仍固定在脚本中 |
| 动态库找不到符号 / C++ 运行库版本不匹配 | 使用 `env/activate.sh`；Docker XPU runner 会预加载匹配运行库；核对库与 ELF 来自同一构建 |
| 新设备 SimObject 不存在 | 检查安装复制集合、SConscript/EXTRAS 和 `build/AXI/params/`，再构建 |
| Vortex 建队列失败 | `XPU_NUM_CPUS` 至少 2；runtime 需要 Host worker 线程上下文 |
| XPU 慢组总验收失败 | slow scale 必须大于 fast scale 且为整数倍；分别看功能、时间反馈与波形原因 |
| 仿真停在 GDB / 达到 max-ticks | 核对 listener 参数与 workload 完成原因；达到时限不能记 PASS |

离线镜像导出与加载见 [README 的交付步骤](../README.md#离线镜像交付)，大体积包放入
`dist/` 并单独交付。已有镜像运行、依赖包 bootstrap 和从零断网重建是三种不同的
验证范围；具体批次和验证方式见[执行记录](../docker/validation_report.md)。
