#!/usr/bin/env bash
# Check installed products without claiming GPU/NPU kernel execution.
set -euo pipefail
source "${SS_ROOT:-/opt/StorageStacked}/env/activate.sh"
export LD_LIBRARY_PATH="$SS_DEPS_ROOT/xpu-native/lib:$VORTEX_HOME/third_party/ramulator:$LD_LIBRARY_PATH"
destination=${1:?请提供新的检查结果目录}
[[ ! -e "$destination" ]] || { echo "结果目录已存在：$destination" >&2; exit 1; }
mkdir -p "$destination"
"$AXI_PYTHON" "$SS_ROOT/env/check_sources.py"
"$AXI_PYTHON" "$SS_ROOT/env/record_xpu.py" "$destination"
"$AXI_PYTHON" - "$destination" <<'PY'
import ctypes
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ['SS_ROOT'])
gem5 = Path(os.environ['AXI_GEM5_BIN'])
assert gem5.is_file() and os.access(gem5, os.X_OK), 'gem5 executable is missing'
build_info = subprocess.check_output([str(gem5), '--build-info'], text=True)
libraries = [
    root / 'mem_sim/build-unified/libstoragestacked_memsim.so',
    root / 'vortex-gpu/vxbuild/sim/simx/libvortex-gem5.so',
    root / 'coralnpu/bazel-bin/gem5int/libcoralnpu-gem5.so',
]
handles = [ctypes.CDLL(str(path), mode=os.RTLD_NOW | os.RTLD_LOCAL) for path in libraries]
result = {
    'passed': True,
    'scope': 'pinned sources, built artifacts, gem5 startup, dynamic loading and SystemC audit',
    'gem5_build_info': build_info.strip(),
    'loaded_libraries': [str(path) for path in libraries],
    'gpu_npu_computation': 'NOT_RUN; use ./run.sh xpu',
}
(Path(sys.argv[1]) / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
print('镜像产物检查通过：gem5 可启动，mem_sim/GPU/NPU 库可加载，SystemC 审计通过。')
PY
