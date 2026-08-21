FROM debian:bookworm-slim AS moonstone-build

ARG ZIG_VERSION=0.16.0
ARG MOONSTONE_OPTIMIZE=ReleaseFast

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    jq \
    tar \
    xz-utils \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN architecture="$(dpkg --print-architecture)" && \
    case "${architecture}" in \
        amd64) zig_arch="x86_64" ;; \
        arm64) zig_arch="aarch64" ;; \
        *) echo "unsupported benchmark architecture: ${architecture}" >&2; exit 1 ;; \
    esac && \
    zig_url="$(curl -fsSL https://ziglang.org/download/index.json | jq -r --arg version "${ZIG_VERSION}" --arg target "${zig_arch}-linux" '.[$version][$target].tarball')" && \
    zig_tar="$(basename "${zig_url}")" && \
    zig_dir="${zig_tar%.tar.xz}" && \
    curl -fsSL "${zig_url}" | tar -xJ -C /usr/local && \
    mkdir -p /opt && \
    mv "/usr/local/${zig_dir}" /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /src
COPY . .
RUN zig build -j1 -Doptimize=${MOONSTONE_OPTIMIZE}

FROM debian:bookworm-slim

ARG MOONSTONE_OPTIMIZE=ReleaseFast

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    bzip2 \
    ca-certificates \
    cmake \
    curl \
    file \
    git \
    jq \
    liblua5.4-dev \
    libssl-dev \
    lua5.4 \
    luarocks \
    make \
    tar \
    time \
    unzip \
    wget \
    xz-utils \
    zip \
    zstd \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=moonstone-build /src/zig-out/bin/moon /usr/local/bin/moon
COPY --from=moonstone-build /opt/zig /opt/zig
COPY examples/rocks-parallel-demo /opt/rocks-parallel-demo
COPY benchmarks/luarocks-vs-moonstone/benchmark.sh /usr/local/bin/benchmark-luarocks-vs-moonstone

WORKDIR /work
ENV MOONSTONE_BENCHMARK_BUILD_MODE=${MOONSTONE_OPTIMIZE}
ENV PATH="/opt/zig:${PATH}"
ENTRYPOINT ["benchmark-luarocks-vs-moonstone"]
