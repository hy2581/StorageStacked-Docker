#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

command=${1:-help}
shift || true

case "$command" in
    build)
        exec docker compose build "$@"
        ;;
    help|-h|--help)
        cat <<'EOF'
用法：
  ./docker/run.sh build
  ./docker/run.sh memsim
  ./docker/run.sh xpu
  ./docker/run.sh llm [访存参数]
  ./docker/run.sh all
EOF
        ;;
    memsim|xpu|llm|all|shell)
        exec docker compose run --rm storagestacked "$command" "$@"
        ;;
    *)
        echo "未知命令：$command" >&2
        "$0" help >&2
        exit 2
        ;;
esac
