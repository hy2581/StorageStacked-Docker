#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

usage() {
    cat <<'EOF'
StorageStacked 客户入口（在仓库根目录运行）

  ./run.sh setup       首次准备：检查 Docker、构建镜像、检查设备库、运行 CPU 闭环验收
  ./run.sh memsim      CPU / 在线内存七组样例
  ./run.sh xpu         NPU、GPU、三源和慢速内存四组样例
  ./run.sh llm         小规模 LLM 合成访存样例，可追加生成器参数
  ./run.sh all         顺序运行 CPU 和 XPU 验收
  ./run.sh view        查看结果：http://localhost:8000（Ctrl+C 停止）
  ./run.sh doctor      仅检查 Docker 环境
  ./run.sh check       检查镜像内的源码、产物与设备动态库
  ./run.sh build       构建/更新镜像，可追加 Compose build 参数
  ./run.sh shell       进入容器排查

默认结果：results/docker/；用 SS_RESULTS_DIR 修改。
默认镜像：storagestacked:local；用 SS_IMAGE 修改。
基础镜像：ubuntu:20.04；用 SS_BASE_IMAGE 指定本地导入的等价标签。
查看端口：8000；用 SS_VIEW_PORT 修改。
第一次 setup 需要联网下载并编译，后续运行复用镜像。
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 2; }

check_docker() {
    command -v docker >/dev/null 2>&1 || fail '未安装 Docker。请先安装 Docker Engine 和 Compose v2，再运行 ./run.sh setup。'
    docker compose version >/dev/null 2>&1 || fail '缺少 Docker Compose v2；请安装 Compose 插件后重试。'
    local engine
    engine=$(docker info --format '{{.OSType}}/{{.Architecture}}') ||
        fail 'Docker 服务不可用或当前用户无权访问。请先确保 docker info 能正常执行。'
    case "$engine" in
        linux/x86_64|linux/amd64) ;;
        *) fail "当前 Docker 平台为 $engine；本交付版本需要 Linux x86-64（支持 WSL2）。" ;;
    esac
    printf 'Docker 环境检查通过：%s\n' "$engine"
}

build_image() {
    printf '构建镜像 %s；首次会自动下载固定源码与工具并编译，请等待构建完成。\n' "$SS_IMAGE"
    docker compose --progress plain build "$@"
}

ensure_image() {
    if ! docker image inspect "$SS_IMAGE" >/dev/null 2>&1; then
        printf '尚无镜像 %s，先自动构建。\n' "$SS_IMAGE"
        build_image
    fi
}

# Keep the wrapper's image check and Compose interpolation on the same value.
export SS_IMAGE=${SS_IMAGE:-storagestacked:local}
command=${1:-help}
shift || true

case "$command" in
    help|-h|--help)
        usage
        exit 0
        ;;
    setup|doctor|view|shell)
        [[ $# == 0 ]] || fail "$command 不接受额外参数；运行 ./run.sh help 查看用法。"
        ;;
    memsim|xpu|all|check)
        [[ $# -le 1 && ( $# == 0 || $1 != -* ) ]] ||
            fail "$command 仅接受一个可选的容器内结果目录；运行 ./run.sh help 查看用法。"
        ;;
    build|llm) ;;
    *)
        usage >&2
        fail "未知命令：$command"
        ;;
esac

check_docker
case "$command" in
    doctor)
        docker compose version
        printf '环境可用。首次准备运行 ./run.sh setup。\n'
        ;;
    setup)
        build_image
        docker compose run --rm --no-deps --pull never storagestacked setup
        printf '\n初始化成功。运行 ./run.sh xpu 或 ./run.sh llm；用 ./run.sh view 查看结果。\n'
        ;;
    build)
        build_image "$@"
        ;;
    view)
        port=${SS_VIEW_PORT:-8000}
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || fail 'SS_VIEW_PORT 必须是 1 到 65535 的整数。'
        (( 10#$port >= 1 && 10#$port <= 65535 )) || fail 'SS_VIEW_PORT 必须是 1 到 65535 的整数。'
        ensure_image
        printf '浏览器打开 http://localhost:%s/；按 Ctrl+C 停止服务。\n' "$port"
        exec docker compose run --rm --no-deps --pull never \
            -p "127.0.0.1:$port:8000" storagestacked view
        ;;
    memsim|xpu|llm|all|check|shell)
        ensure_image
        exec docker compose run --rm --no-deps --pull never storagestacked "$command" "$@"
        ;;
esac
