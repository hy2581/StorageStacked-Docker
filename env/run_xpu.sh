#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/activate.sh"
export LD_LIBRARY_PATH="$SS_DEPS_ROOT/xpu-native/lib:$VORTEX_HOME/third_party/ramulator:$LD_LIBRARY_PATH"
destination=${1:-"$SS_ROOT/results/xpu-$(date -u +%Y%m%dT%H%M%SZ)"}
[[ ! -e "$destination" ]] || { echo "结果目录已存在：$destination" >&2; exit 1; }
mkdir -p "$destination"
destination=$(cd "$destination" && pwd)

# The default values preserve the fixed acceptance workload.  They can be
# changed from Docker/Compose without editing this launcher, which makes a
# parameter sweep reproducible for a delivery partner.
xpu_num_cpus=${XPU_NUM_CPUS:-4}
xpu_memsim_scale=${XPU_MEMSIM_SCALE:-1}
xpu_slow_memsim_scale=${XPU_SLOW_MEMSIM_SCALE:-4}
xpu_max_ticks=${XPU_MAX_TICKS:-20000000000000}
xpu_replay=${XPU_REPLAY:-0}
for item in "$xpu_num_cpus" "$xpu_memsim_scale" "$xpu_slow_memsim_scale" "$xpu_max_ticks"; do
    [[ "$item" =~ ^[1-9][0-9]*$ ]] || { echo "XPU numeric parameters must be positive integers" >&2; exit 2; }
done
case "$xpu_replay" in
    0|1) ;;
    *) echo "XPU_REPLAY must be 0 or 1" >&2; exit 2 ;;
esac
xpu_common=(--num-cpus "$xpu_num_cpus" --max-ticks "$xpu_max_ticks")
if [[ "$xpu_replay" == 1 ]]; then
    xpu_common+=(--replay)
fi
"$AXI_PYTHON" "$SS_ROOT/env/check_sources.py"
"$AXI_PYTHON" "$SS_ROOT/env/record.py" "$destination/environment"
"$AXI_PYTHON" "$SS_ROOT/env/record_xpu.py" "$destination/environment"
ctest --test-dir "$MEMSIM_BUILD" --show-only=json-v1 > "$destination/native-test-plan.json"
ctest --test-dir "$MEMSIM_BUILD" --output-on-failure > "$destination/native-tests.log" 2>&1
"$AXI_PYTHON" "$MEMSIM_HOME/integration/check_online.py" "$MEMSIM_BUILD/libstoragestacked_memsim.so" "$destination/api"
gpu=(--vortex-library "$VORTEX_BUILD/sim/simx/libvortex-gem5.so" --vortex-host-rt-dir "$VORTEX_BUILD/sw/runtime")
npu=(--npu-library "$CORALNPU_HOME/bazel-bin/gem5int/libcoralnpu-gem5.so" --npu-kernel "$SS_ROOT/build/xpu/ddr_touch.elf")
run_case() {
    local name=$1
    shift
    local dir="$destination/$name"
    mkdir -p "$dir"
    echo "运行 $name"
    # Acceptance runs need no debugger; stray connections can stop simulation.
    "$AXI_GEM5_BIN" --listener-mode=off -d "$dir" "$AXI_PROJECT_DIR/configs/run_xpu.py" "${xpu_common[@]}" "$@" > "$dir/run.log" 2>&1
    echo "$name 仿真结束，开始数据与链路校验"
    for checker in check check_aou inspect_link check_memsim trace_view memsim_view; do
        "$AXI_PYTHON" "$AXI_PROJECT_DIR/scripts/$checker.py" "$dir" >> "$dir/verification.log" 2>&1
    done
    "$AXI_PYTHON" -m hettrace validate "$dir/hettrace" --ticks-per-second 1000000000000000 > "$dir/hettrace/validation.txt"
    echo "$name 计算与链路校验通过"
}
run_case npu --cmd "$HET_PROJECT_ROOT/workloads/shared_buffer/build/host_main" --options=npu --memsim-scale "$xpu_memsim_scale" "${npu[@]}"
run_case gpu --cmd "$VORTEX_BUILD/tests/regression/vecadd/vecadd" --options="-n 4 -k $VORTEX_BUILD/tests/regression/vecadd/kernel.vxbin" --memsim-scale "$xpu_memsim_scale" "${gpu[@]}"
run_case three --cmd "$HET_PROJECT_ROOT/workloads/three_source/build/host_main" --options="-k $VORTEX_BUILD/tests/regression/vecadd/kernel.vxbin" --memsim-scale "$xpu_memsim_scale" "${gpu[@]}" "${npu[@]}"
run_case three_slow --cmd "$HET_PROJECT_ROOT/workloads/three_source/build/host_main" --options="-k $VORTEX_BUILD/tests/regression/vecadd/kernel.vxbin" "${gpu[@]}" "${npu[@]}" --memsim-scale "$xpu_slow_memsim_scale"
"$AXI_PYTHON" "$AXI_PROJECT_DIR/scripts/audit_wave.py" "$destination/npu" "$destination/gpu" "$destination/three" "$destination/three_slow" --output "$destination/wave_audit"
"$AXI_PYTHON" "$SS_ROOT/env/verify_xpu.py" "$destination"
echo "三源全链路验收通过：$destination/summary.json"
