# syntax=docker/dockerfile:1.7

ARG UBUNTU_VERSION=20.04

FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG AXI_JOBS=6
ARG GEM5_REV=c8222cc67a399bfc01e8658dd14b30d5bfd634f9
ARG CORALNPU_REV=fcb74cfe79dbd184b9c53539490994e701981f80
ARG VORTEX_REV=d76b7f24e658867ab57e3942d7c648c3e6af072d

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    SS_DEPS_ROOT=/opt/deps \
    AXI_JOBS=${AXI_JOBS} \
    CXXFLAGS=-Wno-error=maybe-uninitialized

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake bash bison bzip2 ca-certificates \
        build-essential cmake curl file flex git gzip \
        libatomic1 libbz2-dev libffi-dev liblzma-dev libncurses5-dev \
        libssl-dev libtool make ninja-build openjdk-11-jre-headless \
        patch perl pkg-config python3 rsync tar unzip wget xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
COPY . /opt/StorageStacked

# The build context intentionally omits external submodule worktrees. Create a
# small local Git repository for the monorepo sources, then fetch the exact
# revisions recorded by env/sources.lock.json inside the image.
RUN set -eux; \
    git init /opt/StorageStacked; \
    git -C /opt/StorageStacked config user.email docker@storagestacked.invalid; \
    git -C /opt/StorageStacked config user.name StorageStacked-Docker; \
    git -C /opt/StorageStacked add -A; \
    git -C /opt/StorageStacked commit -m 'Docker source snapshot'

RUN set -eux; \
    clone_at() { \
        path="$1"; url="$2"; revision="$3"; \
        mkdir -p "$(dirname "$path")"; \
        git init "$path"; \
        git -C "$path" remote add origin "$url"; \
        git -C "$path" fetch --depth=1 origin "$revision"; \
        git -C "$path" checkout --detach FETCH_HEAD; \
        git -C "$path" submodule update --init --recursive; \
    }; \
    clone_at /opt/StorageStacked/gem5 \
        https://github.com/gem5/gem5.git "$GEM5_REV"; \
    clone_at /opt/StorageStacked/coralnpu \
        https://github.com/google-coral/coralnpu.git "$CORALNPU_REV"; \
    clone_at /opt/StorageStacked/vortex-gpu/vortex \
        https://github.com/vortexgpgpu/vortex.git "$VORTEX_REV"

WORKDIR /opt/StorageStacked

# bootstrap_xpu installs the locked compiler/Python environments and the
# pinned Vortex/Bazel assets under /opt/deps; build_xpu then builds gem5,
# mem_sim, Vortex SimX and the CoralNPU shared library.
RUN bash env/bootstrap_xpu.sh
RUN useradd --create-home --uid 1000 ssbuild \
    && chown -R ssbuild:ssbuild /opt/StorageStacked /opt/deps
USER ssbuild
RUN bash env/build_xpu.sh

FROM ubuntu:${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    SS_ROOT=/opt/StorageStacked \
    SS_DEPS_ROOT=/opt/deps \
    SS_RESULTS_ROOT=/results \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates coreutils file git \
        libatomic1 libbz2-1.0 libffi7 libgcc-s1 libgomp1 \
        liblzma5 libncurses5 libssl1.1 libstdc++6 libtinfo5 \
        libxml2 procps python3 rsync zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/StorageStacked /opt/StorageStacked
COPY --from=builder /opt/deps /opt/deps
COPY docker/entrypoint.sh /usr/local/bin/storagestacked

RUN chmod 0755 /usr/local/bin/storagestacked \
    && mkdir -p /results \
    && git config --system --add safe.directory /opt/StorageStacked \
    && git config --system --add safe.directory /opt/StorageStacked/gem5 \
    && git config --system --add safe.directory /opt/StorageStacked/coralnpu \
    && git config --system --add safe.directory /opt/StorageStacked/vortex-gpu/vortex

WORKDIR /opt/StorageStacked
ENTRYPOINT ["/usr/local/bin/storagestacked"]
CMD ["help"]
