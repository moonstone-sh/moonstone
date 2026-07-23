FROM alpine:3.19

# Install base dependencies (ca-certificates for HTTPS networking)
RUN apk add --no-cache ca-certificates curl bash

# Define the architecture and version
ARG TARGETARCH
ARG MOONSTONE_VERSION=latest

# This simulates exactly what Bun and PNPM do!
# They do NOT compile from source in the Dockerfile. They download the pre-compiled native binary.
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        ARCH="aarch64"; \
    else \
        ARCH="x86_64"; \
    fi && \
    VERSION="${MOONSTONE_VERSION#v}" && \
    curl -fsSL "https://github.com/moonstone-sh/moonstone/releases/download/v${VERSION}/moon-v${VERSION}-${ARCH}-linux-musl.tar.gz" | tar -xz -C /usr/local/bin


# Set Moonstone as the entrypoint
ENTRYPOINT ["moon"]
