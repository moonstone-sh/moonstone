FROM ubuntu:22.04

# Prevent interactive prompts during apt installations
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tar \
    && rm -rf /var/lib/apt/lists/*

ARG TARGETARCH
ARG MOONSTONE_VERSION=latest

# Download the pre-compiled binary
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    VERSION="${MOONSTONE_VERSION#v}" && \
    curl -fsSL "https://github.com/moonstone-sh/moonstone/releases/download/v${VERSION}/moon-v${VERSION}-${ARCH}-linux-gnu.tar.gz" | tar -xz -C /usr/local/bin


ENTRYPOINT ["moon"]
