#!/usr/bin/env bash
set -euo pipefail

root=${SS_ROOT:-/opt/StorageStacked}
deps=${SS_DEPS_ROOT:-/opt/deps}
results=${SS_RESULTS_ROOT:-/results}

timestamp() {
    date -u +%Y%m%dT%H%M%SZ
}

usage() {
    cat <<'EOF'
StorageStacked Docker runner

Usage:
  storagestacked memsim [RESULT_DIR]
  storagestacked xpu [RESULT_DIR]
  storagestacked llm [RESULT_DIR] [TRACE_OPTIONS...]
  storagestacked all [RESULT_DIR]
  storagestacked shell

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

run_llm() {
    local destination="$results/llm-$(timestamp)"
    if [[ ${1:-} != "" && ${1:-} != -* ]]; then
        destination=$1
        shift
    fi
    MEMSIM_HOME="$root/mem_sim" \
    MEMSIM_BUILD="$root/mem_sim/build-unified" \
    MEMSIM_BIN="$root/mem_sim/build-unified/hbm_sim" \
    LLM_BENCH_OUT="$destination" \
        bash "$root/gem5_new/workloads/llm_memory/run.sh" "$@"
}

command=${1:-help}
shift || true
case "$command" in
    help|-h|--help)
        usage
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
        mkdir -p "$destination"
        run_memsim "$destination/memsim"
        run_xpu "$destination/xpu"
        ;;
    shell)
        exec bash -l
        ;;
    *)
        echo "unknown command: $command" >&2
        usage >&2
        exit 2
        ;;
esac
