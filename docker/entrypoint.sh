#!/usr/bin/env bash
set -euo pipefail

root=${SS_ROOT:-/opt/StorageStacked}
deps=${SS_DEPS_ROOT:-/opt/deps}
results=${SS_RESULTS_ROOT:-/results}

timestamp() {
    date -u +%Y%m%dT%H%M%S%NZ
}

usage() {
    cat <<'EOF'
StorageStacked Docker runner

Usage:
  storagestacked setup [RESULT_DIR]
  storagestacked check [RESULT_DIR]
  storagestacked memsim [RESULT_DIR]
  storagestacked xpu [RESULT_DIR]
  storagestacked llm [RESULT_DIR] [TRACE_OPTIONS...]
  storagestacked all [RESULT_DIR]
  storagestacked shell
  storagestacked view

Examples:
  docker compose run --rm storagestacked memsim
  docker compose run --rm storagestacked xpu
  docker compose run --rm storagestacked llm --hidden-size 64 --layers 1
  docker compose run --rm storagestacked all

XPU parameters are controlled with XPU_NUM_CPUS, XPU_MEMSIM_SCALE,
XPU_SLOW_MEMSIM_SCALE, XPU_MAX_TICKS and XPU_REPLAY.

Results are written to the host directory configured by SS_RESULTS_DIR
(default: ./results/docker).
EOF
}

[[ -d "$root" ]] || { echo "missing project: $root" >&2; exit 2; }
[[ -d "$deps" ]] || { echo "missing dependencies: $deps" >&2; exit 2; }
mkdir -p "$results"

run_memsim() {
    local destination=${1:-"$results/memsim-$(timestamp)"}
    bash "$root/env/run_memsim.sh" "$destination"
}

run_xpu() {
    local destination=${1:-"$results/xpu-$(timestamp)"}
    local preload=${SS_XPU_LD_PRELOAD:-"$deps/toolchain/lib/libstdc++.so.6:$deps/toolchain/lib/libgcc_s.so.1"}
    LD_PRELOAD="$preload" bash "$root/env/run_xpu.sh" "$destination"
}

run_check() {
    local destination=${1:-"$results/check-$(timestamp)"}
    local preload=${SS_XPU_LD_PRELOAD:-"$deps/toolchain/lib/libstdc++.so.6:$deps/toolchain/lib/libgcc_s.so.1"}
    LD_PRELOAD="$preload" bash "$root/docker/check_runtime.sh" "$destination"
}

run_llm() {
    local destination="$results/llm-$(timestamp)"
    if [[ ${1:-} != "" && ${1:-} != -* ]]; then
        destination=$1
        shift
    fi
    [[ ! -e "$destination" ]] || { echo "结果目录已存在：$destination" >&2; exit 1; }
    MEMSIM_HOME="$root/mem_sim" \
    MEMSIM_BUILD="$root/mem_sim/build-unified" \
    MEMSIM_BIN="$root/mem_sim/build-unified/hbm_sim" \
    LLM_BENCH_OUT="$destination" \
        bash "$root/gem5_new/workloads/llm_memory/run.sh" \
            --hidden-size 32 --layers 1 --context-tokens 4 --decode-tokens 1 --request-bytes 64 "$@"
}

command=${1:-help}
shift || true
case "$command" in
    setup|check|memsim|xpu|all)
        [[ $# -le 1 && ( $# == 0 || $1 != -* ) ]] || { usage >&2; exit 2; }
        ;;
    help|-h|--help|shell|view)
        [[ $# == 0 ]] || { usage >&2; exit 2; }
        ;;
esac
case "$command" in
    help|-h|--help)
        usage
        ;;
    setup)
        destination=${1:-"$results/setup-$(timestamp)"}
        [[ ! -e "$destination" ]] || { echo "结果目录已存在：$destination" >&2; exit 1; }
        mkdir -p "$destination"
        run_check "$destination/check"
        run_memsim "$destination/memsim"
        printf '\n准备完成：设备库检查和 CPU/mem_sim 七组验收通过。\n结果：%s\n' "$destination"
        printf 'GPU/NPU 完整计算验收请运行 ./run.sh xpu。\n'
        ;;
    check)
        run_check "${1:-}"
        ;;
    memsim)
        run_memsim "${1:-}"
        ;;
    xpu)
        run_xpu "${1:-}"
        ;;
    llm)
        run_llm "$@"
        ;;
    all)
        destination=${1:-"$results/all-$(timestamp)"}
        [[ ! -e "$destination" ]] || { echo "结果目录已存在：$destination" >&2; exit 1; }
        mkdir -p "$destination"
        run_memsim "$destination/memsim"
        run_xpu "$destination/xpu"
        ;;
    shell)
        exec bash -l
        ;;
    view)
        exec python3 -m http.server 8000 --bind 0.0.0.0 --directory "$results"
        ;;
    *)
        echo "unknown command: $command" >&2
        usage >&2
        exit 2
        ;;
esac
